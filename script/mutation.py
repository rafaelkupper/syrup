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
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EQUIVALENT = Path(__file__).resolve().parent / "mutation-equivalent.json"
DEFAULT_LIMIT = 20


# MARK: - Which lines changed


def changed_lines(diff: str) -> dict[str, set[int]]:
    """Line numbers in the new version of each file, from `git diff -U0` output."""
    changed: dict[str, set[int]] = {}
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            target = line[4:]
            path = target[2:] if target.startswith("b/") else None
        elif line.startswith("@@") and path:
            match = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
            if match:
                start, count = int(match.group(1)), int(match.group(2) or "1")
                changed.setdefault(path, set()).update(range(start, start + count))
    return {path: lines for path, lines in changed.items() if lines}


# MARK: - Code without comments and strings


def mask(source: str) -> str:
    """The source with comments and string-literal contents replaced by spaces, newlines kept, so a
    column in the result is the same column in the source. Code inside `\\(...)` stays code."""
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
                stack.append(["string", len(match.group(1)), match.group(2) == '"""'])
                index = match.end()
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
    # Which line with this text it is, counting from the top of the file, since a file can repeat a
    # line in places that behave differently.
    occurrence: int = 1

    @property
    def key(self) -> tuple[str, str, str, int]:
        return (self.path, self.original.strip(), self.mutated.strip(), self.occurrence)

    @property
    def order(self) -> str:
        return hashlib.sha256("\0".join(str(part) for part in self.key + (self.line,)).encode()).hexdigest()

    def entry(self) -> str:
        """The mutation-equivalent.json entry that would list this mutant, reason left to fill in."""
        return json.dumps({"file": self.path, "original": self.original.strip(), "mutated": self.mutated.strip(),
                           "occurrence": self.occurrence, "reason": ""})


KEYWORDS = {"return", "if", "guard", "let", "var", "case", "switch", "while", "for", "throw", "defer",
            "else", "repeat", "do", "catch", "import", "func", "init", "deinit", "super", "await", "try"}
BOOL_COMPARISON = re.compile(r"(==|!=)(\s*)(true|false)\b")
REPLACEMENTS = [
    ("== to !=", re.compile(r"(?<![=!<>])==(?!=)(?!\s*(?:true|false)\b)"), "!="),
    ("!= to ==", re.compile(r"!=(?!=)(?!\s*(?:true|false)\b)"), "=="),
    ("&& to ||", re.compile(r"&&"), "||"),
    ("|| to &&", re.compile(r"\|\|"), "&&"),
    ("true to false", re.compile(r"(?<!==)(?<!!=)(?<![=!]\s)\btrue\b"), "false"),
    ("false to true", re.compile(r"(?<!==)(?<!!=)(?<![=!]\s)\bfalse\b"), "true"),
    ("< to <=", re.compile(r"(?<=\s)<(?=\s)"), "<="),
    ("<= to <", re.compile(r"(?<=\s)<=(?=\s)"), "<"),
    ("> to >=", re.compile(r"(?<=\s)>(?=\s)"), ">="),
    (">= to >", re.compile(r"(?<=\s)>=(?=\s)"), ">"),
]
CALL = re.compile(r"(?:try\s+|await\s+|try\s+await\s+)?([A-Za-z_]\w*)(?:\??\.[A-Za-z_]\w*)*\(.*\)")
ASSIGNMENT = re.compile(r"(?:self\.)?([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*\s*(?:=(?!=)|\+=|-=)\s*\S.*")


def balanced(text: str) -> bool:
    depth = 0
    for character in text:
        depth += {"(": 1, ")": -1}.get(character, 0)
        if depth < 0:
            return False
    return depth == 0


def mutants_for_line(path: str, number: int, line: str, code: str, occurrence: int = 1) -> list[Mutant]:
    """Every mutant of one line. `code` is the line masked, so matches are on code only."""
    found: list[Mutant] = []

    def add(operator: str, start: int, end: int, replacement: str) -> None:
        mutated = line[:start] + replacement + line[end:]
        if mutated != line:
            found.append(Mutant(path, number, line, mutated, operator, occurrence))

    for match in BOOL_COMPARISON.finditer(code):
        literal = match.start(3)
        add("compared Bool flipped", literal, match.end(3), "false" if match.group(3) == "true" else "true")
    for operator, pattern, replacement in REPLACEMENTS:
        for match in pattern.finditer(code):
            add(operator, match.start(), match.end(), replacement)
    statement = code.strip()
    indent = line[: len(line) - len(line.lstrip())]
    for pattern in (CALL, ASSIGNMENT):
        match = pattern.fullmatch(statement)
        if match and match.group(1) not in KEYWORDS and balanced(statement):
            found.append(Mutant(path, number, line, indent, "statement deleted", occurrence))
            break
    return found


def mutants_for_file(path: str, source: str, lines: set[int]) -> list[Mutant]:
    source_lines = source.split("\n")
    code_lines = mask(source).split("\n")
    found: list[Mutant] = []
    seen: dict[str, int] = {}
    for number, line in enumerate(source_lines, 1):
        seen[line.strip()] = seen.get(line.strip(), 0) + 1
        if number in lines:
            found += mutants_for_line(path, number, line, code_lines[number - 1], seen[line.strip()])
    return found


def select(mutants: list[Mutant], limit: int) -> list[Mutant]:
    """At most `limit`, picked by a hash of their text, then in file and line order."""
    picked = sorted(mutants, key=lambda mutant: mutant.order)[:limit]
    return sorted(picked, key=lambda mutant: (mutant.path, mutant.line, mutant.operator, mutant.mutated))


def load_equivalent(path: Path) -> set[tuple[str, str, str, int]]:
    if not path.exists():
        return set()
    entries = json.loads(path.read_text())["equivalent"]
    for entry in entries:
        if not entry.get("reason", "").strip():
            raise SystemExit("mutation-equivalent.json: every entry needs a reason: %r" % entry)
    return {(entry["file"], entry["original"].strip(), entry["mutated"].strip(), int(entry.get("occurrence", 1)))
            for entry in entries}


# MARK: - Reading a run


SUMMARY = re.compile(r"Test run with (\d+) tests? in \d+ suites? (passed|failed)")
BUILD_FAILED = ("Testing cancelled because the build failed.", "The following build commands failed:",
                "** BUILD FAILED **", "** TEST BUILD FAILED **")


def classify(exit_code: int, log: str) -> str:
    """killed, survived, did not compile, or unclassified, from a run's exit code and output.
    Anything this cannot read as one of the first three is unclassified, which fails the run, so an
    odd run is never taken for a catch."""
    # `xcodebuild test` reports a compile error as a failed test run, so look for the build's own words.
    if any(marker in log for marker in BUILD_FAILED):
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


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def branch_mutants(base: str) -> list[Mutant]:
    diff = git("diff", "-U0", "--no-color", "--no-ext-diff", base, "--", "Sources")
    changed = changed_lines(diff)
    for path in git("ls-files", "--others", "--exclude-standard", "--", "Sources").splitlines():
        changed[path] = set(range(1, len((ROOT / path).read_text().split("\n")) + 1))
    mutants: list[Mutant] = []
    for path, lines in sorted(changed.items()):
        if path.endswith(".swift") and (ROOT / path).exists():
            mutants += mutants_for_file(path, (ROOT / path).read_text(), lines)
    return mutants


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


def run_suite(scratch: Path, test_root: Path, log_path: Path, timeout: float) -> tuple[str, float]:
    """The run's class and its duration in seconds."""
    started = time.monotonic()
    environment = dict(os.environ, SYRUP_TEST_ROOT=str(test_root))
    with log_path.open("w") as log:
        process = subprocess.Popen([str(scratch / "script" / "test-isolated.sh")], cwd=scratch, env=environment,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop(process)
            return "timed out", time.monotonic() - started
        except BaseException:
            stop(process)
            raise
    return classify(exit_code, log_path.read_text(errors="replace")), time.monotonic() - started


def stop(process: subprocess.Popen) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=30)
            return
        except subprocess.TimeoutExpired:
            continue


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="commit to compare with (default: the merge base with main)")
    parser.add_argument("--limit", type=int, default=int(os.environ.get("SYRUP_MUTANTS", DEFAULT_LIMIT)))
    parser.add_argument("--only", action="append", default=[], metavar="PATH:LINE",
                        help="run only the mutants of this line, such as a survivor being fixed")
    parser.add_argument("--list", action="store_true", help="list the mutants without running them")
    parser.add_argument("--logs", type=Path, help="keep each run's output in this folder")
    arguments = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    base = arguments.base or git("merge-base", "main", "HEAD").strip()
    equivalent = load_equivalent(EQUIVALENT)
    mutants = branch_mutants(base)
    if arguments.only:
        mutants = [mutant for mutant in mutants if "%s:%d" % (mutant.path, mutant.line) in arguments.only]
    listed = [mutant for mutant in mutants if mutant.key in equivalent]
    candidates = [mutant for mutant in mutants if mutant.key not in equivalent]
    picked = select(candidates, arguments.limit)
    print("Mutation testing against %s: %d mutants of changed lines, %d listed as equivalent, %d run, %d left out by the limit of %d."
          % (base[:12], len(mutants), len(listed), len(picked), len(candidates) - len(picked), arguments.limit))
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
            print("\n".join(Path(logs / "baseline.log").read_text(errors="replace").splitlines()[-30:]))
            return 1
        print("Unchanged suite passed in %.0f s." % baseline)
        timeout = baseline + 300
        results: list[tuple[Mutant, str]] = []
        for number, mutant in enumerate(picked, 1):
            file = checkout / mutant.path
            original = file.read_text()
            lines = original.split("\n")
            assert lines[mutant.line - 1] == mutant.original, mutant
            lines[mutant.line - 1] = mutant.mutated
            file.write_text("\n".join(lines))
            try:
                result, seconds = run_suite(checkout, test_root, logs / ("mutant-%d.log" % number), timeout)
            finally:
                file.write_text(original)
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
        if failing:
            print("Add a test that fails on each survivor. Only if a survivor cannot change behavior, add its entry to %s with the reason."
                  % EQUIVALENT.relative_to(ROOT))
        return 1 if failing else 0
    finally:
        if arguments.logs and (scratch / "logs").exists():
            shutil.copytree(scratch / "logs", arguments.logs, dirs_exist_ok=True)
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
