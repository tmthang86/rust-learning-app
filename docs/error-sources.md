# Error explanation sources

Where each entry in `assets/content/errors/` (`index.json` and `en.json`) was
checked, on 2026-10-21. For every error code, the writer checked the
explanation text against the official error index entry: the page on
doc.rust-lang.org and its source file in the rust-lang/rust repository (the
same text `rustc --explain CODE` prints offline; rustc 1.97.0). An independent
reviewer then re-checked the entries against `rustc --explain` on the same
date. The source file of every code was fetched and its opening sentence
matches the local `rustc --explain` output. Rust Book chapters are listed
where they explain the rule in more depth. `tool/check_errors.py` checks, with
rustc 1.97, that each code is still emitted and that each `example` fails with
exactly that error as its first error.

Notes:

- E0412 ("cannot find type") is deliberately missing: rustc 1.97 marks it "no
  longer emitted" and reports unknown types as E0425 (see that entry).
- Codeless entries have no error index page. The rule is cited from the
  Reference or the Book, and the `match` text was taken from rustc 1.97 output
  for the example program.

Pattern for codes: page `https://doc.rust-lang.org/error_codes/EXXXX.html`,
source `https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/EXXXX.md`.

## Error codes

| Entry | Official error index (page, source file) | Book or other |
|---|---|---|
| E0382 | https://doc.rust-lang.org/error_codes/E0382.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0382.md | https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html |
| E0499 | https://doc.rust-lang.org/error_codes/E0499.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0499.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0502 | https://doc.rust-lang.org/error_codes/E0502.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0502.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0505 | https://doc.rust-lang.org/error_codes/E0505.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0505.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0506 | https://doc.rust-lang.org/error_codes/E0506.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0506.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0507 | https://doc.rust-lang.org/error_codes/E0507.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0507.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0515 | https://doc.rust-lang.org/error_codes/E0515.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0515.md | https://doc.rust-lang.org/book/ch10-03-lifetime-syntax.html |
| E0597 | https://doc.rust-lang.org/error_codes/E0597.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0597.md | https://doc.rust-lang.org/book/ch10-03-lifetime-syntax.html |
| E0716 | https://doc.rust-lang.org/error_codes/E0716.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0716.md | https://doc.rust-lang.org/book/ch10-03-lifetime-syntax.html |
| E0106 | https://doc.rust-lang.org/error_codes/E0106.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0106.md | https://doc.rust-lang.org/book/ch10-03-lifetime-syntax.html |
| E0384 | https://doc.rust-lang.org/error_codes/E0384.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0384.md | https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html |
| E0596 | https://doc.rust-lang.org/error_codes/E0596.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0596.md | https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html |
| E0594 | https://doc.rust-lang.org/error_codes/E0594.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0594.md | https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html |
| E0308 | https://doc.rust-lang.org/error_codes/E0308.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0308.md | https://doc.rust-lang.org/book/ch03-02-data-types.html |
| E0277 | https://doc.rust-lang.org/error_codes/E0277.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0277.md | https://doc.rust-lang.org/book/ch10-02-traits.html |
| E0599 | https://doc.rust-lang.org/error_codes/E0599.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0599.md | https://doc.rust-lang.org/book/ch05-03-method-syntax.html |
| E0425 | https://doc.rust-lang.org/error_codes/E0425.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0425.md | https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html |
| E0433 | https://doc.rust-lang.org/error_codes/E0433.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0433.md | https://doc.rust-lang.org/book/ch08-03-hash-maps.html |
| E0432 | https://doc.rust-lang.org/error_codes/E0432.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0432.md | https://doc.rust-lang.org/book/ch07-04-bringing-paths-into-scope-with-the-use-keyword.html |
| E0061 | https://doc.rust-lang.org/error_codes/E0061.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0061.md | https://doc.rust-lang.org/book/ch03-03-how-functions-work.html |
| E0369 | https://doc.rust-lang.org/error_codes/E0369.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0369.md | https://doc.rust-lang.org/book/ch10-01-syntax.html |
| E0381 | https://doc.rust-lang.org/error_codes/E0381.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0381.md | https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html |
| E0282 | https://doc.rust-lang.org/error_codes/E0282.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0282.md | https://doc.rust-lang.org/book/ch08-01-vectors.html |
| E0283 | https://doc.rust-lang.org/error_codes/E0283.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0283.md | https://doc.rust-lang.org/book/ch13-02-iterators.html |
| E0284 | https://doc.rust-lang.org/error_codes/E0284.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0284.md | https://doc.rust-lang.org/book/ch03-02-data-types.html |
| E0004 | https://doc.rust-lang.org/error_codes/E0004.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0004.md | https://doc.rust-lang.org/book/ch06-02-match.html |
| E0063 | https://doc.rust-lang.org/error_codes/E0063.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0063.md | https://doc.rust-lang.org/book/ch05-01-defining-structs.html |
| E0560 | https://doc.rust-lang.org/error_codes/E0560.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0560.md | https://doc.rust-lang.org/book/ch05-01-defining-structs.html |
| E0609 | https://doc.rust-lang.org/error_codes/E0609.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0609.md | https://doc.rust-lang.org/book/ch05-01-defining-structs.html |
| E0615 | https://doc.rust-lang.org/error_codes/E0615.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0615.md | https://doc.rust-lang.org/book/ch05-03-method-syntax.html |
| E0616 | https://doc.rust-lang.org/error_codes/E0616.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0616.md | https://doc.rust-lang.org/book/ch07-03-paths-for-referring-to-an-item-in-the-module-tree.html |
| E0603 | https://doc.rust-lang.org/error_codes/E0603.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0603.md | https://doc.rust-lang.org/book/ch07-03-paths-for-referring-to-an-item-in-the-module-tree.html |
| E0624 | https://doc.rust-lang.org/error_codes/E0624.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0624.md | https://doc.rust-lang.org/book/ch07-03-paths-for-referring-to-an-item-in-the-module-tree.html |
| E0046 | https://doc.rust-lang.org/error_codes/E0046.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0046.md | https://doc.rust-lang.org/book/ch10-02-traits.html |
| E0373 | https://doc.rust-lang.org/error_codes/E0373.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0373.md | https://doc.rust-lang.org/book/ch16-01-threads.html |
| E0614 | https://doc.rust-lang.org/error_codes/E0614.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0614.md | https://doc.rust-lang.org/book/ch15-02-deref.html |
| E0728 | https://doc.rust-lang.org/error_codes/E0728.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0728.md | https://doc.rust-lang.org/std/keyword.await.html |
| E0601 | https://doc.rust-lang.org/error_codes/E0601.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0601.md | https://doc.rust-lang.org/book/ch01-02-hello-world.html |
| E0072 | https://doc.rust-lang.org/error_codes/E0072.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0072.md | https://doc.rust-lang.org/book/ch15-01-box.html |
| E0023 | https://doc.rust-lang.org/error_codes/E0023.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0023.md | https://doc.rust-lang.org/book/ch06-02-match.html |
| E0317 | https://doc.rust-lang.org/error_codes/E0317.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0317.md | https://doc.rust-lang.org/book/ch03-05-control-flow.html |
| E0423 | https://doc.rust-lang.org/error_codes/E0423.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0423.md | https://doc.rust-lang.org/book/ch20-05-macros.html |
| E0606 | https://doc.rust-lang.org/error_codes/E0606.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0606.md | https://doc.rust-lang.org/reference/expressions/operator-expr.html#type-cast-expressions |
| E0368 | https://doc.rust-lang.org/error_codes/E0368.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0368.md | https://doc.rust-lang.org/book/ch08-02-strings.html |
| E0435 | https://doc.rust-lang.org/error_codes/E0435.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0435.md | https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html#constants |
| E0605 | https://doc.rust-lang.org/error_codes/E0605.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0605.md | https://doc.rust-lang.org/reference/expressions/operator-expr.html#type-cast-expressions |
| E0765 | https://doc.rust-lang.org/error_codes/E0765.html · https://github.com/rust-lang/rust/blob/master/compiler/rustc_error_codes/src/error_codes/E0765.md | https://doc.rust-lang.org/book/ch03-02-data-types.html#the-character-type |

## Errors without a code

| Entry | Rule checked against | Message text |
|---|---|---|
| syntax-missing-semicolon | https://doc.rust-lang.org/book/ch03-03-how-functions-work.html#statements-and-expressions · https://doc.rust-lang.org/reference/statements.html | rustc 1.97 output, matched on the text: expected `;` |
| syntax-unclosed-delimiter | https://doc.rust-lang.org/reference/tokens.html#delimiters | rustc 1.97 output, matched on `unclosed delimiter` |
| syntax-mismatched-delimiter | https://doc.rust-lang.org/reference/tokens.html#delimiters | rustc 1.97 output, matched on `mismatched closing delimiter` |
| syntax-unexpected-closing | https://doc.rust-lang.org/reference/tokens.html#delimiters | rustc 1.97 output, matched on `unexpected closing delimiter` |
| syntax-expected-expression | https://doc.rust-lang.org/reference/expressions.html · https://doc.rust-lang.org/book/ch03-03-how-functions-work.html#statements-and-expressions | rustc 1.97 output, matched on `expected expression` |
| syntax-increment | https://doc.rust-lang.org/reference/expressions/operator-expr.html#compound-assignment-expressions · https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html | rustc 1.97 output, matched on `increment operator` |
| syntax-decrement | https://doc.rust-lang.org/reference/expressions/operator-expr.html#compound-assignment-expressions · https://doc.rust-lang.org/book/ch03-01-variables-and-mutability.html | rustc 1.97 output, matched on `decrement operator` |
| syntax-unknown-macro | https://doc.rust-lang.org/book/ch20-05-macros.html · https://doc.rust-lang.org/std/macro.println.html | rustc 1.97 output, matched on `cannot find macro` |
| syntax-format-args | https://doc.rust-lang.org/std/fmt/index.html | rustc 1.97 output, matched on `in format string, but` |
| syntax-argument-never-used | https://doc.rust-lang.org/std/fmt/index.html | rustc 1.97 output, matched on `argument never used` |
| syntax-format-literal | https://doc.rust-lang.org/std/fmt/index.html · https://doc.rust-lang.org/std/macro.println.html | rustc 1.97 output, matched on `format argument must be a string literal` |
| syntax-unused-formatting-arguments | https://doc.rust-lang.org/std/fmt/index.html | rustc 1.97 output, matched on `unused formatting arguments` |
| syntax-invalid-format-string | https://doc.rust-lang.org/std/fmt/index.html · https://doc.rust-lang.org/book/ch01-02-hello-world.html | rustc 1.97 output, matched on `invalid format string` |
| syntax-char-literal | https://doc.rust-lang.org/book/ch03-02-data-types.html#the-character-type · https://doc.rust-lang.org/reference/tokens.html#character-literals | rustc 1.97 output, matched on `character literal may only contain one codepoint` |
| syntax-unknown-token | https://doc.rust-lang.org/reference/tokens.html | rustc 1.97 output, matched on `unknown start of token` |
| syntax-literal-out-of-range | https://doc.rust-lang.org/book/ch03-02-data-types.html#integer-types | rustc 1.97 output, matched on `literal out of range` |
