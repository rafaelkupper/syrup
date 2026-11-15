"""Offline checks for script/mutation.py: which lines it mutates, how, and how it reads a run.

    python3 -I script/test_mutation.py
"""
import ast
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutation  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "mutation-fixtures"
SCRIPT = Path(__file__).resolve().parent / "mutation.py"


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
        ])
        self.assertEqual(mutation.changed_lines(diff), {4, 5, 12})


class BranchTests(unittest.TestCase):
    """A throwaway repository, with the diff settings and file names that once hid changed lines."""

    def git(self, root, *args):
        subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def test_changed_lines_are_found_whatever_the_diff_settings_and_file_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            names = ["Sources/A.swift", "Sources/B with space.swift", "Sources/Café.swift"]
            for name in names:
                (root / name).write_text("func f() -> Bool {\n    return false\n}\n", encoding="utf-8")
            self.git(root, "init", "-q")
            self.git(root, "add", ".")
            self.git(root, "commit", "-q", "--no-verify", "-m", "base")
            for name in names:
                (root / name).write_text("func f() -> Bool {\n    return true\n}\n", encoding="utf-8")
            (root / "Sources/New.swift").write_text("let ready = false\n", encoding="utf-8")
            (root / "Sources/icon.png").write_bytes(b"\x89PNG\r\n\x1a\n\xff\xfe")
            for setting in ("diff.noprefix", "diff.mnemonicPrefix"):
                self.git(root, "config", setting, "true")
            found = {(m.path, m.line) for m in mutation.branch_mutants("HEAD", root)[0]}
            self.assertEqual(found, {(name, 2) for name in names} | {("Sources/New.swift", 1)})


    def test_changed_lines_are_found_with_literal_pathspecs_and_a_diff_attribute(self):
        # GIT_LITERAL_PATHSPECS turns a :(literal) prefix into part of the name; `-diff` makes Git
        # print no hunks. Either once gave zero mutants and a pass.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            (root / "Sources/A.swift").write_text("func f() -> Bool {\n    return false\n}\n", encoding="utf-8")
            (root / ".gitattributes").write_text("*.swift -diff\n", encoding="utf-8")
            self.git(root, "init", "-q")
            self.git(root, "add", ".")
            self.git(root, "commit", "-q", "--no-verify", "-m", "base")
            (root / "Sources/A.swift").write_text("func f() -> Bool {\n    return true\n}\n", encoding="utf-8")
            (root / "Sources/Empty.swift").write_text("", encoding="utf-8")
            self.git(root, "add", "Sources/Empty.swift")  # a new empty file shows no hunk
            for variable in ("GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"):
                previous = os.environ.get(variable)
                os.environ[variable] = "1"
                try:
                    found = {(m.path, m.line) for m in mutation.branch_mutants("HEAD", root)[0]}
                finally:
                    os.environ.pop(variable) if previous is None else os.environ.__setitem__(variable, previous)
                self.assertEqual(found, {("Sources/A.swift", 2)}, variable)


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

    def test_a_raw_string_holding_one_quote_is_one_line(self):
        # `#"""#` is a one-line raw string holding a quote, not the start of a multi-line string.
        masked = mutation.mask('let q = #"""# == x\nlet y = a == b\n')
        self.assertEqual(masked.count("=="), 2)

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

    def test_a_prefix_negation_is_removed(self):
        self.assertEqual(mutated("if !ready {"), [("! removed", "if ready {")])
        self.assertEqual(mutated("guard !items.isEmpty, (!a) else {"),
                         [("! removed", "guard items.isEmpty, (!a) else {"), ("! removed", "guard !items.isEmpty, (a) else {")])
        for line in ["let y = x!.count", "if a != b {", "let s = \"!a\"", "let z = x!!.count"]:
            self.assertNotIn("! removed", [operator for operator, _ in mutated(line)], line)
        self.assertEqual(mutated("if !!ready {"), [("! removed", "if !ready {")])
        self.assertEqual([m for m in mutated("let off =!on") if m[0] == "! removed"], [("! removed", "let off =on")])

    def test_a_bool_literal_that_is_assigned_is_flipped(self):
        self.assertEqual(mutated("let enabled = true"), [("true to false", "let enabled = false")])
        self.assertEqual(mutated("var enabled: Bool = false"), [("false to true", "var enabled: Bool = true")])
        self.assertEqual(mutated("enabled = false"), [("false to true", "enabled = true"), ("statement deleted", "")])

    def test_a_comparison_with_a_bool_literal_is_one_mutant(self):
        self.assertEqual(mutated("if a.isEmpty == false {"), [("compared Bool flipped", "if a.isEmpty == true {")])
        self.assertEqual(mutated("if a ==  true {"), [("compared Bool flipped", "if a ==  false {")])
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
        # Deleting the first line of a statement that goes on below cannot compile, so it is not made.
        for line in ["    outputVolumeWork = Task {", "    items.append(contentsOf: [", "    send(event) {"]:
            self.assertNotIn("statement deleted", [operator for operator, _ in mutated(line)], line)

    def test_view_bodies_are_not_mutated(self):
        source = "\n".join([
            "struct Row: View, Equatable {",           # 1
            "    var body: some View {",               # 2
            "        if a == b { Text(\"x\") }",       # 3
            "    }",                                    # 4
            "}",                                        # 5
            "extension Row: View {",                   # 6
            "    func f() { send(a == b) }",            # 7
            "}",                                        # 8
            "struct Box<Content: View> {",             # 9
            "    func g() -> Bool { a == b }",          # 10
            "}",                                        # 11
            "final class Model: ObservableObject {",    # 12
            "    func h() -> Bool { a == b }",          # 13
            "}",                                        # 14
            "class Boxed: Box<any View> {",             # 15: a View only as a generic argument
            "    func k() -> Bool { a == b }",          # 16
            "}",                                        # 17
            "import SwiftUI",                           # 18
        ])
        found = mutation.mutants_for_file("A.swift", source, set(range(1, 18)))
        self.assertEqual(sorted({m.line for m in found}), [10, 13, 16])
        self.assertEqual(mutation.view_lines(mutation.mask(source)), {1, 2, 3, 4, 5, 6, 7, 8})

    def test_view_code_outside_view_types_is_skipped_and_static_helpers_are_not(self):
        source = "\n".join([
            "struct Pane: View {",                                                  # 1
            "    var body: some View { Text(a == b ? \"x\" : \"y\") }",               # 2
            "    static func detail(_ x: Int) -> String { x == 1 ? \"a\" : \"b\" }",  # 3: tested helper
            "}",                                                                     # 4
            "extension Pane {",                                                      # 5: same-file view
            "    func pill() -> Int { a == b ? 1 : 2 }",                             # 6
            "}",                                                                     # 7
            "struct Bindings {",                                                     # 8
            "    func row() -> some View { Text(a == b ? \"x\" : \"y\") }",          # 9: a view builder
            "    func flag() -> Bool { a == b }",                                    # 10
            "}",                                                                     # 11
            "struct PrimaryStyle: ButtonStyle {",                                    # 12
            "    func makeBody(configuration: Configuration) -> Bool { a == b }",    # 13
            "}",                                                                     # 14
            "struct Main: App {",                                                    # 15
            "    func launch() -> Bool { a == b }",                                  # 16: launch wiring, not a view
            "}",                                                                     # 17
            "struct Checks {",                                                       # 18
            "    func accepts(_ content: some View) -> Bool { a == b }",            # 19: takes a view, returns logic
            "    var preview: some View { Text(a == b ? \"x\" : \"y\") }",           # 20: a view builder
            "}",                                                                     # 21
            "import SwiftUI",                                                        # 22
        ])
        found = mutation.mutants_for_file("A.swift", source, set(range(1, 22)))
        self.assertEqual(sorted({m.line for m in found}), [3, 10, 16, 19])

    def test_an_app_skips_only_its_scenes(self):
        source = "\n".join([
            "import SwiftUI",
            "struct Main: App {",                                               # 2
            "    init() { if a == b { restore() } }",                          # 3: launch logic
            "    var body: some Scene { WindowGroup { Text(a == b ? \"x\" : \"y\") } }",  # 4
            "}",                                                                # 5
            "struct Fancy: ShapeStyle { func f() -> Bool { a == b } }",       # 6: not a view style
        ])
        self.assertEqual(sorted({m.line for m in mutation.mutants_for_file("A.swift", source, set(range(1, 7)))}), [3, 6])

    def test_view_rules_apply_only_where_swiftui_is_imported(self):
        # A style or app protocol of one's own, in a file without SwiftUI, is plain logic.
        source = "\n".join([
            "struct Plain: FormattingStyle {",          # 1
            "    func format() -> Bool { a == b }",     # 2
            "}",                                        # 3
        ])
        self.assertEqual({m.line for m in mutation.mutants_for_file("A.swift", source, {1, 2, 3})}, {2})
        # With SwiftUI imported, only SwiftUI's own style protocols count.
        self.assertEqual({m.line for m in mutation.mutants_for_file("A.swift", source + "\nimport SwiftUI", {1, 2, 3})}, {2})
        button = source.replace("FormattingStyle", "ButtonStyle")
        self.assertEqual({m.line for m in mutation.mutants_for_file("A.swift", button, {1, 2, 3})}, {2})
        self.assertEqual(mutation.mutants_for_file("A.swift", button + "\nimport SwiftUI", {1, 2, 3}), [])

    def test_an_extension_that_adds_view_makes_later_extensions_view_code(self):
        source = "\n".join([
            "import SwiftUI",
            "struct Pane {}",                           # 2
            "extension Pane: View {",                   # 3
            "    var body: some View { Text(\"x\") }",  # 4
            "}",                                        # 5
            "extension Pane {",                         # 6
            "    func pill() -> Bool { a == b }",       # 7
            "}",                                        # 8
        ])
        self.assertEqual(mutation.mutants_for_file("A.swift", source, set(range(1, 9))), [])

    def test_only_changed_lines(self):
        source = "a = b == c\nd = e == f\ng = h == i\n"
        found = mutation.mutants_for_file("A.swift", source, {2})
        self.assertEqual({m.line for m in found}, {2})


class SelectionTests(unittest.TestCase):
    def mutants(self, count):
        return [mutation.Mutant("A.swift", n, "a%d == b" % n, "a%d != b" % n, "== to !=") for n in range(1, count + 1)]

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
            path.write_text(json.dumps({"version": 1, "equivalent": [{"file": "A.swift", "original": "remember(key)", "mutated": "",
                                                        "scope": "func b()", "occurrence": 1, "before": "func b() {",
                                                        "after": "}", "reason": "b never runs"}]}))
            self.assertEqual(mutation.load_equivalent(path), {second.key})

    def test_an_entry_does_not_move_to_another_line_when_an_identical_line_is_inserted(self):
        source = "func a() {\n    remember(key)\n}\nfunc b() {\n    remember(key)\n}\n"
        listed = mutation.mutants_for_file("A.swift", source, {5})[0]
        changed = "func z() {\n    remember(key)\n}\n" + source
        matching = [m.line for m in mutation.mutants_for_file("A.swift", changed, {2, 5, 8}) if m.key == listed.key]
        # The entry for func b still names func b's line, now line 8, and no other.
        self.assertEqual(matching, [8])

    def test_an_entry_does_not_move_to_an_identical_line_in_another_function(self):
        # As in OpenAICompatibleTransformer: two functions hold the same line with the same neighbors.
        def function(name):
            return "    func %s() {\n        var sends = first\n        var flag = false\n        while true {\n        }\n    }\n" % name
        source = "struct T {\n" + function("stream") + function("transform") + "}\n"
        listed = mutation.mutants_for_file("A.swift", source, set(range(1, 20)))
        listed = [m for m in listed if m.original.strip() == "var flag = false"]
        self.assertEqual(len(listed), 2)
        changed = "struct T {\n" + function("added") + function("stream") + function("transform") + "}\n"
        after = [m for m in mutation.mutants_for_file("A.swift", changed, set(range(1, 30)))
                 if m.original.strip() == "var flag = false"]
        keys = {m.key for m in listed}
        # The two listed lines still match; the new function's line does not take over either entry.
        self.assertEqual([m.key in keys for m in after], [False, True, True])

    def test_selection_does_not_change_when_unrelated_lines_move(self):
        source = "".join("func f%d() -> Bool {\n    return a%d == b\n}\n" % (n, n) for n in range(12))
        before = {(m.original, m.mutated) for m in mutation.select(mutation.mutants_for_file("A.swift", source, set(range(1, 40))), 5)}
        moved = "// a new first line\n" + source
        after = {(m.original, m.mutated) for m in mutation.select(mutation.mutants_for_file("A.swift", moved, set(range(1, 41))), 5)}
        self.assertEqual(before, after)

    def test_entries_that_match_no_line_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "A.swift").write_text("func f() {\n    remember(key)\n}\n", encoding="utf-8")
            good = {"file": "A.swift", "scope": "func f()", "original": "remember(key)", "mutated": "", "occurrence": 1,
                    "before": "func f() {", "after": "}", "reason": "r"}
            moved = dict(good, before="func g() {")
            gone = dict(good, file="Gone.swift")
            path = root / "equivalent.json"
            path.write_text(json.dumps({"version": 1, "equivalent": [good, moved, gone]}), encoding="utf-8")
            self.assertEqual(mutation.stale_entries(path, root), [moved, gone])

    def test_equivalent_entries_need_a_reason_and_match_by_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "equivalent.json"
            path.write_text(json.dumps({"version": 1, "equivalent": [
                {"file": "A.swift", "original": "  a == b ", "mutated": "a != b", "reason": "a and b are always equal"}]}))
            self.assertEqual(mutation.load_equivalent(path), {("A.swift", "", "a == b", "a != b", 1, "", "")})
            path.write_text(json.dumps({"version": 1, "equivalent": [{"file": "A.swift", "original": "a", "mutated": "b", "reason": " "}]}))
            with self.assertRaises(SystemExit):
                mutation.load_equivalent(path)
            # A hand-edited entry missing a field is refused with a message, not a traceback.
            path.write_text(json.dumps({"version": 1, "equivalent": [{"file": "A.swift", "mutated": "b", "reason": "r"}]}))
            with self.assertRaises(SystemExit):
                mutation.load_equivalent(path)
            with self.assertRaises(SystemExit):
                mutation.stale_entries(path, Path(directory))
            # Entries that are not objects, or whose optional fields have the wrong type.
            for entry in (None, {"file": "A.swift", "original": "a", "mutated": "b", "reason": "r", "scope": None},
                          {"file": "A.swift", "original": "a", "mutated": "b", "reason": "r", "occurrence": "two"},
                          {"file": "A.swift", "original": "a", "mutated": "b", "reason": "r", "occurrence": 0}):
                path.write_text(json.dumps({"version": 1, "equivalent": [entry]}), encoding="utf-8")
                for check in (mutation.load_equivalent, lambda p: mutation.stale_entries(p, Path(directory))):
                    with self.assertRaises(SystemExit, msg=repr(entry)):
                        check(path)
            # Not JSON, or written for a version this tool does not know: refused with a message.
            for text in ("{not json", json.dumps({"version": 2, "equivalent": []}), json.dumps([]),
                         json.dumps({"version": True, "equivalent": []})):
                path.write_text(text, encoding="utf-8")
                for check in (mutation.load_equivalent, lambda p: mutation.stale_entries(p, Path(directory))):
                    with self.assertRaises(SystemExit, msg=text):
                        check(path)
        self.assertEqual(mutation.load_equivalent(Path("/nonexistent/equivalent.json")), set())


class RunTests(unittest.TestCase):
    def test_a_time_out_stops_the_whole_process_group(self):
        # A fake test script whose child ignores SIGTERM, as a hung build tool might.
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            (scratch / "script").mkdir()
            fake = scratch / "script" / "test-isolated.sh"
            fake.write_text("#!/bin/sh\necho $$ > \"$(dirname \"$0\")/pid\"\n(trap '' TERM; sleep 300) &\nexec sleep 300\n")
            fake.chmod(0o755)
            grace = mutation.STOP_GRACE
            mutation.STOP_GRACE = 1
            self.addCleanup(setattr, mutation, "STOP_GRACE", grace)
            result, _ = mutation.run_suite(scratch, scratch / "root", scratch / "run.log", timeout=1)
            self.assertEqual(result, "timed out")
            group = int((scratch / "script" / "pid").read_text())
            time.sleep(0.2)
            with self.assertRaises(ProcessLookupError):
                os.killpg(group, 0)

    def test_a_time_out_stops_build_processes_outside_the_group(self):
        # Xcode's build service starts each compiler in its own process group; a compiler names the
        # run's build folder in its arguments. This fake one leaves the group and ignores SIGTERM.
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            (scratch / "script").mkdir()
            fake = scratch / "script" / "test-isolated.sh"
            fake.write_text("#!/bin/sh\n"
                            "perl -e 'setpgrp(0, 0); $SIG{TERM} = \"IGNORE\"; sleep 300' \"$SYRUP_TEST_ROOT/build\" &\n"
                            "exec sleep 300\n")
            fake.chmod(0o755)
            grace = mutation.STOP_GRACE
            mutation.STOP_GRACE = 1
            self.addCleanup(setattr, mutation, "STOP_GRACE", grace)
            root = scratch / "root"
            self.addCleanup(self.kill_naming, str(root))  # never leave the probe behind
            result, _ = mutation.run_suite(scratch, root, scratch / "run.log", timeout=2)
            self.assertEqual(result, "timed out")
            self.assertEqual(self.kill_naming(str(root)), [])

    @staticmethod
    def kill_naming(text):
        """Kills the processes whose arguments contain `text`, and returns their PIDs."""
        listing = subprocess.run(["ps", "-axww", "-o", "pid=,args="], capture_output=True, text=True).stdout
        pids = [int(line.split()[0]) for line in listing.splitlines() if text in line]
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return pids

    def test_the_run_removes_the_lock_files_swiftpm_left_for_it(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            mine = ["_private_var_T_syrup-mutation.abcd1234_test-root_build_SourcePackages_Package.resolved.lock",
                    "_private_var_T_syrup-mutation.abcd1234_test-root_build_SourcePackages_artifacts_sparkle_Sparkle.lock"]
            other = ["_private_var_T_syrup-mutation.zzzz9999_test-root_build_SourcePackages_Package.resolved.lock",
                     "_Users_x_DerivedData_Syrup-abc_SourcePackages_Package.resolved.lock"]
            for name in mine + other:
                (folder / name).touch()
            mutation.remove_lock_files(folder, "syrup-mutation.abcd1234")
            self.assertEqual(sorted(p.name for p in folder.iterdir()), sorted(other))

    def test_files_are_read_and_written_as_utf8_whatever_the_locale(self):
        # The fault fb5f1c6 fixed in generate.py: open(), read_text(), and write_text() otherwise use
        # the locale's encoding, which crashes on non-ASCII Swift under US-ASCII.
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        missing = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                name = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
                modes = [arg.value for arg in node.args[1:2] if isinstance(arg, ast.Constant)]
                if name in ("open", "read_text", "write_text") and not any("b" in str(m) for m in modes) \
                        and "encoding" not in [keyword.arg for keyword in node.keywords]:
                    missing.append(node.lineno)
        self.assertEqual(missing, [])

    def test_an_empty_or_bad_limit_from_the_environment(self):
        env = dict(os.environ, SYRUP_MUTANTS="")
        self.assertEqual(subprocess.run([sys.executable, "-I", str(SCRIPT), "--base", "HEAD", "--list"], env=env,
                                        capture_output=True).returncode, 0)
        env["SYRUP_MUTANTS"] = "many"
        self.assertEqual(subprocess.run([sys.executable, "-I", str(SCRIPT), "--base", "HEAD", "--list"], env=env,
                                        capture_output=True).returncode, 2)

    def test_a_time_out_stops_a_process_that_left_the_tree_but_not_the_session(self):
        # Xcode's build service can start a compiler after xcodebuild has died; it then descends
        # from nothing of the run's, but it stays in the run's session.
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            (scratch / "script").mkdir()
            fake = scratch / "script" / "test-isolated.sh"
            fake.write_text("#!/bin/sh\n"
                            "perl -e 'if (fork) { exit } setpgrp(0, 0); $SIG{TERM} = \"IGNORE\"; sleep 300' "
                            "\"$SYRUP_TEST_ROOT/build\"\nexec sleep 300\n")
            fake.chmod(0o755)
            grace = mutation.STOP_GRACE
            mutation.STOP_GRACE = 1
            self.addCleanup(setattr, mutation, "STOP_GRACE", grace)
            root = scratch / "root"
            self.addCleanup(self.kill_naming, str(root))
            result, _ = mutation.run_suite(scratch, root, scratch / "run.log", timeout=2)
            self.assertEqual(result, "timed out")
            self.assertEqual(self.kill_naming(str(root)), [])

    def test_the_process_table_reads_the_same_in_any_locale(self):
        # Some locales print the start time in fewer words.
        previous = os.environ.get("LC_ALL")
        os.environ["LC_ALL"] = "ja_JP.UTF-8"
        try:
            table = mutation.process_table()
        finally:
            os.environ.pop("LC_ALL") if previous is None else os.environ.__setitem__("LC_ALL", previous)
        self.assertIn(os.getpid(), table)
        self.assertIn("python", table[os.getpid()][2].lower())

    def test_stopping_leaves_processes_the_run_did_not_start(self):
        # Processes that only name the build folder, or a folder whose name begins with it, are not
        # the run's: someone watching a log there, say.
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            (scratch / "script").mkdir()
            fake = scratch / "script" / "test-isolated.sh"
            fake.write_text("#!/bin/sh\nexec sleep 300\n")
            fake.chmod(0o755)
            root = scratch / "root"
            (root / "build").mkdir(parents=True)
            (root / "build" / "log").write_text("", encoding="utf-8")
            self.addCleanup(self.kill_naming, str(root))
            bystanders = [subprocess.Popen(["perl", "-e", "sleep 300", str(root) + "-unrelated"]),
                          subprocess.Popen(["tail", "-f", str(root / "build" / "log")])]
            for bystander in bystanders:
                self.addCleanup(lambda process=bystander: (process.kill(), process.wait()))
            result, _ = mutation.run_suite(scratch, root, scratch / "run.log", timeout=1)
            self.assertEqual(result, "timed out")
            self.assertEqual([bystander.poll() for bystander in bystanders], [None, None])

    def test_stopping_reaches_the_test_host_launched_from_the_build_folder(self):
        # launchd starts the test host, so it is no descendant of the run; its executable is in the
        # run's build folder, which only the run builds into.
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            (scratch / "script").mkdir()
            fake = scratch / "script" / "test-isolated.sh"
            fake.write_text("#!/bin/sh\nexec sleep 300\n")
            fake.chmod(0o755)
            root = scratch / "root"
            (root / "build").mkdir(parents=True)
            host = root / "build" / "Host"
            # Built here rather than copied: macOS kills a copied system binary at launch.
            subprocess.run(["cc", "-x", "c", "-", "-o", str(host)], check=True, capture_output=True,
                           input=b"#include <unistd.h>\nint main(void) { for (;;) pause(); }\n")
            self.addCleanup(self.kill_naming, str(root))
            launched = subprocess.Popen([str(host), "300"], start_new_session=True)
            self.addCleanup(lambda: (launched.kill(), launched.wait()))
            result, _ = mutation.run_suite(scratch, root, scratch / "run.log", timeout=1)
            self.assertEqual(result, "timed out")
            self.assertEqual(launched.wait(timeout=5), -signal.SIGTERM)

    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--base", "HEAD", "--list", *args],
                              capture_output=True, text=True)

    def test_a_limit_below_one_is_refused(self):
        for limit in ("0", "-1"):
            self.assertEqual(self.run_script("--limit", limit).returncode, 2, limit)

    def test_only_naming_a_line_without_mutants_is_refused(self):
        # A typo or a moved line would otherwise pass as fixed.
        self.assertEqual(self.run_script("--only", "Sources/Nope.swift:1").returncode, 2)

    def test_a_logs_path_that_is_a_file_is_refused_before_anything_runs(self):
        with tempfile.NamedTemporaryFile() as file:
            self.assertEqual(self.run_script("--logs", file.name).returncode, 2)


class ClassifyTests(unittest.TestCase):
    """Each fixture is the end of a real run's output, with local paths removed."""

    def classify(self, name, exit_code):
        return mutation.classify(exit_code, (FIXTURES / name).read_text(encoding="utf-8"))

    def test_real_runs(self):
        self.assertEqual(self.classify("passed.log", 0), "survived")
        self.assertEqual(self.classify("test-failed.log", 65), "killed")
        self.assertEqual(self.classify("build-failed.log", 65), "did not compile")
        self.assertEqual(mutation.classify(65, (FIXTURES / "build-failed.log").read_text(encoding="utf-8"),
                                           "Sources/Translation/OpenAISSEParser.swift"), "did not compile")
        self.assertEqual(self.classify("crashed.log", 65), "killed")
        self.assertEqual(self.classify("no-tests.log", 0), "unclassified")

    def test_a_passing_run_that_exits_with_an_error_is_unclassified(self):
        # Something after the tests failed; reading it as a catch could hide a survivor.
        self.assertEqual(self.classify("passed.log", 65), "unclassified")

    def test_a_failed_run_that_names_no_failing_test_is_unclassified(self):
        # Hand-built: the runner stopping before any test, which reads as no catch either way.
        log = "Testing failed:\n\tTest runner exited before starting test execution.\n\n** TEST FAILED **\n"
        self.assertEqual(mutation.classify(65, log), "unclassified")

    def test_a_build_that_fails_outside_the_mutated_file_is_unclassified(self):
        # A disk, signing, or package failure is no evidence about the mutant.
        log = (FIXTURES / "build-failed.log").read_text(encoding="utf-8")
        self.assertEqual(mutation.classify(65, log, "Sources/Core/Other.swift"), "unclassified")

    def test_no_output_is_unclassified(self):
        self.assertEqual(mutation.classify(0, ""), "unclassified")
        self.assertEqual(mutation.classify(1, "xcodegen: command not found"), "unclassified")


if __name__ == "__main__":
    unittest.main()
