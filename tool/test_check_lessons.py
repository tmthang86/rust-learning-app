#!/usr/bin/env python3
"""Tests for the translation checks in tool/check_lessons.py.

Usage: python3 tool/test_check_lessons.py   (no rustc needed)
"""

import copy
import json
import os
import tempfile
import unittest

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
        vi["units"][0]["lessons"][0]["title"] = "Bài"
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

    def test_the_real_translations_pass(self):
        problems, _ = c.check_translations()
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
