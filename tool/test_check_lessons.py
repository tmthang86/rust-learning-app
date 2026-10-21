#!/usr/bin/env python3
"""Tests for the translation checks in tool/check_lessons.py.

Usage: python3 tool/test_check_lessons.py   (no rustc needed)
"""

import copy
import json
import os
import tempfile
import unittest

import check_errors as e
import check_lessons as c

LESSON = {
    "id": "x-l1",
    "title": "Hello",
    "sections": [
        {"type": "text", "text": "Words"},
        {"type": "code", "code": "fn main() {}"},
        {"type": "note", "text": "Careful", "track": "fast"},
    ],
    "exercise": {
        "prompt": "Print hi",
        "hints": ["one", "two"],
        "starter": "fn main() {}",
        "expectedOutput": "hi",
        "solution": "fn main() { println!(\"hi\"); }",
    },
    "quiz": [
        {"question": "Q?", "options": ["a", "b"], "answer": 1, "explanation": "Because"}
    ],
}


def translated():
    t = copy.deepcopy(LESSON)
    t["title"] = "Xin chào"
    t["sections"][0]["text"] = "Chữ"
    t["sections"][2]["text"] = "Cẩn thận"
    t["exercise"]["prompt"] = "In ra hi"
    t["exercise"]["hints"] = ["một", "hai"]
    t["quiz"][0].update(question="H?", options=["x", "y"], explanation="Vì")
    return t


class CompareTranslation(unittest.TestCase):
    def problems(self, tr):
        return c.compare_translation(LESSON, tr, "t")

    def test_texts_may_change(self):
        self.assertEqual(self.problems(translated()), [])

    def test_test_labels_are_translatable(self):
        base = copy.deepcopy(LESSON)
        base["exercise"]["tests"] = [
            {"label": "Prints hi", "expectedOutput": "hi"},
            {"label": "Hidden case", "hidden": True, "expectedOutput": "yo"},
        ]
        tr = copy.deepcopy(base)
        tr["exercise"]["tests"][0]["label"] = "In ra hi"  # visible: translated
        self.assertEqual(c.compare_translation(base, tr, "t"), [])  # hidden: copied
        tr["exercise"]["tests"][0]["expectedOutput"] = "xin chao"
        self.assertTrue(
            any("tests[0].expectedOutput" in p for p in c.compare_translation(base, tr, "t"))
        )

    def test_identical_copy_is_fine(self):
        self.assertEqual(self.problems(copy.deepcopy(LESSON)), [])

    def test_code_must_be_identical(self):
        t = translated()
        t["sections"][1]["code"] = "fn main() { }"
        self.assertTrue(any("sections[1].code" in p for p in self.problems(t)))

    def test_exercise_fields_must_be_identical(self):
        for key in ("starter", "solution", "expectedOutput"):
            t = translated()
            t["exercise"][key] += " "
            self.assertTrue(any(key in p for p in self.problems(t)), key)

    def test_ids_types_tracks_answers_must_match(self):
        for edit in (
            lambda t: t.update(id="x-l2"),
            lambda t: t["sections"][0].update(type="note"),
            lambda t: t["sections"][2].update(track="starter"),
            lambda t: t["quiz"][0].update(answer=0),
        ):
            t = translated()
            edit(t)
            self.assertTrue(self.problems(t))

    def test_answer_type_must_match(self):
        t = translated()
        t["quiz"][0]["answer"] = True
        self.assertTrue(self.problems(t))

    def test_list_lengths_must_match(self):
        for edit in (
            lambda t: t["sections"].pop(),
            lambda t: t["quiz"][0]["options"].append("z"),
            lambda t: t["exercise"]["hints"].pop(),
            lambda t: t["quiz"].append(copy.deepcopy(t["quiz"][0])),
        ):
            t = translated()
            edit(t)
            self.assertTrue(self.problems(t))

    def test_shape_must_match(self):
        for edit in (
            lambda t: t.pop("exercise"),
            lambda t: t.update(extra=1),
            lambda t: t["exercise"].pop("starter"),
            lambda t: t.update(title=["not", "a", "string"]),
            lambda t: t["quiz"][0].update(options="a"),
        ):
            t = translated()
            edit(t)
            self.assertTrue(self.problems(t))

    def test_translation_may_not_be_empty(self):
        t = translated()
        t["title"] = " "
        self.assertTrue(any("title is empty" in p for p in self.problems(t)))


class CheckTranslations(unittest.TestCase):
    def write(self, root, rel, data):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)

    def tree(self, root):
        course = {"units": [{"id": "u", "number": 1, "title": "T", "summary": "S",
                             "tracks": ["fast"], "lessons": [{"id": "x-l1", "title": "L"}]}]}
        self.write(root, "course.json", course)
        self.write(root, "lessons/x-l1.json", LESSON)
        vi = copy.deepcopy(course)
        vi["units"][0].update(title="Đ", summary="Tóm tắt")
        vi["units"][0]["lessons"][0]["title"] = "Xin chào"
        self.write(root, "vi/course.json", vi)
        self.write(root, "vi/lessons/x-l1.json", translated())

    def test_clean_tree(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            problems, summary = c.check_translations(d)
            self.assertEqual(problems, [])
            self.assertEqual(summary, ["vi: 1 of 1 lessons translated"])

    def test_orphan_and_stray_files(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            self.write(d, "vi/lessons/y-l1.json", LESSON)
            self.write(d, "vi/notes.json", {})
            problems, _ = c.check_translations(d)
            self.assertTrue(any("orphan" in p for p in problems))
            self.assertTrue(any("notes.json" in p for p in problems))

    def test_course_mismatch_and_wrong_id(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            with open(os.path.join(d, "vi/course.json"), encoding="utf-8") as f:
                vi = json.load(f)
            vi["units"][0]["tracks"] = ["starter"]
            self.write(d, "vi/course.json", vi)
            self.write(d, "vi/lessons/x-l1.json", dict(translated(), id="x-l2"))
            problems, _ = c.check_translations(d)
            self.assertTrue(any("tracks" in p for p in problems))
            self.assertTrue(any("id" in p for p in problems))

    def test_non_locale_folders_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            self.write(d, "errors/vi.json", {"anything": 1})
            problems, summary = c.check_translations(d)
            self.assertEqual(problems, [])
            self.assertEqual(len(summary), 1)

    def test_lesson_title_must_match_the_course_map(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            t = translated()
            t["title"] = "Khác"
            self.write(d, "vi/lessons/x-l1.json", t)
            problems, _ = c.check_translations(d)
            self.assertTrue(any("course.json" in p and "title" in p for p in problems))

    def test_course_titles_are_scanned_for_code(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            with open(os.path.join(d, "course.json"), encoding="utf-8") as f:
                en = json.load(f)
            en["units"][0]["title"] = "Box<T> and println!"
            self.write(d, "course.json", en)
            with open(os.path.join(d, "vi/course.json"), encoding="utf-8") as f:
                vi = json.load(f)
            vi["units"][0]["title"] = "Box và println"
            self.write(d, "vi/course.json", vi)
            problems, _ = c.check_translations(d)
            self.assertTrue(any("vi/course.json" in p and "Box<T>" in p for p in problems))

    def test_region_folders_are_checked(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            os.rename(os.path.join(d, "vi"), os.path.join(d, "pt-BR"))
            bad = translated()
            bad["exercise"]["starter"] = "x"
            self.write(d, "pt-BR/lessons/x-l1.json", bad)
            problems, summary = c.check_translations(d)
            self.assertTrue(any("pt-BR/lessons/x-l1.json" in p for p in problems))
            self.assertEqual(summary, ["pt-BR: 0 of 1 lessons translated"])

    def test_a_copy_of_the_english_file_is_not_counted_as_translated(self):
        with tempfile.TemporaryDirectory() as d:
            self.tree(d)
            with open(os.path.join(d, "vi/course.json"), encoding="utf-8") as f:
                vi = json.load(f)
            vi["units"][0]["lessons"][0]["title"] = LESSON["title"]
            self.write(d, "vi/course.json", vi)
            self.write(d, "vi/lessons/x-l1.json", LESSON)
            problems, summary = c.check_translations(d)
            self.assertEqual(problems, [])
            self.assertEqual(summary, ["vi: 0 of 1 lessons translated"])

    def test_the_real_translations_pass(self):
        problems, _ = c.check_translations()
        self.assertEqual(problems, [])


CODE_LESSON = {
    "id": "c-l1",
    "title": "Decisions",
    "sections": [
        {"type": "text", "text": 'Read let apples = 5; as "let apples be 5". The = sign means "store this value", not "is equal to".'},
        {"type": "text", "text": "Use if age == 18 { ... } and println! to say it, or call greet(); later."},
        {"type": "code", "code": 'fn main() {\n    println!("Grade A");\n}'},
    ],
    "exercise": {
        "prompt": "Print Grade A with println!",
        "hints": ["Use println!(\"Grade A\");"],
        "starter": "fn main() {}",
        "expectedOutput": "Grade A",
        "solution": 'fn main() { println!("Grade A"); }',
    },
    "quiz": [
        {"question": "Which operator compares two values?", "options": ["=", "==", "=>"], "answer": 1, "explanation": "Use == to compare."},
        {"question": "What does the program print?", "options": ["Grade A", "Grade B", "Nothing at all"], "answer": 0, "explanation": "It prints Grade A."},
        {"question": "Which line stores 5?", "options": ["let x = 5;", "Stores five", "const x = 5;"], "answer": 0, "explanation": "let stores."},
    ],
}


def vi_code_lesson():
    t = copy.deepcopy(CODE_LESSON)
    t["title"] = "Quyết định"
    t["sections"][0]["text"] = 'Hãy đọc let apples = 5; như "gán 5 cho apples". Dấu = có nghĩa là "lưu giá trị này", không phải "bằng nhau".'
    t["sections"][1]["text"] = "Dùng if age == 18 { ... } và println! để nói điều đó, hoặc gọi greet(); sau."
    t["exercise"]["prompt"] = "In ra Grade A bằng println!"
    t["exercise"]["hints"] = ['Dùng println!("Grade A");']
    t["quiz"][0].update(question="Toán tử nào so sánh hai giá trị?", explanation="Dùng == để so sánh.")
    t["quiz"][1].update(question="Chương trình in ra gì?", options=["Grade A", "Grade B", "Không có gì cả"], explanation="Nó in ra Grade A.")
    t["quiz"][2].update(question="Dòng nào lưu số 5?", options=["let x = 5;", "Lưu số năm", "const x = 5;"], explanation="let lưu giá trị.")
    return t


class CodeInProse(unittest.TestCase):
    def problems(self, tr):
        en = CODE_LESSON
        found = c.compare_translation(en, tr, "t")
        return found or c.compare_code(en, tr, "t", c.lesson_vocabulary(en))

    def test_a_faithful_translation_passes(self):
        self.assertEqual(self.problems(vi_code_lesson()), [])

    def test_natural_language_quotes_may_be_translated(self):
        # "let apples be 5" is not in the lesson's code, so it is words.
        t = vi_code_lesson()
        self.assertNotIn("let apples be 5", t["sections"][0]["text"])
        self.assertEqual(self.problems(t), [])

    def test_changed_operator_in_prose(self):
        t = vi_code_lesson()
        t["sections"][1]["text"] = t["sections"][1]["text"].replace("==", "=")
        self.assertTrue(any("'=='" in p for p in self.problems(t)))

    def test_changed_value_in_prose(self):
        t = vi_code_lesson()
        t["sections"][0]["text"] = t["sections"][0]["text"].replace("= 5;", "= 6;")
        self.assertTrue(any("sections[0].text" in p for p in self.problems(t)))

    def test_missing_macro_or_call_in_prose(self):
        for old in ("println!", "greet();"):
            t = vi_code_lesson()
            t["sections"][1]["text"] = t["sections"][1]["text"].replace(old, "")
            self.assertTrue(any(repr(old) in p for p in self.problems(t)), old)

    def test_code_options_must_be_identical(self):
        for i, j, value in ((0, 0, "=="), (0, 2, "=="), (1, 0, "Điểm A"), (2, 0, "let x = 6;"), (2, 2, "var x = 5;")):
            t = vi_code_lesson()
            t["quiz"][i]["options"][j] = value
            self.assertTrue(
                any("must stay" in p for p in self.problems(t)), (i, j, value)
            )

    def test_quoted_program_output_in_prose_must_stay(self):
        t = vi_code_lesson()
        t["exercise"]["prompt"] = 'In ra Điểm A bằng println!'
        self.assertTrue(any("exercise.prompt" in p for p in self.problems(t)))
        t["exercise"]["prompt"] = 'In ra "Điểm A" bằng println!'
        self.assertTrue(any("exercise.prompt" in p for p in self.problems(t)))

    def test_word_options_may_be_translated(self):
        t = vi_code_lesson()
        self.assertEqual(t["quiz"][1]["options"][2], "Không có gì cả")
        self.assertEqual(self.problems(t), [])

    def test_tampering_with_a_real_translated_lesson_is_found(self):
        def load(*parts):
            with open(os.path.join(c.CONTENT, *parts), encoding="utf-8") as f:
                return json.load(f)

        en = load("lessons", "u0-l3.json")
        vi = load("vi", "lessons", "u0-l3.json")
        vocab = c.lesson_vocabulary(en)
        self.assertEqual(c.compare_code(en, vi, "t", vocab), [])

        t = copy.deepcopy(vi)
        t["quiz"][1]["options"] = ["=", "=", "=>"]  # the right answer changes
        self.assertTrue(c.compare_code(en, t, "t", vocab))

        t = copy.deepcopy(vi)
        t["quiz"][2]["options"][0] = "Điểm A"  # program output translated
        self.assertTrue(c.compare_code(en, t, "t", vocab))

        t = copy.deepcopy(vi)
        section = t["sections"][3]
        section["text"] = section["text"].replace("==", "=")  # if age = 18
        self.assertTrue(c.compare_code(en, t, "t", vocab))

    def test_ordinary_prose_is_not_flagged(self):
        # From the real lessons: output-like words and "unsafe" as plain English.
        def real(lid):
            with open(os.path.join(c.CONTENT, "lessons", lid + ".json"), encoding="utf-8") as f:
                en = json.load(f)
            return en, c.lesson_vocabulary(en)

        en, v = real("u11-l3")
        text = "Rc's counter is unsafe across threads, so the compiler rejects Rc there"
        self.assertEqual(c.missing_code(text, "Bộ đếm của Rc không an toàn giữa các thread, nên compiler từ chối Rc ở đó", v), [])
        en, v = real("u6-l1")
        self.assertEqual(c.missing_code("It gives back a Result, not a number.", "Nó trả về một Result, không phải một con số.", v), [])
        en, v = real("u10-l2")
        self.assertEqual(c.missing_code("At the end of main the values drop.", "Ở cuối main, các giá trị bị drop.", v), [])
        # ...but output after "prints" or a colon is still output.
        en, v = real("u0-l3")
        self.assertEqual(c.missing_code("it prints Even when ok", "nó in ra Chẵn khi đúng", v), ["Even"])
        self.assertEqual(c.missing_code("It should print: Even", "Nó nên in: Even", v), [])

    def test_let_is_code_only_in_code_shape(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        for prose in (
            "The compiler won't let you do that.",
            "How do you let several threads send into one channel?",
            "Use a match when you move on, in a loop; the type is where it lives.",
        ):
            self.assertFalse(c.code_tokens(prose, vocab), prose)
        for text in ("Write let x = 5; first", "Use let mut total = 0;", "Try let (a, b) = pair;"):
            self.assertEqual(c.code_tokens(text, vocab)["let"], 1, text)
        self.assertIn("let", c.missing_code("Write let x = 5; first", "Hãy viết var x = 5; trước", vocab))
        self.assertEqual(c.missing_code("It won't let you", "Nó không cho phép bạn", vocab), [])

    def test_other_keywords_are_code_wherever_they_appear(self):
        # The review's tampering table: each of these must be found.
        vocab = c.lesson_vocabulary(CODE_LESSON)
        cases = [
            ("Add mut to allow changes:", "Thêm const để cho phép thay đổi:", "mut"),
            ("Functions are declared with fn.", "Hàm được khai báo bằng def.", "fn"),
            (
                "A module has pub struct Account { pub owner: String, balance: i64 }.",
                "Một module có struct Account { owner: String, balance: i64 }.",
                "pub",
            ),
            ("The word pub in front of an item", "Từ const đặt trước một mục", "pub"),
            ("Write impl fmt::Display for ShopError", "Viết fmt::Display for ShopError", "impl"),
            ("The parameter type impl Fn(i32) -> i32", "Kiểu tham số dyn Fn(i32) -> i32", "impl"),
            ("Why impl<T> Point<T> and not impl Point<T>?", "Vì sao Point<T>?", "impl"),
            ("Declare struct Player here", "Khai báo enum Player ở đây", "struct"),
            ("Use for mut x in &v here", "Dùng for x in &v ở đây", "mut"),
        ]
        for en, tr, keyword in cases:
            self.assertIn(keyword, c.missing_code(en, tr, vocab), en)
        # Kept as loanwords, they pass.
        self.assertEqual(
            c.missing_code("Add mut to allow changes:", "Thêm mut để cho phép thay đổi:", vocab), []
        )

    def test_keyword_only_options_must_be_identical(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        for option in ("mut", "let", "const", "pub", "fn", "impl", "dyn", "struct", "enum",
                       "mod", "let mut", "pub struct", "mut self"):
            self.assertTrue(c.is_code_option(option, vocab), option)
            found = c.compare_code_text([option], ["từ khóa"], "t", vocab, "$.options", option=True)
            self.assertTrue(found and "must stay" in found[0], option)
        self.assertFalse(c.is_code_option("Before fn", vocab))
        self.assertFalse(c.is_code_option("It lets you", vocab))

    def test_prose_in_parentheses_is_not_an_argument_list(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        self.assertFalse(c.code_tokens("Some(that variable) holds it", vocab))
        self.assertEqual(
            c.missing_code("Some(that variable) holds it", "Some chứa biến đó", vocab), []
        )
        self.assertTrue(c.code_tokens("Use Some(value) or add(2, 3)", vocab))

    def test_code_made_of_words_in_parentheses_is_kept(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        cases = [
            ("Call v.get(i as usize) here", "Gọi v.get(j as isize) ở đây"),
            ("Match Some(ref x) here", "Khớp Some(x) ở đây"),
            ("Write fn rename(mut self) here", "Viết fn rename(self) ở đây"),
            ("Use print_it(mut value) here", "Dùng print_it(value) ở đây"),
        ]
        for en, tr in cases:
            self.assertTrue(c.missing_code(en, tr, vocab), en)

    def test_quoted_text_only_in_a_comment_is_not_output(self):
        lesson = {
            "sections": [
                {"type": "code", "code": 'fn main() {\n    // say "not ready yet" later\n    println!("go");\n}'},
                {"type": "code", "code": 'println!("hi");\n// Output:\n// hi'},
            ],
        }
        vocab = c.lesson_vocabulary(lesson)
        self.assertNotIn("not ready yet", vocab["literals"])
        self.assertNotIn("not ready yet", vocab["printed"])
        self.assertIn("go", vocab["literals"])
        self.assertIn("hi", vocab["literals"])  # an "// Output:" line is output
        self.assertFalse(c.code_tokens('It says "not ready yet" to you', vocab))

    def test_commented_out_code_still_counts_as_code(self):
        lesson = {
            "sections": [
                {"type": "code", "code": 'fn main() {\n    // println!("{a}");\n    // total = 1;\n    // calls foo(1)\n}'},
            ],
        }
        vocab = c.lesson_vocabulary(lesson)
        self.assertIn("{a}", vocab["literals"])
        self.assertIn("total = 1;", vocab["literals"])
        en = 'Try println!("{a}") to see it'
        self.assertEqual(c.missing_code(en, 'Thử println!("{a}") để xem', vocab), [])
        self.assertTrue(c.missing_code(en, 'Thử println!("{b}") để xem', vocab))

    def test_token_counts_matter(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        en = "Use if age == 18 { ... } else if age == 19 { ... } to decide."
        ok = "Dùng if age == 18 { ... } else if age == 19 { ... } để quyết định."
        bad = "Dùng if age == 18 { ... } else if age = 19 { ... } để quyết định."
        self.assertEqual(c.missing_code(en, ok, vocab), [])
        self.assertEqual(c.missing_code(en, bad, vocab), ["=="])
        self.assertEqual(c.missing_code("Use = and ==", "Dùng == và ==", vocab), ["="])

    def test_titles_are_scanned(self):
        en = copy.deepcopy(CODE_LESSON)
        en["title"] = "Using Box<T> and println!"
        vocab = c.lesson_vocabulary(en)
        ok = dict(copy.deepcopy(en), title="Dùng Box<T> và println!")
        bad = dict(copy.deepcopy(en), title="Dùng Box và println")
        self.assertEqual(c.compare_code(en, ok, "t", vocab), [])
        found = c.compare_code(en, bad, "t", vocab)
        self.assertTrue(found and "Box<T>" in found[0])

    def test_ordinary_words_are_not_code(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        for text in (
            "Great job! Keep going, it's easy; you'll see: it works.",
            "Think of it as a box (called a variable) that holds one value.",
            "Use a loop when you repeat something - again and again.",
        ):
            self.assertFalse(c.code_tokens(text, vocab), text)

    def test_real_code_is_found(self):
        vocab = c.lesson_vocabulary(CODE_LESSON)
        found = c.code_tokens(
            'Call greet(); then Vec<i32> and std::fmt, a == b, use &mut v or "Grade A".',
            vocab,
        )
        for token in ("greet();", "Vec<i32>", "std::fmt", "==", "&mut", '"Grade A"'):
            self.assertIn(token, found)


class ErrorTranslations(unittest.TestCase):
    EN = {
        "title": "Using a value after it was moved",
        "explanation": "Borrow with &name, or use i32 for Copy types. See E0382.",
        "fixes": ["Write &name so the owner keeps it.", "Call .clone() for a copy."],
    }

    def problems(self, tr):
        found = []
        e.check_translation("E0382", self.EN, tr, "vi.json", found)
        return found

    def test_faithful_translation_passes(self):
        tr = {
            "title": "Dùng giá trị sau khi đã move",
            "explanation": "Hãy mượn bằng &name, hoặc dùng i32 cho kiểu Copy. Xem E0382.",
            "fixes": ["Viết &name để chủ sở hữu giữ lại.", "Gọi .clone() để lấy một bản sao."],
        }
        self.assertEqual(self.problems(tr), [])

    def test_changed_code_and_fix_count_are_found(self):
        tr = {
            "title": "x",
            "explanation": "Hãy mượn bằng &tên, hoặc dùng i64. Xem E0383.",
            "fixes": ["Gọi .clone()"],
        }
        found = "\n".join(self.problems(tr))
        for expected in ("1 fixes", "&name", "i32", "E0382"):
            self.assertIn(expected, found)


if __name__ == "__main__":
    unittest.main()
