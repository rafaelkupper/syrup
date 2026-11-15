#!/usr/bin/env python3
"""Mutation testing of the Swift lines a branch changed.

Makes one small break (a mutant) at a time in the lines under Sources/ that differ from the merge
base with main, runs the isolated suite against it in a scratch copy, and fails if the suite still
passes against any mutant (a survivor), unless that mutant is listed in mutation-equivalent.json
with the reason it cannot change behavior. The developer's checkout is never changed.

    python3 -I script/mutation.py [--base <commit>] [--limit <n>] [--only <path:line>]... [--list] [--logs <dir>]

SYRUP_MUTANTS sets the limit too. The limit keeps the run bounded; mutants are picked by a hash of
their text, so a rerun makes the same ones, and the run says how many it left out.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EQUIVALENT = Path(__file__).resolve().parent / "mutation-equivalent.json"
DEFAULT_LIMIT = 20


# MARK: - Which lines changed


def changed_lines(diff: str) -> set[int]:
    """Line numbers in the new version of one file, from the hunk headers of its `git diff -U0`.
    File names are not read from the diff, since diff settings and quoting change how they print."""
    changed: set[int] = set()
    for line in diff.splitlines():
        match = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
        if match:
            start, count = int(match.group(1)), int(match.group(2) or "1")
            changed.update(range(start, start + count))
    return changed


# MARK: - Code without comments and strings


def mask(source: str) -> str:
    """The source with comments and string-literal contents replaced by spaces, newlines kept, so a
    column in the result is the same column in the source. Code inside `\\(...)` stays code. Regex
    literals are not recognized; one containing a quote would be read as opening a string (Sources/
    has none)."""
    out = list(source)
    length = len(source)
    stack: list[list] = []  # ["string", hashes, multiline] or ["code", open parentheses]

    def blank(start: int, end: int) -> None:
        for index in range(start, end):
            if out[index] != "\n":
                out[index] = " "

    opener = re.compile(r'(#*)("""|")')
    index = 0
    while index < length:
        top = stack[-1] if stack else None
        if top is None or top[0] == "code":
            if source.startswith("//", index):
                end = source.find("\n", index)
                end = length if end < 0 else end
                blank(index, end)
                index = end
                continue
            if source.startswith("/*", index):
                depth, end = 1, index + 2
                while end < length and depth:
                    if source.startswith("/*", end):
                        depth, end = depth + 1, end + 2
                    elif source.startswith("*/", end):
                        depth, end = depth - 1, end + 2
                    else:
                        end += 1
                blank(index, end)
                index = end
                continue
            match = opener.match(source, index)
            if match:
                hashes, quotes = len(match.group(1)), match.group(2)
                # `"""` opens a multi-line string only when the line ends after it; `#"""#` is a
                # one-line raw string holding a quote.
                rest = source[match.end():source.find("\n", match.end()) if "\n" in source[match.end():] else length]
                multiline = quotes == '"""' and rest.strip() == ""
                stack.append(["string", hashes, multiline])
                index = match.start() + hashes + (3 if multiline else 1)
                continue
            if top is not None:
                if source[index] == "(":
                    top[1] += 1
                elif source[index] == ")":
                    top[1] -= 1
                    if top[1] == 0:
                        stack.pop()
            index += 1
        else:
            _, hashes, multiline = top
            closer = ('"""' if multiline else '"') + "#" * hashes
            if source.startswith(closer, index):
                stack.pop()
                index += len(closer)
                continue
            escape = "\\" + "#" * hashes
            if source.startswith(escape, index):
                after = index + len(escape)
                if after < length and source[after] == "(":
                    blank(index, after)
                    stack.append(["code", 1])
                    index = after + 1
                    continue
                blank(index, min(after + 1, length))
                index = after + 1
                continue
            blank(index, index + 1)
            index += 1
    return "".join(out)


# MARK: - Mutants


@dataclass(frozen=True)
class Mutant:
    path: str
    line: int  # 1-based
    original: str
    mutated: str
    operator: str
    # A file can repeat a line in places that behave differently, so a mutant is also known by which
    # line with this text it is within its declarations, counting from the top, and by the code lines
    # just before and after. If any changes, an entry stops matching and the mutant runs again.
    occurrence: int = 1
    before: str = ""
    after: str = ""
    # The declarations around the line, such as "struct T > func stream()", so an identical line in
    # another function never takes over an entry; occurrences are counted within them.
    scope: str = ""

    @property
    def key(self) -> tuple[str, str, str, str, int, str, str]:
        return (self.path, self.scope, self.original.strip(), self.mutated.strip(), self.occurrence, self.before, self.after)

    @property
    def order(self) -> str:
        """Picks mutants under the limit. Line numbers are left out, so lines moving elsewhere in the
        file do not change which run."""
        return hashlib.sha256("\0".join(str(part) for part in self.key).encode()).hexdigest()

    def entry(self) -> str:
        """The mutation-equivalent.json entry that would list this mutant, reason left to fill in."""
        return json.dumps({"file": self.path, "scope": self.scope, "original": self.original.strip(),
                           "mutated": self.mutated.strip(), "occurrence": self.occurrence, "before": self.before,
                           "after": self.after, "reason": ""}, ensure_ascii=False)


KEYWORDS = {"return", "if", "guard", "let", "var", "case", "switch", "while", "for", "throw", "defer",
            "else", "repeat", "do", "catch", "import", "func", "init", "deinit", "super", "await", "try"}
BOOL_COMPARISON = re.compile(r"(==|!=)(\s*)(true|false)\b")
REPLACEMENTS = [
    ("== to !=", re.compile(r"(?<![=!<>])==(?!=)(?!\s*(?:true|false)\b)"), "!="),
    ("!= to ==", re.compile(r"!=(?!=)(?!\s*(?:true|false)\b)"), "=="),
    ("&& to ||", re.compile(r"&&"), "||"),
    ("|| to &&", re.compile(r"\|\|"), "&&"),
    ("true to false", re.compile(r"\btrue\b"), "false"),
    ("false to true", re.compile(r"\bfalse\b"), "true"),
    ("< to <=", re.compile(r"(?<=\s)<(?=\s)"), "<="),
    ("<= to <", re.compile(r"(?<=\s)<=(?=\s)"), "<"),
    ("> to >=", re.compile(r"(?<=\s)>(?=\s)"), ">="),
    (">= to >", re.compile(r"(?<=\s)>=(?=\s)"), ">"),
    ("! removed", re.compile(r"(?:^|(?<=[\s(\[,{=]))!(?=[A-Za-z_(.$\[!])"), ""),
]
CALL = re.compile(r"(?:try\s+|await\s+|try\s+await\s+)?([A-Za-z_]\w*)(?:\??\.[A-Za-z_]\w*)*\(.*\)")
ASSIGNMENT = re.compile(r"(?:self\.)?([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*\s*(?:=(?!=)|\+=|-=)\s*\S.*")


def balanced(text: str) -> bool:
    """Every (, [, and { on the line is closed on it, so deleting the line deletes a whole statement."""
    for opener, closer in ("()", "[]", "{}"):
        depth = 0
        for character in text:
            depth += 1 if character == opener else -1 if character == closer else 0
            if depth < 0:
                return False
        if depth:
            return False
    return True


DECLARATION_LINE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*|(?:public|private|fileprivate|internal|open|static|final|override|mutating|"
    r"nonmutating|nonisolated|convenience|required|lazy|dynamic|indirect|class)\s+)*"
    r"(func|init|deinit|subscript|var|struct|class|enum|extension|actor|protocol)\b")
TYPE_KEYWORDS = {"struct", "class", "enum", "extension", "actor", "protocol"}
# SwiftUI's view protocols and its style protocols, by name. An `App` or `Scene` is not listed: its
# `body` returns `some Scene` and is skipped as a builder, while its `init` is launch logic.
UI_CONFORMANCES = {"View", "ViewModifier"} | {name + "Style" for name in (
    "Button", "PrimitiveButton", "Toggle", "Label", "Menu", "ProgressView", "GroupBox", "DisclosureGroup",
    "LabeledContent", "TextField", "TextEditor", "Picker", "List", "Table", "Form", "ControlGroup", "Gauge",
    "DatePicker", "NavigationSplitView", "TabView", "Window", "WindowToolbar", "IndexView", "MenuBarExtra")}
UI_CONFORMANCES |= {"SwiftUI." + name for name in UI_CONFORMANCES}


def declaration(header: str, ui_types: set[str] = frozenset()) -> tuple[str, str] | None:
    """For the code before a `{`: the declaration it opens, whitespace collapsed, and its kind. "ui" is
    a SwiftUI type (see `conforms_to_ui`) or an extension of one declared in the same file; "builder"
    a member returning `some View`; "static" any other static member; "type" and "member" the rest.
    None for a closure or a control-flow block."""
    lines = header.split("\n")
    for index in range(len(lines) - 1, -1, -1):
        match = DECLARATION_LINE.match(lines[index])
        if not match:
            continue
        text = " ".join(" ".join(lines[index:]).split())
        keyword = match.group(1)
        if keyword in TYPE_KEYWORDS:
            name = re.search(r"\b%s\s+([\w.]+)" % keyword, text)
            extended = keyword == "extension" and name is not None and name.group(1) in ui_types
            return text, "ui" if conforms_to_ui(text) or extended else "type"
        if is_builder(text, keyword):
            return text, "builder"
        if re.search(r"\bstatic\b", text):
            return text, "static"
        return text, "member"
    return None


MODIFIERS = r"(?:@\w+(?:\([^)]*\))?\s*|(?:public|private|fileprivate|internal|package|open|static|final|override|nonisolated|lazy|dynamic)\s+)*"
OPAQUE_VIEW = r"some\s+(?:SwiftUI\.)?(?:View|Scene)"


def is_builder(text: str, keyword: str) -> bool:
    """The declaration gives back `some View` or `some Scene`, read from where it ends rather than
    parsed: the header text stops where the block opens, so a function's return type is what follows
    its last `->` (with a `where` clause at most after it), and a property is exactly
    `var name: some View`. Generic clauses, closure parameters, default values, and a parameter
    typed `some View` come before that end and do not count; a local `var` followed by other
    statements does not match."""
    if keyword == "var":
        return re.fullmatch(MODIFIERS + r"var\s+\w+\s*:\s*" + OPAQUE_VIEW, text) is not None
    return re.search(r"->\s*" + OPAQUE_VIEW + r"\s*(?:\bwhere\b[^{}]*)?$", text) is not None


def conforms_to_ui(text: str) -> bool:
    """One of the type's own conformances is SwiftUI's: `View`, `ViewModifier`, or a style such as
    `ButtonStyle` (see `UI_CONFORMANCES`). A generic argument or constraint does not count, so
    `struct Box<Content: View>` and `class Model: Box<any View>` are not views."""
    match = re.match(r".*?\b(?:struct|class|enum|extension|actor|protocol)\s+[\w.]+", text)
    rest = text[match.end():] if match else text
    if rest.startswith("<"):  # the type's own generic parameters
        depth = 0
        for index, character in enumerate(rest):
            depth += {"<": 1, ">": -1}.get(character, 0)
            if depth == 0:
                rest = rest[index + 1:]
                break
    rest = re.split(r"\bwhere\b", rest)[0].strip()
    if not rest.startswith(":"):
        return False
    items, depth, current = [], 0, ""
    for character in rest[1:]:
        depth += {"<": 1, "(": 1, "[": 1, ">": -1, ")": -1, "]": -1}.get(character, 0)
        if character == "," and depth == 0:
            items.append(current)
            current = ""
        else:
            current += character
    items.append(current)
    return any(item.strip() in UI_CONFORMANCES for item in items)


def line_blocks(code: str) -> list[tuple[str, bool]]:
    """For each line of masked code: the declarations around it, innermost last (the deepest reached on
    the line, so a one-line function counts as its own scope), and whether it is view code. View code
    is inside a SwiftUI type or a view builder, unless a static member that builds no view sits in
    between: such helpers are plain logic that tests can call."""
    # SwiftUI's names count only where SwiftUI is imported; elsewhere a `...Style` or `App` is a
    # protocol of the code's own.
    swiftui = re.search(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?"
                        r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?SwiftUI(?![\w])",
                        code, re.MULTILINE) is not None
    ui_types: set[str] = set()
    boundary = 0
    for index, character in enumerate(code):  # first, the file's own SwiftUI types, for extensions
        if character == "{" and swiftui:
            found = declaration(code[boundary:index])
            if found and found[1] == "ui":
                name = re.search(r"\b(struct|class|enum|actor|extension)\s+([\w.]+)", found[0])
                # A conditional conformance (`extension Box: View where T == Int`) makes only some of
                # the type a view; a `where` on the type's own declaration does not.
                if name and not (name.group(1) == "extension" and re.search(r"\bwhere\b", found[0])):
                    ui_types.add(name.group(2))
        if character in "{};":
            boundary = index + 1

    result: list[tuple[str, bool]] = []
    stack: list[tuple[str, str] | None] = []
    boundary = 0

    def scope() -> tuple[str, bool]:
        view = False
        for entry in stack:
            if entry and entry[1] in ("ui", "builder"):
                view = True
            elif entry and entry[1] == "static":
                view = False
        return " > ".join(entry[0] for entry in stack if entry), view

    line_scope, line_view = scope()
    for index, character in enumerate(code):
        if character == "{":
            found = declaration(code[boundary:index], ui_types)
            if found and not swiftui and found[1] in ("ui", "builder"):
                found = (found[0], "type" if found[1] == "ui" else "member")
            stack.append(found)
            boundary = index + 1
            current, view = scope()
            if len(current) > len(line_scope):  # the deepest declaration on the line decides both
                line_scope, line_view = current, view
        elif character == "}":
            if stack:
                stack.pop()
            boundary = index + 1
        elif character == ";":
            boundary = index + 1
        elif character == "\n":
            result.append((line_scope, line_view))
            line_scope, line_view = scope()
    result.append((line_scope, line_view))
    return result


def view_lines(code: str) -> set[int]:
    """Lines of SwiftUI view code (see `line_blocks`), from masked code. No test hosts a view, so
    mutants there would always survive; docs/QA.md checks views instead."""
    return {number for number, (_, view) in enumerate(line_blocks(code), 1) if view}


def mutants_for_line(path: str, number: int, line: str, code: str, occurrence: int = 1,
                     before: str = "", after: str = "", scope: str = "") -> list[Mutant]:
    """Every mutant of one line. `code` is the line masked, so matches are on code only."""
    found: list[Mutant] = []

    def add(operator: str, start: int, end: int, replacement: str) -> None:
        mutated = line[:start] + replacement + line[end:]
        if mutated != line:
            found.append(Mutant(path, number, line, mutated, operator, occurrence, before, after, scope))

    compared = set()
    for match in BOOL_COMPARISON.finditer(code):
        compared.add(match.start(3))
        add("compared Bool flipped", match.start(3), match.end(3), "false" if match.group(3) == "true" else "true")
    for operator, pattern, replacement in REPLACEMENTS:
        for match in pattern.finditer(code):
            # A literal compared with == or != already has its one mutant above.
            if match.start() not in compared:
                add(operator, match.start(), match.end(), replacement)
    statement = code.strip()
    indent = line[: len(line) - len(line.lstrip())]
    for pattern in (CALL, ASSIGNMENT):
        match = pattern.fullmatch(statement)
        if match and match.group(1) not in KEYWORDS and balanced(statement):
            found.append(Mutant(path, number, line, indent, "statement deleted", occurrence, before, after, scope))
            break
    return found


def mutants_for_file(path: str, source: str, lines: set[int]) -> list[Mutant]:
    """Mutants of the given lines, leaving out lines inside SwiftUI views (see `view_lines`)."""
    source_lines = source.split("\n")
    masked = mask(source)
    code_lines = masked.split("\n")
    blocks = line_blocks(masked)
    code = [number for number, text in enumerate(code_lines, 1) if text.strip()]
    found: list[Mutant] = []
    seen: dict[tuple[str, str], int] = {}
    for number, line in enumerate(source_lines, 1):
        scope, view = blocks[number - 1]
        seen[(scope, line.strip())] = seen.get((scope, line.strip()), 0) + 1
        if number in lines and not view:
            position = code.index(number) if number in code else None
            before = source_lines[code[position - 1] - 1].strip() if position else ""
            after = source_lines[code[position + 1] - 1].strip() if position is not None and position + 1 < len(code) else ""
            found += mutants_for_line(path, number, line, code_lines[number - 1], seen[(scope, line.strip())],
                                      before, after, scope)
    return found


def select(mutants: list[Mutant], limit: int) -> list[Mutant]:
    """At most `limit`, picked by a hash of their text, then in file and line order."""
    picked = sorted(mutants, key=lambda mutant: mutant.order)[:limit]
    return sorted(picked, key=lambda mutant: (mutant.path, mutant.line, mutant.operator, mutant.mutated))


REQUIRED_FIELDS = ("file", "original", "mutated", "reason")


def read_entries(path: Path) -> list[dict]:
    """The entries of mutation-equivalent.json, or a message naming what is wrong with it."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as error:
        raise SystemExit("%s is not valid JSON: %s" % (path.name, error))
    version = document.get("version") if isinstance(document, dict) else None
    if type(version) is not int or version != 1 or not isinstance(document.get("equivalent"), list):
        raise SystemExit("%s must be an object with \"version\": 1 and an \"equivalent\" list." % path.name)
    return document["equivalent"]


def entry_key(entry: dict) -> tuple[str, str, str, str, int, str, str]:
    if not isinstance(entry, dict):
        raise SystemExit("mutation-equivalent.json: an entry is not an object: %r" % (entry,))
    missing = [field for field in REQUIRED_FIELDS if not isinstance(entry.get(field), str)]
    wrong = [field for field in ("scope", "before", "after") if field in entry and not isinstance(entry[field], str)]
    occurrence = entry.get("occurrence", 1)
    if not isinstance(occurrence, int) or isinstance(occurrence, bool) or occurrence < 1:
        wrong.append("occurrence")
    if missing or wrong:
        raise SystemExit("mutation-equivalent.json: an entry lacks %s: %r" % (", ".join(missing + wrong), entry))
    return (entry["file"], entry.get("scope", "").strip(), entry["original"].strip(), entry["mutated"].strip(),
            int(entry.get("occurrence", 1)), entry.get("before", "").strip(), entry.get("after", "").strip())


def load_equivalent(path: Path) -> set[tuple[str, str, str, str, int, str, str]]:
    if not path.exists():
        return set()
    entries = read_entries(path)
    for entry in entries:
        entry_key(entry)
        if not entry["reason"].strip():
            raise SystemExit("mutation-equivalent.json: every entry needs a reason: %r" % entry)
    return {entry_key(entry) for entry in entries}


def stale_entries(path: Path, root: Path = ROOT) -> list[dict]:
    """Entries that match no mutant of their file as it is now: the file, the line, or its neighbors
    changed. An entry must not quietly outlive the line it reasons about."""
    if not path.exists():
        return []
    stale = []
    keys: dict[str, set] = {}
    for entry in read_entries(path):
        entry_key(entry)
        file = entry["file"]
        if file not in keys:
            source = root / file
            try:
                text = source.read_text(encoding="utf-8") if source.is_file() else None
            except (OSError, UnicodeDecodeError):
                text = None  # gone, a folder, or not Swift text: nothing the entry could match
            keys[file] = set() if text is None else {
                mutant.key for mutant in mutants_for_file(file, text, set(range(1, text.count("\n") + 2)))}
        if entry_key(entry) not in keys[file]:
            stale.append(entry)
    return stale


def remove_lock_files(folder: Path, scratch_name: str) -> None:
    """SwiftPM leaves lock files named after the build folder in the temporary folder."""
    for lock in folder.glob("*%s_test-root_build_SourcePackages_*.lock" % scratch_name):
        lock.unlink(missing_ok=True)


# MARK: - Reading a run


SUMMARY = re.compile(r"Test run with (\d+) tests? in \d+ suites? (passed|failed)")
BUILD_FAILED = ("Testing cancelled because the build failed.", "The following build commands failed:",
                "** BUILD FAILED **", "** TEST BUILD FAILED **")


def classify(exit_code: int, log: str, mutated_file: str | None = None) -> str:
    """killed, survived, did not compile, or unclassified, from a run's exit code and output.
    Anything this cannot read as one of the first three is unclassified, which fails the run, so an
    odd run is never taken for a catch."""
    # `xcodebuild test` reports a compile error as a failed test run, so look for the build's own words.
    # A mutant did not compile only if the compiler names its file; any other failed build (disk,
    # signing, a package fetch) says nothing about the mutant.
    if any(marker in log for marker in BUILD_FAILED):
        if mutated_file and not re.search(re.escape("/" + mutated_file) + r":\d+:\d+: error:", log):
            return "unclassified"
        return "did not compile"
    # A failing test, or a crash: the host restarts, Swift Testing summarizes only its last launch,
    # which may pass, and xcodebuild names the tests that failed or were lost.
    if "** TEST FAILED **" in log and "Failing tests:" in log:
        return "killed"
    summaries = SUMMARY.findall(log)
    if summaries and summaries[-1][1] == "passed" and int(summaries[-1][0]) > 0 and exit_code == 0:
        return "survived"
    return "unclassified"


# MARK: - Running


def git(*args: str, root: Path = ROOT) -> str:
    # GIT_GLOB_PATHSPECS and the like conflict with --literal-pathspecs, so they are left out.
    environment = {key: value for key, value in os.environ.items()
                   if not (key.startswith("GIT_") and key.endswith("_PATHSPECS"))}
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                          encoding="utf-8", errors="surrogateescape", env=environment).stdout


def branch_mutants(base: str, root: Path = ROOT) -> tuple[list[Mutant], int]:
    """Mutants of the Swift lines under Sources/ that differ from `base`, in the working tree, and the
    number of those lines skipped as SwiftUI view code. A renamed file counts as new, so all its
    lines are mutated; untracked Swift files count whole."""
    def names(*args: str) -> list[str]:
        return [name for name in git(*args, root=root).split("\0") if name.endswith(".swift")]

    changed: dict[str, set[int]] = {}
    for path in names("diff", "--name-only", "-z", "--no-renames", "--diff-filter=d", base, "--", "Sources"):
        # --literal-pathspecs whatever GIT_LITERAL_PATHSPECS says, and --text whatever attributes say,
        # so a listed file always shows its hunks.
        diff = git("--literal-pathspecs", "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                   "--text", "--no-renames", base, "--", path, root=root)
        empty = (root / path).exists() and (root / path).stat().st_size == 0
        if "\n@@ " not in "\n" + diff and "\nold mode " not in "\n" + diff and not empty:
            raise SystemExit("git diff lists %s as changed but shows no change to read; run with a plain "
                             "Git configuration or pass --base." % path)
        changed[path] = changed_lines(diff)
    for path in names("ls-files", "-z", "--others", "--exclude-standard", "--", "Sources"):
        changed[path] = set(range(1, len((root / path).read_text(encoding="utf-8").split("\n")) + 1))
    mutants: list[Mutant] = []
    skipped = 0
    for path, lines in sorted(changed.items()):
        if lines and (root / path).exists():
            source = (root / path).read_text(encoding="utf-8")
            mutants += mutants_for_file(path, source, lines)
            masked = mask(source)
            code_lines = masked.split("\n")
            skipped += len({number for number in lines & view_lines(masked) if code_lines[number - 1].strip()})
    return mutants, skipped


def copy_checkout(scratch: Path) -> None:
    for folder in ("Sources", "Tests"):
        shutil.copytree(ROOT / folder, scratch / folder)
    for name in ("project.yml", "Syrup.entitlements"):
        shutil.copy2(ROOT / name, scratch / name)
    (scratch / "script").mkdir()
    shutil.copy2(ROOT / "script" / "test-isolated.sh", scratch / "script" / "test-isolated.sh")
    resolved = Path("Syrup.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    if (ROOT / resolved).exists():
        (scratch / resolved).parent.mkdir(parents=True)
        shutil.copy2(ROOT / resolved, scratch / resolved)


def run_suite(scratch: Path, test_root: Path, log_path: Path, timeout: float,
              mutated_file: str | None = None) -> tuple[str, float]:
    """The run's class and its duration in seconds."""
    started = time.monotonic()
    environment = dict(os.environ, SYRUP_TEST_ROOT=str(test_root))
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen([str(scratch / "script" / "test-isolated.sh")], cwd=scratch, env=environment,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop(process, str(test_root))
            return "timed out", time.monotonic() - started
        except BaseException:
            stop(process, str(test_root))
            raise
    return classify(exit_code, log_path.read_text(encoding="utf-8", errors="replace"), mutated_file), time.monotonic() - started


def process_table() -> dict[int, tuple[int, str, str]]:
    """Every live process: its parent, its start time, and its executable. A zombie has already
    exited and only waits for its parent to collect it, so it is left out."""
    # In en_US.UTF-8 `lstart` is always five words, which some locales shorten, and paths come out as
    # they are, where the C locale escapes every non-ASCII byte.
    listing = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,stat=,lstart=,comm="], capture_output=True,
                             encoding="utf-8", errors="replace", env=dict(os.environ, LC_ALL="en_US.UTF-8")).stdout
    table = {}
    for line in listing.splitlines():
        parts = line.split(None, 8)
        if len(parts) == 9 and parts[0].isdigit() and parts[1].isdigit() and not parts[2].startswith("Z"):
            table[int(parts[0])] = (int(parts[1]), " ".join(parts[3:8]), parts[8].strip())
    return table


def owned(leader: int, build_folder: str, table: dict[int, tuple[int, str, str]]) -> dict[int, str]:
    """The processes the run started, by PID with their start times: the leader and its descendants,
    which include the compilers Xcode starts in process groups of their own, any process in the
    leader's session, and any process running an executable from the run's build folder: the test
    host, which launchd starts for xcodebuild.
    A process that only names the folder, such as one watching a log there, is not the run's."""
    children: dict[int, list[int]] = {}
    for pid, (parent, _, _) in table.items():
        children.setdefault(parent, []).append(pid)
    found = {leader: table[leader][1]} if leader in table else {}
    queue = [leader]
    while queue:
        for child in children.get(queue.pop(), []):
            if child not in found:
                found[child] = table[child][1]
                queue.append(child)
    # Compared in one Unicode form: launchd can report a path in decomposed form (NFD) where the run
    # spelled it composed (NFC), and APFS takes both as the same folder.
    prefixes = {unicodedata.normalize("NFC", folder.rstrip("/") + "/")
                for folder in (build_folder, os.path.realpath(build_folder))}
    for pid, (_, start, executable) in table.items():
        if any(unicodedata.normalize("NFC", executable).startswith(prefix) for prefix in prefixes):
            found[pid] = start
        elif pid not in found:
            # The leader starts a session of its own, so everything in it came from the run, even a
            # compiler Xcode's build service starts after xcodebuild has died.
            try:
                if os.getsid(pid) == leader:
                    found[pid] = start
            except OSError:
                pass
    found.pop(os.getpid(), None)
    return found


STOP_GRACE = 30  # seconds the run's processes get to stop after SIGTERM


def stop(process: subprocess.Popen, build_folder: str) -> None:
    """Stops every process the run started (see `owned`), not only its leader: a compiler that outlived
    the run would keep writing to the build folder the next mutant reuses. They are listed before any
    signal, since a process whose parent has exited no longer shows as a descendant, and each is
    signalled only while its start time still matches, so a reused PID is never touched."""
    targets = owned(process.pid, build_folder, process_table())

    def live() -> list[int]:
        table = process_table()
        for pid, start in owned(process.pid, build_folder, table).items():
            if pid not in targets:  # started while stopping: asked to stop at once, like the rest
                targets[pid] = start
                try:
                    os.kill(pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        return [pid for pid, start in targets.items() if pid in table and table[pid][1] == start]

    def send(sig: int) -> None:
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass  # macOS answers EPERM for a group whose only member has exited
        for pid in live():
            try:
                os.kill(pid, sig)
            except (ProcessLookupError, PermissionError):
                pass

    send(signal.SIGTERM)
    deadline = time.monotonic() + STOP_GRACE
    while time.monotonic() < deadline:
        process.poll()  # reap the leader, so it no longer counts
        if not live():
            break
        time.sleep(0.2)
    else:
        send(signal.SIGKILL)
    process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="commit to compare with (default: the merge base with main)")
    parser.add_argument("--limit", type=int, help="most mutants to run (default: SYRUP_MUTANTS, else %d)" % DEFAULT_LIMIT)
    parser.add_argument("--only", action="append", default=[], metavar="PATH:LINE",
                        help="run only the mutants of this line, such as a survivor being fixed")
    parser.add_argument("--list", action="store_true", help="list the mutants without running them")
    parser.add_argument("--logs", type=Path, help="keep each run's output in this folder")
    arguments = parser.parse_args()
    if arguments.limit is None:
        setting = os.environ.get("SYRUP_MUTANTS", "").strip()
        if not setting.isdigit() and setting:
            parser.error("SYRUP_MUTANTS must be a whole number: %r" % setting)
        arguments.limit = int(setting) if setting else DEFAULT_LIMIT
    if arguments.limit < 1:
        parser.error("the limit must be at least 1")
    if arguments.logs and arguments.logs.exists() and not arguments.logs.is_dir():
        parser.error("--logs must name a folder: %s" % arguments.logs)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))  # a closed terminal stops the run cleanly too
    # Even when started with SIGINT ignored, as a background job is, an interrupt stops the run cleanly.
    signal.signal(signal.SIGINT, signal.default_int_handler)

    base = arguments.base
    for candidate in ("main", "origin/main"):
        if base:
            break
        try:
            base = git("merge-base", candidate, "HEAD").strip()
        except subprocess.CalledProcessError:
            continue
    if not base:
        sys.exit("No merge base with main or origin/main; pass --base <commit>.")
    equivalent = load_equivalent(EQUIVALENT)
    stale = stale_entries(EQUIVALENT)
    if stale:
        for entry in stale:
            print("Stale entry in %s, matching no line of %s: %s" % (EQUIVALENT.name, entry["file"], entry["original"]))
        print("Update or remove each one: the code it reasoned about has changed.")
        return 1
    mutants, skipped = branch_mutants(base)
    if arguments.only:
        mutants = [mutant for mutant in mutants if "%s:%d" % (mutant.path, mutant.line) in arguments.only]
        matched = {"%s:%d" % (mutant.path, mutant.line) for mutant in mutants}
        for spec in arguments.only:
            if spec not in matched:
                parser.error("--only %s names no mutant of a changed line" % spec)
    listed = [mutant for mutant in mutants if mutant.key in equivalent]
    candidates = [mutant for mutant in mutants if mutant.key not in equivalent]
    picked = select(candidates, arguments.limit)
    print("Mutation testing against %s: %d mutants of changed lines, %d listed as equivalent, %d run, %d left out by the limit of %d."
          % (base[:12], len(mutants), len(listed), len(picked), len(candidates) - len(picked), arguments.limit), flush=True)
    if skipped:
        print("%d changed lines inside SwiftUI views were not mutated; docs/QA.md checks views." % skipped, flush=True)
    if arguments.list:
        for mutant in picked:
            print("  %s:%d  %s\n    - %s\n    + %s" % (mutant.path, mutant.line, mutant.operator, mutant.original.strip(), mutant.mutated.strip()))
        return 0
    if not picked:
        return 0

    scratch = Path(tempfile.mkdtemp(prefix="syrup-mutation."))
    try:
        checkout, test_root, logs = scratch / "checkout", scratch / "test-root", scratch / "logs"
        checkout.mkdir()
        logs.mkdir()
        copy_checkout(checkout)
        result, baseline = run_suite(checkout, test_root, logs / "baseline.log", timeout=1800)
        if result != "survived":
            print("The unchanged suite did not pass in the scratch copy (%s); no mutants were run." % result)
            print("\n".join(Path(logs / "baseline.log").read_text(encoding="utf-8", errors="replace").splitlines()[-30:]))
            return 1
        print("Unchanged suite passed in %.0f s." % baseline, flush=True)
        timeout = baseline + 300
        results: list[tuple[Mutant, str]] = []
        for number, mutant in enumerate(picked, 1):
            file = checkout / mutant.path
            original = file.read_text(encoding="utf-8")
            lines = original.split("\n")
            assert lines[mutant.line - 1] == mutant.original, mutant
            lines[mutant.line - 1] = mutant.mutated
            file.write_text("\n".join(lines), encoding="utf-8")
            try:
                result, seconds = run_suite(checkout, test_root, logs / ("mutant-%d.log" % number), timeout, mutant.path)
            finally:
                file.write_text(original, encoding="utf-8")
            results.append((mutant, result))
            print("[%d/%d] %-15s %4.0f s  %s:%d  %s" % (number, len(picked), result, seconds, mutant.path, mutant.line, mutant.operator), flush=True)

        failing = [(mutant, result) for mutant, result in results if result in ("survived", "unclassified")]
        counts = {name: sum(1 for _, result in results if result == name)
                  for name in ("killed", "timed out", "survived", "did not compile", "unclassified")}
        print("Killed %(killed)d, timed out %(timed out)d (counted as killed), survived %(survived)d, did not compile %(did not compile)d, unclassified %(unclassified)d." % counts)
        for mutant, result in failing:
            print("%s: %s:%d (%s)\n  - %s\n  + %s" % (result, mutant.path, mutant.line, mutant.operator, mutant.original.strip(), mutant.mutated.strip()))
            if result == "survived":
                print("  entry: " + mutant.entry())
            else:
                # Name what the compiler or the run reported, so an odd run can be read without its log.
                number = picked.index(mutant) + 1
                log = (logs / ("mutant-%d.log" % number)).read_text(encoding="utf-8", errors="replace")
                for line in [line for line in log.splitlines() if ": error:" in line][:3]:
                    print("  " + line.strip()[-200:])
        if failing:
            print("Add a test that fails on each survivor. Only if a survivor cannot change behavior, add its entry to %s with the reason."
                  % EQUIVALENT.relative_to(ROOT))
        return 1 if failing else 0
    finally:
        try:
            if arguments.logs and (scratch / "logs").exists():
                shutil.copytree(scratch / "logs", arguments.logs, dirs_exist_ok=True)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
            remove_lock_files(Path(tempfile.gettempdir()), scratch.name)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted; any mutant run under way was stopped and its scratch copy removed.", file=sys.stderr)
        sys.exit(130)
