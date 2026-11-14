#!/usr/bin/env python3
"""Generates Tests/SyrupTests/ProviderCorpus.swift from corpus.json.

corpus.json holds stream chunks and error bodies copied from provider documentation on the date it
names, each with its source URL and a phrase from the page. This script decides, per entry, how the
documented example is put on the wire and what the page says it carries, and writes the Swift cases.
Run it from the repository root: python3 -I script/provider-corpus/generate.py
"""
import json
import pathlib
import re

import hashlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = HERE.parent.parent / "Tests" / "SyrupTests" / "ProviderCorpus.swift"
corpus = json.loads((HERE / "corpus.json").read_text())
ENTRIES = corpus["entries"]
# The tables below are keyed by entry position. If corpus.json gains, loses, or reorders entries, the
# positions no longer match; recheck every table, then update this digest of the entries' labels.
LABELS_DIGEST = "d0d7bb981b4d262cd4348bd9642031ba7f070207aa9eb8b1eb8e613d5f992640"
_labels = "\n".join(entry["provider"] + "|" + entry["label"] for entry in ENTRIES)
assert hashlib.sha256(_labels.encode()).hexdigest() == LABELS_DIGEST, "corpus.json entries changed; recheck the tables"


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def objects(raw):
    """Every JSON value in `raw`, in order; trailing commas (the vLLM pages print them) removed."""
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    decoder, index, found = json.JSONDecoder(), 0, []
    while index < len(raw):
        while index < len(raw) and raw[index].isspace():
            index += 1
        if index >= len(raw):
            break
        value, index = decoder.raw_decode(raw, index)
        found.append(value)
    return found


def wire(raw):
    """SSE lines as printed; a `data:` event printed as pretty JSON is compacted onto one line."""
    if raw.startswith("data:") and "\n  " in raw:
        events = [event.strip() for event in raw.split("\n\n") if event.strip()]
        return ["data: " + compact(json.loads(event[len("data:"):])) for event in events]
    return raw.split("\n")


def content_text(lines):
    text, progress = "", 0
    for line in lines:
        if not line.startswith("data: {"):
            continue
        delta = json.loads(line[len("data: "):])["choices"][0]["delta"]
        piece = delta.get("content") or ""
        text += piece
        progress += 1 if piece else 0
    return text, progress


PRETTY = "Printed pretty and without `data: `; compacted onto one `data:` line."
# entry index: (how to put it on the wire, answer text, progress chunks, ending, note).
# Text, progress, and ending are what the page says the example carries; None means the answer is
# the example's documented content pieces joined.
STREAMS = {
    0: ("wire", "", 0, "open", "As printed."),
    1: ("wire", "Hello", 1, "open", "As printed."),
    2: ("wire", "", 0, "open", "The page's placeholder for omitted chunks, in SSE comment form; the API is not described as sending it."),
    3: ("wire", "", 0, "stop", "As printed."),
    4: ("wire", "", 0, "done", "As printed."),
    5: ("wire", "Hello", 1, "stopDone", "As printed, blank lines included."),
    6: ("objects", "", 0, "open", "Printed as a bare JSON object; `data: ` added and its whitespace compacted."),
    7: ("toolcalls", "", 8, "open", 'The page prints successive values of `delta.tool_calls`; each is wrapped as `{"choices":[{"delta":{"tool_calls":VALUE}}]}`.'),
    10: ("wire", "", 0, "open", "As printed."),
    13: ("wire", "", 0, "providerError", "As printed."),
    14: ("wire", "", 0, "providerError", "As printed."),
    15: ("wire", "", 0, "providerError", "As printed."),
    20: ("objects", "", 1, "open", PRETTY),
    21: ("objects", "", 0, "open", PRETTY),
    22: ("objects", "", 0, "open", "An abridged chunk p" + PRETTY[1:]),
    23: ("wire", "", 0, "providerError", "Each event printed as pretty JSON after one `data:`; each compacted onto one line."),
    24: ("objects", "Hello", 1, "open", "An OpenAPI example value, joined onto one line; `data: ` added."),
    25: ("toolcall", "", 1, "open", 'An OpenAPI example of one `delta.tool_calls` element; wrapped as `{"choices":[{"delta":{"tool_calls":[ELEMENT]}}]}`.'),
    26: ("objects", "", 0, "open", PRETTY),
    27: ("objects", "3", 1, "open", PRETTY),
    28: ("objects", "00", 1, "stop", PRETTY),
    29: ("objects", "384400", 4, "stop", "Five chunks printed pretty, back to back, without `data: `; each compacted onto its own `data:` line."),
    35: ("wire", "", 0, "open", "As printed."),
    36: ("wire", "Hello", 1, "open", "As printed."),
    37: ("wire", " 👋", 1, "open", "As printed."),
    38: ("wire", "", 0, "stop", "As printed."),
    39: ("wire", "", 0, "done", "As printed."),
    40: ("wire", None, None, "stopDone", "As printed, blank lines included."),
    41: ("wire", "", 0, "open", "Quoted in a sentence on the page."),
    42: ("objects", "", 1, "open", "Printed pretty, without `data: `, and with a trailing comma that makes it invalid JSON; the comma is removed and the chunk compacted onto one `data:` line."),
    43: ("objects", "", 1, "open", "Printed pretty, without `data: `, and with a trailing comma that makes it invalid JSON; the comma is removed and the chunk compacted onto one `data:` line."),
}
EXCLUDED = {
    11: "abridged by the page with a literal `...`, so not JSON",
    44: "OpenAI Python SDK printouts of the deltas, not wire JSON",
    46: "Ollama's native NDJSON API, not SSE",
}
ERROR_NOTES = {
    19: "Printed pretty; compacted onto one line. The page shows no status beside it; 200 follows from its description of a non-streamed reply that carries the error in its choice.",
    12: "Printed pretty; compacted onto one line. The page says an appropriate status is returned without naming it; 400 is the body's `error.code`, which OpenRouter sets to the status.",
}
# entry index: (status shown with the example, or None; the error it maps to, or None).
ERRORS = {
    8: (400, "httpStatus"), 9: (429, "rateLimited"), 12: (400, "httpStatus"), 16: (None, None),
    17: (403, "httpStatus"), 18: (403, "httpStatus"), 19: (200, "providerError"), 30: (None, None),
    31: (None, None), 32: (400, "httpStatus"), 33: (403, "httpStatus"), 34: (403, "httpStatus"), 45: (None, None),
}
assert set(STREAMS) | set(EXCLUDED) | set(ERRORS) == set(range(len(ENTRIES))), "every entry is used or excluded"


def swift(text):
    hashes = 1
    while ('"' + "#" * hashes) in text or ("#" * hashes + '"') in text:
        hashes += 1
    return "#" * hashes + '"' + text + '"' + "#" * hashes


def stream_lines(index, how):
    raw = ENTRIES[index]["raw"]
    if how == "wire":
        return wire(raw)
    if how == "objects":
        return ["data: " + compact(value) for value in objects(raw)]
    if how == "toolcalls":
        return ["data: " + compact({"choices": [{"delta": {"tool_calls": json.loads(line)}}]}) for line in raw.split("\n")]
    return ["data: " + compact({"choices": [{"delta": {"tool_calls": [json.loads(raw)]}}]})]


out = [
    "// Generated by script/provider-corpus/generate.py from script/provider-corpus/corpus.json, which holds",
    "// examples copied from provider documentation on %s. Do not edit by hand; edit the script and rerun it." % corpus["retrieved"],
    "// Each case keeps its source and a phrase from the page, so it can be found again, and a note on what,",
    "// if anything, was changed to put the documented example on the wire. Groq and LM Studio publish no",
    "// raw OpenAI-compatible stream chunk (SDK code and prose only), and no provider publishes a body",
    "// rejecting `temperature`, so neither appears here.",
    "",
    "enum ProviderCorpus {",
    '    static let retrieved = "%s"' % corpus["retrieved"],
    "",
    "    static let streams: [ProviderStreamCase] = [",
]
for index, (how, text, progress, end, note) in sorted(STREAMS.items()):
    entry, lines = ENTRIES[index], stream_lines(index, how)
    if text is None:
        text, progress = content_text(lines)
    out += [
        "        ProviderStreamCase(",
        "            provider: %s, label: %s," % (swift(entry["provider"]), swift(entry["label"])),
        "            source: %s," % swift(entry["source"]),
        "            nearby: %s," % swift(entry["quote_context"]),
        "            note: %s," % swift(note),
        "            lines: [",
        *["                %s," % swift(line) for line in lines],
        "            ],",
        "            text: %s, progress: %d, end: .%s" % (swift(text), progress, end),
        "        ),",
    ]
out += ["    ]", "", "    static let errors: [ProviderErrorCase] = ["]
for index, (status, expected) in sorted(ERRORS.items()):
    entry = ENTRIES[index]
    body = compact(objects(entry["raw"])[0])
    note = ERROR_NOTES.get(index, "As printed." if body == entry["raw"] else "Printed pretty; compacted onto one line.")
    out += [
        "        ProviderErrorCase(",
        "            provider: %s, label: %s," % (swift(entry["provider"]), swift(entry["label"])),
        "            source: %s," % swift(entry["source"]),
        "            nearby: %s," % swift(entry["quote_context"]),
        "            note: %s," % swift(note),
        "            status: %s, body: %s," % ("nil" if status is None else status, swift(body)),
        "            expected: %s" % ("nil" if expected is None else "." + expected),
        "        ),",
    ]
out += ["    ]", "", "    /// Documented examples left out, and why.",
        "    static let excluded: [(provider: String, label: String, source: String, reason: String)] = ["]
for index, reason in sorted(EXCLUDED.items()):
    entry = ENTRIES[index]
    out.append("        (%s, %s, %s, %s)," % (swift(entry["provider"]), swift(entry["label"]), swift(entry["source"]), swift(reason)))
out += ["    ]", "}"]
text = "\n".join(out) + "\n"
if "--check" in sys.argv:
    # CI: the checked-in Swift file must be what this script makes from corpus.json.
    if OUTPUT.read_text() != text:
        sys.exit("ProviderCorpus.swift is out of date; run python3 -I script/provider-corpus/generate.py")
    print("ProviderCorpus.swift matches corpus.json")
else:
    OUTPUT.write_text(text)
    print("%d streams, %d errors, %d excluded -> %s" % (len(STREAMS), len(ERRORS), len(EXCLUDED), OUTPUT))
