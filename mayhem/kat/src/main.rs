// KAT (known-answer test) oracle probe for the winnow Mayhem integration.
//
// Drives winnow's PUBLIC combinator API on FIXED inputs and prints exact,
// deterministic values. mayhem/test.sh runs this binary and greps the exact
// expected lines (SPEC §6.3 anti-reward-hacking): a PATCH that neuters winnow
// (or this probe) changes/eliminates the output and the oracle FAILS.
//
// The arithmetic grammar below is the same combinator stack upstream's own
// fuzz/fuzz_targets/fuzz_arithmetic.rs exercises (delimited/alt/repeat/fold/
// parse_to over ascii::digit1), so the probe asserts real library behavior on
// the very code paths the fuzz target explores. No file I/O, no network.

use winnow::prelude::*;
use winnow::{
    ascii::{digit1 as digit, space0 as space},
    combinator::alt,
    combinator::repeat,
    combinator::{delimited, terminated},
};

fn parens(i: &mut &str) -> ModalResult<i64> {
    delimited(space, delimited(terminated("(", space), expr, ")"), space).parse_next(i)
}

fn factor(i: &mut &str) -> ModalResult<i64> {
    alt((delimited(space, digit, space).parse_to(), parens)).parse_next(i)
}

fn term(i: &mut &str) -> ModalResult<i64> {
    let init = factor(i)?;
    let res = repeat(0.., alt((('*', factor), ('/', factor.verify(|v| *v != 0)))))
        .fold(
            || init,
            |acc, (op, val): (char, i64)| {
                if op == '*' {
                    acc.saturating_mul(val)
                } else {
                    acc.checked_div(val).unwrap_or(i64::MAX)
                }
            },
        )
        .parse_next(i);
    res
}

fn expr(i: &mut &str) -> ModalResult<i64> {
    let init = term(i)?;
    let res = repeat(0.., (alt(('+', '-')), term))
        .fold(
            || init,
            |acc, (op, val): (char, i64)| {
                if op == '+' {
                    acc.saturating_add(val)
                } else {
                    acc.saturating_sub(val)
                }
            },
        )
        .parse_next(i);
    res
}

fn digits<'i>(i: &mut &'i str) -> ModalResult<&'i str> {
    digit.parse_next(i)
}

fn main() {
    // KAT1: full expression evaluation through the combinator stack.
    let v1 = expr.parse(" 1 + 2 * 3 + 4 ").expect("KAT1 parse failed");
    println!("KAT1 value={v1}"); // 11

    // KAT2: nested parentheses + division + saturating ops.
    let v2 = expr.parse("2*(3+4)-10/(2+3)").expect("KAT2 parse failed");
    println!("KAT2 value={v2}"); // 12

    // KAT3: primitive slicing — ascii::digit1 must split the leading digit run.
    let mut i3 = "98765rest";
    let d = digits.parse_next(&mut i3).expect("KAT3 parse failed");
    println!("KAT3 digits={d} rest={i3}"); // digits=98765 rest=rest

    // KAT4: a malformed input must be REJECTED (an oracle for error paths, so a
    // neutered parser that "accepts everything" also fails the KATs).
    let e = expr.parse("1++2");
    println!("KAT4 reject={}", e.is_err()); // true
}
