import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import random
import re
import selectors
import statistics
import subprocess
import sys
import time
import unicodedata
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[2]
TOOL = Path(__file__).resolve().parent
CACHE = ROOT / ".cache/recognition-eval"


class EvalClip(TypedDict):
    id: str
    wav: str
    locale: str
    reference: str
    expectedTerms: list[str]
    group: str


class EvalOptions(TypedDict):
    vocabulary: bool
    aliases: bool
    boostRescue: str
    trimEndMs: int
    realtime: bool
    preferFastResults: bool
    bufferMs: int | None
    wholeBuffer: bool
    prefixAfterSpeechMs: int | None
    endSilenceMs: int | None


class EvalResult(TypedDict):
    engine: str
    clipId: str
    options: EvalOptions
    hypothesis: str
    wer: float
    termRecall: float | None
    excessVocabularyOccurrences: int | None
    setupMs: float
    finalizationMs: float


class EvalError(Exception):
    pass


def words(text):
    text = unicodedata.normalize("NFC", text).casefold()
    return re.findall(r"[^\W_]+", text.replace("'", "").replace("’", ""), re.UNICODE)


def occurrences(tokens, term):
    size = len(term)
    return sum(tokens[i:i + size] == term for i in range(len(tokens) - size + 1)) if size else 0


def score(reference, hypothesis, expected, vocabulary):
    ref, hyp = words(reference), words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, left in enumerate(ref, 1):
        next_row = [i]
        for j, right in enumerate(hyp, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (left != right)))
        row = next_row
    recalled = sum(occurrences(hyp, words(term)) > 0 for term in expected)
    excess = sum(max(0, occurrences(hyp, words(term)) - occurrences(ref, words(term))) for term in vocabulary)
    return dict(
        wordErrors=row[-1], referenceWords=len(ref), wer=row[-1] / len(ref),
        termsRecalled=recalled, expectedTermCount=len(expected),
        termRecall=recalled / len(expected) if expected else None,
        excessVocabularyOccurrences=excess, lastWordRetained=bool(hyp and ref[-1] == hyp[-1]),
    )


def in_git(path):
    parent = path.resolve()
    while not parent.is_dir():
        parent = parent.parent
    return subprocess.run(["git", "-C", str(parent), "rev-parse", "--is-inside-work-tree"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def load_clips():
    private_path = os.environ.get("SYRUP_EVAL_PRIVATE_MANIFEST")
    manifest = Path(private_path).expanduser().resolve() if private_path else TOOL / "clips.json"
    if private_path and in_git(manifest):
        raise EvalError("Private manifests must be outside Git worktrees.")
    clips: list[EvalClip] = json.loads(manifest.read_text())
    ids = set()
    for clip in clips:
        if (set(clip) != {"id", "wav", "locale", "reference", "expectedTerms", "group"}
                or not all(isinstance(clip[key], str) for key in ("id", "wav", "locale", "reference", "group"))
                or clip["group"] not in ("target", "guard")
                or not re.fullmatch(r"[a-z]{2,3}[-_][A-Za-z]{2,4}", clip["locale"])
                or not re.fullmatch(r"[A-Za-z0-9_-]+", clip["id"])
                or clip["id"] in ids or not words(clip["reference"])
                or not isinstance(clip["expectedTerms"], list)
                or not all(isinstance(term, str) and words(term) for term in clip["expectedTerms"])
                or (clip["group"] == "guard" and clip["expectedTerms"])):
            raise EvalError("Invalid EvalClip manifest.")
        ids.add(clip["id"])
        audio = (manifest.parent if private_path else CACHE) / clip["wav"]
        if private_path and in_git(audio):
            raise EvalError("Private audio must be outside Git worktrees.")
        if not private_path and (audio.resolve().parent != (CACHE / "audio").resolve()):
            raise EvalError("Synthetic audio must stay in the ignored audio directory.")
    if not clips:
        raise EvalError("The manifest is empty.")
    return clips, manifest, bool(private_path)


def load_aliases(path):
    aliases = json.loads(Path(path).read_text())
    if not isinstance(aliases, dict) or not all(
            isinstance(term, str) and isinstance(forms, list) and forms and all(isinstance(form, str) and words(form) for form in forms)
            for term, forms in aliases.items()):
        raise EvalError("Aliases must map each term to a non-empty list of strings.")
    return aliases


def generate():
    clips, _, private = load_clips()
    if private:
        raise EvalError("Fixture generation uses only the committed synthetic manifest. Unset SYRUP_EVAL_PRIVATE_MANIFEST.")
    voices = {
        "pt-BR": ["Luciana (Portuguese (Brazil))", "Eddy (Portuguese (Brazil))", "Flo (Portuguese (Brazil))"],
        "en-US": ["Samantha (English (US))", "Eddy (English (US))", "Flo (English (US))"],
    }
    (CACHE / "audio").mkdir(parents=True, exist_ok=True)
    metadata = []
    for index, clip in enumerate(clips):
        wav = CACHE / clip["wav"]
        voice = voices[clip["locale"]][index % 3]
        subprocess.run(["say", "-v", voice, "-r", "175", "--file-format=WAVE", "--data-format=LEI16@24000",
                        "-o", str(wav), clip["reference"]], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        metadata.append(dict(id=clip["id"], voice=voice, sha256=hashlib.sha256(wav.read_bytes()).hexdigest()))
    (CACHE / "fixtures.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated {len(clips)} synthetic WAV files in {CACHE / 'audio'}")


ENGINES = ("apple", "parakeet-v3", "parakeet-ultra", "parakeet-redux", "parakeet-unified",
           "nemotron-latin-2240", "nemotron-multi-2240", "nemotron-multi-1120", "canary-180m")


def build(engine="apple"):
    CACHE.mkdir(parents=True, exist_ok=True)
    if engine == "apple":
        binary = CACHE / "runner"
        source = TOOL / "Runner.swift"
        if not binary.exists() or source.stat().st_mtime > binary.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)], check=True)
        return [str(binary)]
    if engine == "canary-180m":
        binary = CACHE / "canary-runner"
        sources = [TOOL / "canary/main.swift", ROOT / "Sources/Transcription/CanaryModel.swift",
                   ROOT / "Sources/Transcription/SpeechSegmenter.swift"]
        if not binary.exists() or max(p.stat().st_mtime for p in sources) > binary.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-swift-version", "6", "-parse-as-library", *map(str, sources),
                            "-o", str(binary)], check=True)
        return [str(binary), str(CACHE / "models")]
    scratch = CACHE / "parakeet-build"
    subprocess.run(["swift", "build", "-c", "release", "--package-path", str(TOOL / "parakeet"), "--scratch-path", str(scratch)],
                   check=True, stdout=subprocess.DEVNULL)
    return [str(scratch / "release/ParakeetRunner"), engine.removeprefix("parakeet-"), str(CACHE / "models")]


def run(args):
    engines = args.engine.split(",")
    if "whisper" in engines:
        raise EvalError("Whisper is unavailable in this standalone tool. See script/recognition-eval/usage.md. No model was downloaded.")
    if set(engines) - set(ENGINES) or len(set(engines)) != len(engines):
        raise EvalError(f"--engine takes distinct comma-separated values from: {', '.join(ENGINES)}.")
    whole_buffer = getattr(args, "whole_buffer", False)
    if whole_buffer and (engines != ["apple"] or args.realtime):
        raise EvalError("Whole-buffer input requires offline Apple.")
    prefix = getattr(args, "prefix_after_speech_ms", None)
    silence = getattr(args, "end_silence_ms", None)
    if prefix is not None or silence is not None:
        if engines != ["apple"] or args.trim_sweep or args.trim_end_ms or (prefix is not None and args.realtime):
            raise EvalError("Speech-end prefixes require offline Apple; silence padding requires Apple, without trimming.")
        if any(value is not None and value < 0 for value in (prefix, silence)):
            raise EvalError("Speech-end offsets must be nonnegative.")
    aliases = load_aliases(args.aliases) if args.aliases else {}
    clips, manifest, private = load_clips()
    vocabulary = sorted({term for clip in clips for term in clip["expectedTerms"]}, key=str.casefold)
    if len(vocabulary) > 100:
        raise EvalError("At most 100 vocabulary terms are supported, matching AppleTranscriber.")
    if set(aliases) - set(vocabulary):
        raise EvalError("Every alias key must be a vocabulary term from the manifest.")
    if args.clips:
        selected = set(args.clips.split(","))
        if selected - {clip["id"] for clip in clips}:
            raise EvalError("An unknown clip ID was requested.")
        clips = [clip for clip in clips if clip["id"] in selected]
    output = Path(args.output).expanduser().resolve() if args.output else CACHE / "results.jsonl"
    if private and (not args.output or in_git(output)):
        raise EvalError("Private results require --output outside Git worktrees.")
    if in_git(output) and subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(output)],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise EvalError("Raw results must be ignored or outside Git worktrees.")
    output.parent.mkdir(parents=True, exist_ok=True)
    commands = {engine: build(engine) for engine in engines}
    trims = [0, 100, 200, 300, 400, 500, 600] if args.trim_sweep else [args.trim_end_ms]
    modes = [False, True] if args.vocabulary == "both" else [args.vocabulary == "on"]
    workers, selectors_by_engine = {}, {}
    for engine, command in commands.items():
        workers[engine] = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, text=True, bufsize=1)
        selectors_by_engine[engine] = selectors.DefaultSelector()
        selectors_by_engine[engine].register(workers[engine].stdout, selectors.EVENT_READ)
    completed, failed = 0, 0
    try:
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as sink:
            for repetition in range(args.repeats):
                ordered = list(clips)
                random.Random(20261101 + repetition).shuffle(ordered)
                for clip in ordered:
                    offsets = trims[repetition % len(trims):] + trims[:repetition % len(trims)]
                    for trim in offsets:
                        for enabled, engine in [(enabled, engine) for enabled in modes for engine in engines][::1 if repetition % 2 == 0 else -1]:
                            worker = workers[engine]
                            wav = ((manifest.parent if private else CACHE) / clip["wav"]).resolve()
                            options: EvalOptions = dict(vocabulary=enabled, aliases=enabled and bool(aliases), boostRescue=args.boost_rescue,
                                                        trimEndMs=trim, realtime=args.realtime, bufferMs=20, preferFastResults=getattr(args, "prefer_fast_results", False))
                            options.update(prefixAfterSpeechMs=prefix, endSilenceMs=silence, wholeBuffer=whole_buffer)
                            if whole_buffer: options["bufferMs"] = None
                            result = dict(engine=engine, clipId=clip["id"], group=clip["group"], locale=clip["locale"],
                                          repetition=repetition, options=options, private=private)
                            request = dict(wav=str(wav), locale=clip["locale"], vocabulary=vocabulary if enabled else [],
                                           aliases=aliases if enabled else {}, boostRescue=args.boost_rescue, trimEndMs=trim, realtime=args.realtime, preferFastResults=getattr(args, "prefer_fast_results", False))
                            request.update(prefixAfterSpeechMs=prefix, endSilenceMs=silence, wholeBuffer=whole_buffer)
                            start = time.monotonic()
                            worker.stdin.write(json.dumps(request) + "\n")
                            worker.stdin.flush()
                            if not selectors_by_engine[engine].select(args.timeout_seconds):
                                result.update(status="timedOut", error="recognitionTimedOut", wallMs=(time.monotonic() - start) * 1000)
                                sink.write(json.dumps(result) + "\n")
                                sink.flush()
                                raise EvalError("Recognition timed out; partial results are preserved.")
                            line = worker.stdout.readline()
                            if not line:
                                result.update(status="failed", error="workerExited", wallMs=(time.monotonic() - start) * 1000)
                                sink.write(json.dumps(result) + "\n")
                                sink.flush()
                                raise EvalError("Recognition worker exited; partial results are preserved.")
                            recognition = json.loads(line)
                            if "error" in recognition:
                                result.update(status="failed", error=recognition["error"])
                                failed += 1
                            else:
                                result.update(status="passed", **recognition)
                                result.update(score(clip["reference"], result["hypothesis"], clip["expectedTerms"], vocabulary))
                                if clip["group"] != "guard":
                                    result["excessVocabularyOccurrences"] = None
                                completed += 1
                            result["wallMs"] = (time.monotonic() - start) * 1000
                            sink.write(json.dumps(result, ensure_ascii=False) + "\n")
                            sink.flush()
                            if args.show_text and "hypothesis" in result:
                                print(result["hypothesis"])
                print(f"Completed repetition {repetition + 1}/{args.repeats}; passed={completed}, failed={failed}", flush=True)
    finally:
        for engine, worker in workers.items():
            selectors_by_engine[engine].close()
            worker.terminate()
            worker.wait(timeout=10)
            worker.stdin.close()
            worker.stdout.close()
    summary(output)
    if failed:
        raise EvalError("Some recognition runs failed.")


def distribution(values):
    return dict(median=round(statistics.median(values), 3), min=round(min(values), 3), max=round(max(values), 3))


def partial_readiness(rows):
    matches = [row["partialMatchAfterSpeechMs"] for row in rows if row.get("partialMatchAfterSpeechMs") is not None]
    return dict(partialMatchedBeforeRelease=len(matches),
                partialMatchAfterSpeechMs=distribution(matches) if matches else None,
                partialWithinSilenceMs={str(ms): sum(value <= ms for value in matches) for ms in (300, 600, 1000)})


def summary(path):
    groups = defaultdict(list)
    for line in Path(path).read_text().splitlines():
        result = json.loads(line)
        key = (result["engine"], result["locale"], result["options"]["vocabulary"],
               result["options"]["trimEndMs"], result["options"]["realtime"], result["options"].get("preferFastResults", False),
               result["options"].get("prefixAfterSpeechMs"), result["options"].get("endSilenceMs"),
               result["options"].get("wholeBuffer", False))
        groups[key].append(result)
    summaries = []
    for key, rows in sorted(groups.items(), key=lambda item: str(item[0])):
        passed = [row for row in rows if row["status"] == "passed"]
        entry = dict(engine=key[0], locale=key[1], vocabulary=key[2], trimEndMs=key[3], realtime=key[4],
                     preferFastResults=key[5], prefixAfterSpeechMs=key[6], endSilenceMs=key[7], wholeBuffer=key[8], runs=len(rows), passed=len(passed), failed=sum(row["status"] == "failed" for row in rows),
                     timedOut=sum(row["status"] == "timedOut" for row in rows))
        if passed:
            terms = sum(row["expectedTermCount"] for row in passed)
            guards = [row for row in passed if row["group"] == "guard"]
            targets = [row for row in passed if row["group"] == "target"]
            entry.update(
                wer=sum(row["wordErrors"] for row in passed) / sum(row["referenceWords"] for row in passed),
                targetWer=sum(row["wordErrors"] for row in targets) / sum(row["referenceWords"] for row in targets) if targets else None,
                guardWer=sum(row["wordErrors"] for row in guards) / sum(row["referenceWords"] for row in guards) if guards else None,
                termRecall=sum(row["termsRecalled"] for row in passed) / terms if terms else None,
                guardExcessVocabularyOccurrences=sum(row["excessVocabularyOccurrences"] for row in guards),
                guardRuns=len(guards), lastWordRetained=sum(row["lastWordRetained"] for row in passed),
                finalizationMs=distribution([row["finalizationMs"] for row in passed]),
                setupMs=distribution([row["setupMs"] for row in passed]),
                feedMinusAudioMs=distribution([row["feedMs"] - row["audioMs"] for row in passed]),
            )
            if key[0] == "apple" and key[4]:
                entry.update(partial_readiness(passed))
        summaries.append(entry)
    print(json.dumps(summaries, indent=2))


def compare_pauses(rows):
    references = {}
    prefixes = []
    for row in rows:
        options = row["options"]
        key = (row["clipId"], row["locale"], options.get("preferFastResults", False),
               options["vocabulary"], row["repetition"])
        if options.get("prefixAfterSpeechMs") is not None and not options["realtime"]:
            prefixes.append((key, row))
        elif options["realtime"]:
            if key in references:
                raise EvalError("Duplicate realtime reference in pause comparison.")
            references[key] = row
    groups = defaultdict(list)
    seen = set()
    for key, row in prefixes:
        offset = row["options"]["prefixAfterSpeechMs"]
        if (key, offset) in seen:
            raise EvalError("Duplicate offline prefix in pause comparison.")
        seen.add((key, offset))
        reference = references.get(key)
        if reference is None:
            raise EvalError("Missing realtime reference in pause comparison.")
        groups[(key[1], key[2], key[3], offset)].append((row, reference))
    summaries = []
    for (locale, fast, vocabulary, offset), pairs in sorted(groups.items()):
        valid = [(p, r) for p, r in pairs if p["status"] == r["status"] == "passed"
                 and p["hypothesis"].strip() and r["hypothesis"].strip()]
        matched = sum(p["hypothesis"].strip().encode("utf-8") == r["hypothesis"].strip().encode("utf-8")
                      for p, r in valid)
        by_clip = defaultdict(list)
        for p, _ in valid:
            by_clip[p["clipId"]].append(p)
        summaries.append(dict(locale=locale, preferFastResults=fast, vocabulary=vocabulary,
            prefixAfterSpeechMs=offset, pairs=len(pairs), valid=len(valid), invalid=len(pairs)-len(valid),
            matched=matched, equalityRate=matched/len(pairs),
            offlineWallMs=distribution([p["wallMs"] for p, _ in valid]) if valid else None,
            latencyByClip=[dict(clipId=clip, audioMs=distribution([p["audioMs"] for p in values]),
                                wallMs=distribution([p["wallMs"] for p in values]))
                           for clip, values in sorted(by_clip.items())]))
    return summaries


def main():
    parser = argparse.ArgumentParser(description="Synthetic SpeechAnalyzer recognition evaluation. Raw results never overwrite an existing file.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("generate", help="Generate the committed invented sentences with macOS say.")
    builder = commands.add_parser("build", help="Compile an optimized runner without running recognition.")
    builder.add_argument("--engine", choices=ENGINES, default="apple")
    summarize = commands.add_parser("summary", help="Print aggregate metrics, never transcript text.")
    summarize.add_argument("results", type=Path)
    comparison = commands.add_parser("compare-pauses", help="Compare offline prefixes with matched realtime release rows, using trimmed UTF-8 bytes.")
    comparison.add_argument("results", type=Path)
    evaluate = commands.add_parser("run", help="Evaluate fixtures or SYRUP_EVAL_PRIVATE_MANIFEST.")
    evaluate.add_argument("--engine", default="apple", help=f"Comma-separated engines run in alternating order: {', '.join(ENGINES)}.")
    evaluate.add_argument("--vocabulary", choices=["on", "off", "both"], default="both")
    evaluate.add_argument("--aliases", help="JSON object mapping vocabulary terms to misheard forms, sent with the vocabulary. Apple ignores it.")
    evaluate.add_argument("--boost-rescue", choices=["default", "floors", "off"], default="default",
                          help="Parakeet spotter-anchored rescue: FluidAudio's default, its recommended similarity floors, or off.")
    evaluate.add_argument("--trim-end-ms", type=int, default=0)
    evaluate.add_argument("--trim-sweep", action="store_true")
    evaluate.add_argument("--realtime", action="store_true")
    evaluate.add_argument("--prefer-fast-results", action="store_true", help="Use Apple's fast partial-result mode.")
    evaluate.add_argument("--whole-buffer", action="store_true", help="Feed the offline Apple snapshot in one buffer, matching the app pause pass.")
    evaluate.add_argument("--prefix-after-speech-ms", type=int, help="Offline Apple prefix ending this many ms after the last voiced sample (amplitude > 0.01), padded with silence if needed.")
    evaluate.add_argument("--end-silence-ms", type=int, help="Pad Apple input in memory to at least this much end silence.")
    evaluate.add_argument("--repeats", type=int, default=5)
    evaluate.add_argument("--clips", help="Comma-separated fixture IDs.")
    evaluate.add_argument("--output", help="New ignored path, or an external path for private results.")
    evaluate.add_argument("--show-text", action="store_true", help="Explicitly print hypotheses, including private content.")
    evaluate.add_argument("--timeout-seconds", type=float, default=120)
    args = parser.parse_args()
    if args.command == "generate":
        generate()
    elif args.command == "build":
        print(build(args.engine)[0])
    elif args.command == "compare-pauses":
        print(json.dumps(compare_pauses([json.loads(line) for line in args.results.read_text().splitlines()]), indent=2))
    elif args.command == "summary":
        summary(args.results)
    elif args.repeats < 1 or args.trim_end_ms < 0 or args.timeout_seconds <= 0:
        parser.error("Repeats and timeout must be positive; trim must be nonnegative.")
    else:
        run(args)


if __name__ == "__main__":
    try:
        main()
    except EvalError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError, KeyError, TypeError):
        print("Evaluation failed. Check arguments, manifest, installed assets, audio files, and output permissions. Existing results are never overwritten.", file=sys.stderr)
        sys.exit(1)
