"""Offline checks for script/mutation.py: which lines it mutates, how, and how it reads a run.

    python3 -I script/test_mutation.py
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "mutation-fixtures"


def mutated(line: str) -> list[tuple[str, str]]:
    """(operator, mutated line) for every mutant of one line of code."""
    code = mutation.mask(line)
    return [(m.operator, m.mutated) for m in mutation.mutants_for_line("A.swift", 1, line, code)]


class ChangedLinesTests(unittest.TestCase):
    def test_reads_the_new_side_of_each_hunk(self):
        diff = "\n".join([
            "diff --git a/Sources/A.swift b/Sources/A.swift",
            "--- a/Sources/A.swift",
            "+++ b/Sources/A.swift",
            "@@ -3,0 +4,2 @@ struct A {",
            "+    let a = 1",
            "+    let b = 2",
            "@@ -10 +12 @@ func f() {",
            "-    old()",
            "+    new()",
            "@@ -20,3 +21,0 @@",
            "-    gone()",
            "diff --git a/Sources/B.swift b/Sources/B.swift",
            "--- a/Sources/B.swift",
            "+++ /dev/null",
            "@@ -1,2 +0,0 @@",
            "-x",
        ])
        self.assertEqual(mutation.changed_lines(diff), {"Sources/A.swift": {4, 5, 12}})


class MaskTests(unittest.TestCase):
    def test_comments_and_strings_become_spaces_and_columns_stay(self):
        source = 'let a = b == c // d == e\n/* f == g\n /* nested */ h == i */ j == k\nlet s = "x == y"\n'
        masked = mutation.mask(source)
        self.assertEqual(len(masked), len(source))
        self.assertEqual([line.rstrip() for line in masked.split("\n")],
                         ["let a = b == c", "", " " * 24 + "j == k", 'let s = "      "', ""])

    def test_raw_and_multiline_strings(self):
        source = 'let r = #"a " == b"# == c\nlet m = """\n  d == e\n  """ == f\n'
        masked = mutation.mask(source).split("\n")
        self.assertNotIn("== b", masked[0])
        self.assertTrue(masked[0].rstrip().endswith("== c"))
        self.assertEqual(masked[2].strip(), "")
        self.assertTrue(masked[3].rstrip().endswith("== f"))

    def test_interpolation_is_code_and_its_strings_are_not(self):
        masked = mutation.mask('let s = "\\(f("x == y") == z) == w"')
        self.assertEqual(masked.count("=="), 1)
        self.assertIn(") == z)", masked)


class OperatorTests(unittest.TestCase):
    def test_each_operator(self):
        self.assertEqual(mutated("if a == b, c != d {"),
                         [("== to !=", "if a != b, c != d {"), ("!= to ==", "if a == b, c == d {")])
        self.assertEqual(mutated("x = a && b || c"),
                         [("&& to ||", "x = a || b || c"), ("|| to &&", "x = a && b && c"),
                          ("statement deleted", "")])
        self.assertEqual(mutated("return true"), [("true to false", "return false")])
        self.assertEqual(mutated("guard ok else { return false }"), [("false to true", "guard ok else { return true }")])
        self.assertEqual(mutated("if a < b, c <= d, e > f, g >= h {"),
                         [("< to <=", "if a <= b, c <= d, e > f, g >= h {"), ("<= to <", "if a < b, c < d, e > f, g >= h {"),
                          ("> to >=", "if a < b, c <= d, e >= f, g >= h {"), (">= to >", "if a < b, c <= d, e > f, g > h {")])

    def test_a_comparison_with_a_bool_literal_is_one_mutant(self):
        self.assertEqual(mutated("if a.isEmpty == false {"), [("compared Bool flipped", "if a.isEmpty == true {")])
        self.assertEqual(mutated("if a != true {"), [("compared Bool flipped", "if a != false {")])

    def test_types_arrows_identity_comments_and_strings_are_left_alone(self):
        for line in ["func f(_ a: Array<Int>) -> Set<String> {", "if a === b, c !== d {",
                     "// if a == b && c { return true }", 'let s = "a == b && true"']:
            self.assertEqual(mutated(line), [], line)

    def test_statement_deletion(self):
        for line in ["    self.send(.download)", "    try await operations.unload()", "    runningTask?.cancel()",
                     "    hasPartialDownload = partial", "    count += 1", "    _ = set.insert(key)"]:
            self.assertEqual(mutated(line)[-1], ("statement deleted", "    "), line)
        for line in ["    let x = f()", "    return f()", "    x == y", "    foo(a,", "    super.init()",
                     "    try fileManager.createDirectory(at: parent) {", "    case .a = b"]:
            self.assertNotIn("statement deleted", [operator for operator, _ in mutated(line)], line)

    def test_only_changed_lines(self):
        source = "a = b == c\nd = e == f\ng = h == i\n"
        found = mutation.mutants_for_file("A.swift", source, {2})
        self.assertEqual({m.line for m in found}, {2})


class SelectionTests(unittest.TestCase):
    def mutants(self, count):
        return [mutation.Mutant("A.swift", n, "a == b", "a != b", "== to !=") for n in range(1, count + 1)]

    def test_the_limit_is_kept_and_the_choice_repeats(self):
        picked = mutation.select(self.mutants(30), 7)
        self.assertEqual(len(picked), 7)
        self.assertEqual(picked, mutation.select(list(reversed(self.mutants(30))), 7))
        self.assertEqual([m.line for m in picked], sorted(m.line for m in picked))

    def test_an_entry_names_which_of_identical_lines_it_means(self):
        source = "func a() {\n    remember(key)\n}\nfunc b() {\n    remember(key)\n}\n"
        first, second = mutation.mutants_for_file("A.swift", source, {2, 5})
        self.assertNotEqual(first.key, second.key)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "equivalent.json"
            path.write_text(json.dumps({"equivalent": [{"file": "A.swift", "original": "remember(key)", "mutated": "",
                                                        "occurrence": 2, "reason": "b never runs"}]}))
            self.assertEqual(mutation.load_equivalent(path), {second.key})

    def test_equivalent_entries_need_a_reason_and_match_by_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "equivalent.json"
            path.write_text(json.dumps({"equivalent": [
                {"file": "A.swift", "original": "  a == b ", "mutated": "a != b", "reason": "a and b are always equal"}]}))
            self.assertEqual(mutation.load_equivalent(path), {("A.swift", "a == b", "a != b", 1)})
            path.write_text(json.dumps({"equivalent": [{"file": "A.swift", "original": "a", "mutated": "b", "reason": " "}]}))
            with self.assertRaises(SystemExit):
                mutation.load_equivalent(path)
        self.assertEqual(mutation.load_equivalent(Path("/nonexistent/equivalent.json")), set())


class ClassifyTests(unittest.TestCase):
    """Each fixture is the end of a real run's output, with local paths removed."""

    def classify(self, name, exit_code):
        return mutation.classify(exit_code, (FIXTURES / name).read_text())

    def test_real_runs(self):
        self.assertEqual(self.classify("passed.log", 0), "survived")
        self.assertEqual(self.classify("test-failed.log", 65), "killed")
        self.assertEqual(self.classify("build-failed.log", 65), "did not compile")
        self.assertEqual(self.classify("crashed.log", 65), "killed")
        self.assertEqual(self.classify("no-tests.log", 0), "unclassified")

    def test_a_passing_run_that_exits_with_an_error_is_unclassified(self):
        # Something after the tests failed; reading it as a catch could hide a survivor.
        self.assertEqual(self.classify("passed.log", 65), "unclassified")

    def test_a_failed_run_that_names_no_failing_test_is_unclassified(self):
        # Hand-built: the runner stopping before any test, which reads as no catch either way.
        log = "Testing failed:\n\tTest runner exited before starting test execution.\n\n** TEST FAILED **\n"
        self.assertEqual(mutation.classify(65, log), "unclassified")

    def test_no_output_is_unclassified(self):
        self.assertEqual(mutation.classify(0, ""), "unclassified")
        self.assertEqual(mutation.classify(1, "xcodegen: command not found"), "unclassified")


if __name__ == "__main__":
    unittest.main()
