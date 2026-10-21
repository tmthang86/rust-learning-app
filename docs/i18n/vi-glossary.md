# Vietnamese glossary and tone

For translators of the UI (`lib/l10n/app_vi.arb`) and course content
(`assets/content/vi/`). Rules and file layout: [README.md](README.md).

## Tone

- **Address the learner as "bạn".** Never "các bạn", "quý khách", "em" or "anh/chị".
  When the lesson walks through something together, "chúng ta" is fine (the
  English says "let's", "we").
- **The app speaks as "chúng tôi"** in system messages ("Chúng tôi không thể xác
  nhận ..."), and avoids it elsewhere. Buttons that say "I" use "Tôi" ("Tôi mới
  học lập trình").
- **Friendly, plain, not childish.** Short sentences. No emoji, no slang, no
  "nhé" except to soften a retry nudge ("Hãy tiếp tục thử nhé.").
- **"Hãy" or "Vui lòng".** "Hãy ..." is the teacher's voice: instructions and
  coaching in lessons, hints, quiz and exercise feedback, and the empty-code nudge
  ("Hãy nhìn ba dòng bên trong ...", "Hãy xem lại bài học và thử lại."). "Vui lòng
  ..." is the system's voice: every request that follows an error, a failure or a
  warning from the app, the runner, the account service or the store ("Vui lòng
  kiểm tra kết nối mạng và thử lại."). Never mix them inside one message.
- **Sentence case.** Capitalise the first word and proper names only
  ("Quyền sở hữu", not "Quyền Sở Hữu"; the Vietnamese Rust book title-cases
  headings, we don't).
- **Faithful.** Don't add, drop or soften facts. Legal and consent text (age
  screen, account deletion, sign-out warning, purchase text) keeps the exact
  meaning, including "vĩnh viễn" (permanently), "không thể hoàn tác" (can't be
  undone), "tất cả thiết bị" (all devices).
- **Loanwords stay as written in English** (no hyphenated or phonetic spellings:
  "closure", not "clô-giơ"), lower case, never pluralised ("các closure", not
  "closures"). Give a Vietnamese gloss in brackets the first time a term appears
  in a lesson when the table below says so.
- **Don't translate**: code, comments inside code, identifiers, macro names,
  keywords (`let`, `mut`, `fn`), type names (`String`, `Vec`, `Option`), quoted
  program output (`Grade A`), error codes (`E0308`), file and command names
  (`Cargo.toml`, `cargo run`), brand names (Learn Rust, Rust, Cargo, Google,
  Apple, Firebase, App Store, Google Play).
- **Numbers and punctuation.** Keep `3.5` as in code. Use Vietnamese punctuation
  in prose; keep quotation marks as plain `"` around quoted code or text.
- **Learner-facing "code"** is written "code" ("code của bạn"), not "mã".

## Terms

"Keep" means written in English; "gloss" means add the Vietnamese in brackets at
first use in a lesson (and, in titles, where the table says so).

### Everyday programming

| English | Vietnamese | Note |
| --- | --- | --- |
| program | chương trình | |
| code (noun) | code | "đoạn code" for a snippet |
| compile / compiler | biên dịch / trình biên dịch | gloss "(compiler)" at first use |
| compiler error / warning | lỗi biên dịch / cảnh báo (của trình biên dịch) | |
| run | chạy | button "Chạy" |
| build / build tool | build / công cụ build | keep |
| variable | biến | |
| value | giá trị | |
| type | kiểu | "kiểu dữ liệu" for "data type" |
| expression / statement | biểu thức / câu lệnh | |
| function | hàm | |
| method | phương thức | |
| parameter / argument | tham số / đối số | |
| return value / "gives back" | giá trị trả về / trả về | |
| comment | chú thích | gloss "(comment)" in Unit 0 |
| condition | điều kiện | |
| loop | vòng lặp | `for`, `while`, `loop` keep |
| range (`1..=5`) | dãy số (range) | |
| placeholder (`{}`) | ô giữ chỗ (placeholder) | |
| array | mảng | |
| tuple | tuple | keep |
| scalar types | kiểu scalar | keep; the Vietnamese book also uses "vô hướng" |
| string | chuỗi | `String` and `&str` keep as type names |
| string slice | chuỗi slice (`&str`) | |
| slice | slice | keep |
| vector | vector | keep |
| hash map | HashMap | prose may say "bảng băm (hash map)" |
| collection | collection | keep; "tập hợp dữ liệu (collection)" in an explanation |
| struct | struct | keep |
| field | trường | |
| enum | enum | keep |
| variant | variant | keep (the Vietnamese book writes "biến thể") |
| exercise / lesson / quiz / hint / solution | bài tập / bài học / bài kiểm tra (UI), câu hỏi (in a quiz) / gợi ý / lời giải | |
| learner | bạn | |

### Rust concepts

| English | Vietnamese | Note |
| --- | --- | --- |
| ownership | quyền sở hữu | gloss "(ownership)" in titles and at first use |
| borrowing / borrow | mượn (borrowing) | gloss at first use |
| borrow checker | borrow checker | keep; "trình kiểm tra mượn" at first use |
| reference | tham chiếu | |
| mutable reference | tham chiếu có thể thay đổi (`&mut`) | the Rust book translation uses exactly "tham chiếu có thể thay đổi" (ch. 4.2); keep the `(&mut)` gloss in titles so it is clear what is meant |
| move (the concept) | di chuyển (move) / "move" | the keyword `move` stays |
| copy / clone | `Copy` / `Clone` | keep (trait names) |
| mutable / mutability | có thể thay đổi / tính có thể thay đổi | `mut` keep |
| immutable | bất biến | plain wording: "không thể thay đổi" |
| shadowing | shadowing | keep; "che khuất" may be used as a gloss |
| scope | phạm vi | |
| stack / heap | stack / heap | keep |
| garbage collector | bộ thu gom rác (garbage collector) | |
| lifetime | lifetime | keep; "thời gian sống" as a gloss |
| trait | trait | keep |
| trait bound | ràng buộc trait (trait bound) | |
| generic (adj.) | generic | "hàm generic", "kiểu generic" |
| pattern | mẫu (pattern) | |
| pattern matching | so khớp mẫu | `match` keep |
| match arm | nhánh | "nhánh `match`" |
| macro | macro | keep (`println!` is "macro `println!`") |
| attribute (`#[derive]`) | attribute | keep |
| closure | closure | keep |
| capture (a variable) | capture | keep; "nắm bắt" as a gloss |
| iterator | iterator | keep |
| iterator adapter | adapter | keep (the Vietnamese book writes "bộ điều hợp") |
| consume (an iterator) | tiêu thụ | |
| module | module | keep |
| crate | crate | keep |
| package / workspace | package / workspace | keep |
| visibility (`pub`) | visibility; công khai / riêng tư | |
| test / unit test | test / unit test | keep in titles, summaries and prose ("viết test"); "kiểm thử" only as a gloss |
| panic | panic | keep as noun and verb ("gây ra panic") |
| error handling | xử lý lỗi | |
| recoverable / unrecoverable error | lỗi có thể khôi phục / không thể khôi phục | |
| `Result`, `Option`, `Some`, `None`, `Ok`, `Err` | keep | |
| `?` operator | toán tử `?` | |
| custom error type | kiểu lỗi tùy chỉnh | |
| smart pointer | con trỏ thông minh (smart pointer) | |
| `Box`, `Rc`, `Arc`, `RefCell`, `Mutex`, `Deref`, `Drop` | keep | |
| reference counting | đếm tham chiếu | |
| interior mutability | interior mutability | keep |
| concurrency | đồng thời (concurrency) | "đa luồng" for multithreading |
| thread | thread | keep; "luồng" is understood and may be used in plain prose |
| channel | channel | keep (it is the API name, `mpsc::channel`); "kênh" as a gloss. The Rust book translation writes "kênh" throughout (81 uses); we keep the English word because learners meet it in code |
| message passing | truyền thông điệp | |
| shared state | trạng thái chia sẻ | |
| data race / deadlock | data race / deadlock | keep |
| async / await / future | keep | |
| command-line tool (CLI) | công cụ dòng lệnh (CLI) | |
| web server | máy chủ web | |

### Terms used in Units 1-12

Chosen while translating the lessons. Where earlier tables already list a term,
that row wins.

**Kept in English** (lower case, not pluralised; gloss only where noted):
implement, override, annotation, lifetime annotation, elision rules, orphan rule,
destructor, unwind, parse, exception, type erasure, monomorphization, trait
object, fat pointer, static/dynamic dispatch, vtable, deref coercion, turbofish,
workspace, integration test, doctest, atomic, runtime, executor, polling, lazy,
thread pool, worker, handle, guard, prelude, marker trait, tuple struct, match
guard, combinator, literal, destructuring.

**Always glossed at first use in a lesson**: *dangling pointer* is "con trỏ treo
(dangling pointer)" and *dangling reference* is "tham chiếu treo (dangling
reference)" (not the bare English word in one lesson and a gloss in another).

| English | Vietnamese | Note |
| --- | --- | --- |
| Unit N / unit | Unit N / unit | keep; the UI shows only the number |
| dependency | dependency (thư viện phụ thuộc) | gloss at first use |
| format string | chuỗi định dạng (format string) | |
| index | chỉ số | |
| signed / unsigned | có dấu / không dấu | |
| floating-point | số thực dấu phẩy động | |
| overflow | tràn (overflow) | |
| cast | ép kiểu | |
| owner | chủ sở hữu | |
| caller | bên gọi | |
| shared reference | tham chiếu chia sẻ | |
| immutable reference | tham chiếu bất biến | |
| borrow checker | borrow checker (trình kiểm tra mượn) | |
| dereference | giải tham chiếu | |
| associated function | hàm liên kết | |
| constructor | hàm khởi tạo | |
| type parameter | tham số kiểu | |
| where clause | mệnh đề where | `where` keep |
| default method | phương thức mặc định | |
| associated type | kiểu liên kết | |
| consumer | consumer (bộ tiêu thụ) | |
| type annotation | khai báo kiểu | |
| angle brackets / curly braces | dấu ngoặc góc / ngoặc nhọn | |
| key (of a map) | khóa | |
| pure function | hàm thuần túy | |
| state machine | máy trạng thái | |
| port | cổng | |
| starter code | code khởi đầu | |
| "Coming from another language:" | Nếu bạn đến từ một ngôn ngữ khác: | |
| "It should print:" | Chương trình phải in ra: | |

Keywords (`let`, `struct`, `enum`, `impl`, ...) are English words too. In prose,
translate the word when it is a plain word ("won't let you" -> "không cho phép
bạn"); keep the keyword when it names the code (`let x = 5;`, `struct Game {`,
`impl Speak for Robot`). The checker only enforces the code shape.

### UI words

| English | Vietnamese |
| --- | --- |
| Learn / Playground / Progress | Học / Thử code / Tiến độ |
| Sign in / Sign out | Đăng nhập / Đăng xuất |
| Delete account | Xóa tài khoản |
| Continue / Cancel / Back | Tiếp tục / Hủy / Quay lại |
| Check / Next (quiz) | Kiểm tra / Tiếp theo |
| Run / Reset | Chạy / Đặt lại |
| Remove ads / Restore purchases | Gỡ quảng cáo / Khôi phục giao dịch mua |
| Language: System / English / Tiếng Việt | Hệ thống / English / Tiếng Việt |

## Where these choices come from

- **tuanemdev/rust-book-vn**
  (https://github.com/tuanemdev/rust-book-vn, folder `src-vi`), the Vietnamese
  translation of *The Rust Programming Language* that the book's own Appendix F
  lists (https://doc.rust-lang.org/book/appendix-06-translation.html). I read its
  chapters and counted how it renders the terms (about 100 chapter files, snapshot
  of 2026-10). It consistently translates *quyền sở hữu* (ownership, 138
  uses), *mượn* (borrowing, 121), *tham chiếu* (reference, 589), *xử lý lỗi*
  (44), *con trỏ thông minh* (57), *đồng thời* (concurrency, 104), *kênh*
  (channel, 81), *phương thức*, *hàm*, *biến*, *biên dịch*; it keeps *trait*
  (739), *struct* (465), *enum* (262), *macro* (299), *crate* (526), *module*
  (307), *closure* (290), *iterator* (237), *generic* (227), *lifetime* (278,
  against 9 for "thời gian sống"), *slice* (167), *vector* (177), *stack*/*heap*,
  *Result*/*Option*. It is mixed on *thread* (419) versus *luồng* (299), *panic*
  (209) versus *hoảng loạn* (30) and *shadowing* (8) versus *che khuất* (20),
  and uses *bất biến* (72) for immutable, *biến thể* (156) for variant,
  *bộ điều hợp* (14) for adapter and *bộ giá trị* (18) beside *tuple* (121). I
  followed it where it is clear and where Vietnamese developers would
  recognise the word, and chose myself where it is mixed (noted in the tables).
  It is a community translation; I did not find a review process for its
  terminology, so treat it as evidence of usage, not an authority.
- **No other authoritative Vietnamese source found.** MDN's Vietnamese pages
  redirect to the English ones, so there is no MDN glossary to follow. I found
  no Vietnamese translation of the Python documentation with a published
  glossary (a discuss.python.org thread announces one at a very early stage:
  https://discuss.python.org/t/starting-vietnamese-translation/107028), and my
  searches for an accepted Vietnamese term for *closure* or *iterator* found
  nothing authoritative. Vietnamese Wikipedia pages I tried were not reachable.
  The decision to keep these terms in English is mine, based on how Vietnamese
  developers speak and on the Rust book translation above. Please correct it if
  you know better.
- **Brand and legal wording** follows the English text word for word; see the
  `@description` notes in `lib/l10n/app_en.arb`.

## Terms worth a second look

- *Thử code* for the "Playground" tab (literal "sân chơi" is rarely used).
- *Mới học code* / *Đã có kinh nghiệm* for the learning-track switch.
- *Tiến độ* for "Progress" (alternative: "Tiến trình").
- *Kết quả* for the editor's "Output" heading (alternative: "Đầu ra"); the
  screen-reader line says "Kết quả: ...".
- *Bất biến* versus *không thể thay đổi* for "immutable".
- "Learn Rust" is kept as the app's name in Vietnamese; the home title and the
  task switcher show it unchanged.
