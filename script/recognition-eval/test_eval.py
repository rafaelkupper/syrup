import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import eval as evaluation


class MetricsTests(unittest.TestCase):
    def test_word_errors_and_normalization(self):
        result = evaluation.score("Olá, MUNDO!", "olá novo mundo", [], [])
        self.assertEqual(result["wordErrors"], 1)
        self.assertEqual(result["wer"], 0.5)
        self.assertEqual(evaluation.score("a b c", "a d", [], [])["wordErrors"], 2)
        self.assertEqual(evaluation.score("It's a test.", "ITS A TEST", [], [])["wer"], 0)
        self.assertEqual(evaluation.score("a b", "", [], [])["wer"], 1)

    def test_terms_require_whole_tokens_and_guard_excess(self):
        result = evaluation.score("An ordinary day", "Docker dockerized new york", ["Docker", "New York", "Yorkshire"], ["Docker", "New York"])
        self.assertEqual(result["termsRecalled"], 2)
        self.assertEqual(result["termRecall"], 2 / 3)
        self.assertEqual(result["excessVocabularyOccurrences"], 2)
        self.assertEqual(evaluation.score("Docker", "Docker Docker", [], ["Docker"])["excessVocabularyOccurrences"], 1)

    def test_last_word_must_be_at_the_end(self):
        self.assertTrue(evaluation.score("blue door", "the blue door!", [], [])["lastWordRetained"])
        self.assertFalse(evaluation.score("blue door", "door blue", [], [])["lastWordRetained"])

    def test_summary_counts_failures_without_printing_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            row = dict(engine="apple", locale="en-US", status="failed", options=dict(vocabulary=True, trimEndMs=0, realtime=False))
            path.write_text(json.dumps(row) + "\n" + json.dumps(dict(row, status="timedOut")) + "\n")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                evaluation.summary(path)
            result = json.loads(output.getvalue())[0]
            self.assertEqual(result["failed"], 1)
            self.assertEqual(result["passed"], 0)
            self.assertEqual(result["timedOut"], 1)

    def test_summary_splits_target_and_guard_word_error_rates(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            base = dict(engine="parakeet-v3", locale="pt-BR", status="passed", options=dict(vocabulary=False, trimEndMs=0, realtime=False),
                        expectedTermCount=1, termsRecalled=1, excessVocabularyOccurrences=0, lastWordRetained=True,
                        finalizationMs=40, setupMs=1, feedMs=3, audioMs=3)
            rows = [dict(base, group="target", wordErrors=1, referenceWords=4), dict(base, group="guard", wordErrors=0, referenceWords=6, expectedTermCount=0, termsRecalled=0)]
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                evaluation.summary(path)
            result = json.loads(output.getvalue())[0]
            self.assertEqual(result["targetWer"], 0.25)
            self.assertEqual(result["guardWer"], 0)
            self.assertEqual(result["wer"], 0.1)

    def test_engine_list_is_validated_before_any_build(self):
        arguments = dict(vocabulary="off", clips=None, output=None, trim_sweep=False, trim_end_ms=0, realtime=False, repeats=1, show_text=False, timeout_seconds=1)
        with patch.object(evaluation, "build") as build:
            for engine in ["apple,nope", "parakeet-v3,parakeet-v3", "whisper"]:
                with self.assertRaises(evaluation.EvalError):
                    evaluation.run(argparse.Namespace(**dict(arguments, engine=engine, aliases=None, boost_rescue="default")))
            build.assert_not_called()

    def test_aliases_must_name_manifest_terms_and_list_forms(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "aliases.json"
            arguments = dict(engine="parakeet-v3", vocabulary="on", clips=None, output=None, trim_sweep=False, trim_end_ms=0,
                             realtime=False, repeats=1, show_text=False, timeout_seconds=1, aliases=str(path), boost_rescue="default")
            with patch.object(evaluation, "build") as build:
                for aliases in [{"Kubernetes": []}, {"Kubernetes": "cubernetes"}, {"NotATerm": ["x"]}]:
                    path.write_text(json.dumps(aliases))
                    with self.assertRaises(evaluation.EvalError):
                        evaluation.run(argparse.Namespace(**arguments))
                build.assert_not_called()

    def test_parakeet_worker_receives_its_version_and_model_cache(self):
        with patch.object(evaluation.subprocess, "run"):
            command = evaluation.build("parakeet-ultra")
        self.assertEqual(command[1:], ["ultra", str(evaluation.CACHE / "models")])

    def test_private_manifest_in_git_is_rejected(self):
        with patch.dict(os.environ, {"SYRUP_EVAL_PRIVATE_MANIFEST": str(evaluation.TOOL / "clips.json")}):
            with self.assertRaises(evaluation.EvalError):
                evaluation.load_clips()

    def test_private_output_requires_external_path_without_leaking_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "clips.json"
            manifest.write_text(json.dumps([dict(id="private", wav="clip.wav", locale="en-US", reference="INVENTED_PRIVATE_SENTINEL", expectedTerms=[], group="guard")]))
            env = dict(os.environ, SYRUP_EVAL_PRIVATE_MANIFEST=str(manifest))
            result = subprocess.run([str(evaluation.ROOT / "script/recognition-eval.sh"), "run"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("INVENTED_PRIVATE_SENTINEL", result.stdout + result.stderr)
            self.assertIn("Private results require", result.stderr)


class PartialReadinessTests(unittest.TestCase):
    def test_counts_matches_at_thresholds_and_keeps_missing_results(self):
        rows = [dict(partialMatchAfterSpeechMs=x) for x in (-20, 300, 600, 1000, 1001, None)] + [{}]
        result = evaluation.partial_readiness(rows)
        self.assertEqual(result["partialMatchedBeforeRelease"], 5)
        self.assertEqual(result["partialWithinSilenceMs"], {"300": 2, "600": 3, "1000": 4})

    def test_no_matches_has_no_distribution(self):
        result = evaluation.partial_readiness([{}])
        self.assertIsNone(result["partialMatchAfterSpeechMs"])
        self.assertEqual(result["partialWithinSilenceMs"], {"300": 0, "600": 0, "1000": 0})


class PauseComparisonTests(unittest.TestCase):
    @staticmethod
    def row(prefix=None, text="café", status="passed", repetition=0, fast=False):
        return dict(clipId="clip", locale="pt-BR", repetition=repetition, status=status,
                    hypothesis=text, audioMs=2300, wallMs=123,
                    options=dict(prefixAfterSpeechMs=prefix, realtime=prefix is None,
                                 vocabulary=False, preferFastResults=fast))

    def test_compares_trimmed_bytes_without_unicode_normalization(self):
        rows = [self.row(), self.row(300, " café\n"), self.row(600, "cafe\u0301")]
        result = evaluation.compare_pauses(rows)
        self.assertEqual([r["matched"] for r in result], [1, 0])
        self.assertEqual(result[0]["offlineWallMs"]["median"], 123)
        self.assertEqual(result[0]["latencyByClip"][0]["audioMs"]["median"], 2300)

    def test_failed_and_empty_pairs_stay_in_denominator(self):
        rows = [self.row(), self.row(300),
                self.row(repetition=1), self.row(300, status="failed", repetition=1),
                self.row(repetition=2), self.row(300, text=" ", repetition=2)]
        result = evaluation.compare_pauses(rows)[0]
        self.assertEqual((result["pairs"], result["valid"], result["invalid"]), (3, 1, 2))
        self.assertEqual(result["equalityRate"], 1 / 3)

    def test_requires_unique_reference_and_prefix(self):
        for rows in ([self.row(300)], [self.row(), self.row(), self.row(300)],
                     [self.row(), self.row(300), self.row(300)]):
            with self.assertRaises(evaluation.EvalError):
                evaluation.compare_pauses(rows)

    def test_pairs_modes_and_repetitions_separately(self):
        rows = [self.row(text="one"), self.row(300, text="one"),
                self.row(text="two", fast=True), self.row(300, text="two", fast=True)]
        result = evaluation.compare_pauses(rows)
        self.assertEqual(len(result), 2)
        self.assertTrue(all(r["matched"] == 1 for r in result))

    def test_run_forwards_offsets_and_keeps_output_private(self):
        worker = """import json, sys
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps(dict(hypothesis='fixture', setupMs=1, finalizationMs=2, feedMs=3,
        audioMs=4, sourceAudioMs=5, trailingSilenceMs=600, finalSegments=1,
        speechEndMs=2, prefixReceived=request['prefixAfterSpeechMs'],
        silenceReceived=request['endSilenceMs'], wholeReceived=request['wholeBuffer'])), flush=True)
"""
        clip = dict(id="clip", wav="audio/clip.wav", locale="en-US", reference="fixture",
                    expectedTerms=[], group="guard")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            arguments = argparse.Namespace(engine="apple", vocabulary="off", clips=None,
                output=str(path), trim_sweep=False, trim_end_ms=0, realtime=False,
                repeats=1, show_text=False, timeout_seconds=5, aliases=None, boost_rescue="default",
                prefix_after_speech_ms=600, end_silence_ms=1500, prefer_fast_results=True, whole_buffer=True)
            with patch.object(evaluation, "build", return_value=[evaluation.sys.executable, "-u", "-c", worker]), \
                 patch.object(evaluation, "load_clips", return_value=([clip], Path(directory)/"clips.json", False)), \
                 contextlib.redirect_stdout(io.StringIO()):
                evaluation.run(arguments)
            row = json.loads(path.read_text())
            self.assertEqual((row["prefixReceived"], row["silenceReceived"]), (600, 1500))
            self.assertEqual(row["options"]["prefixAfterSpeechMs"], 600)
            self.assertTrue(row["options"]["preferFastResults"])
            self.assertTrue(row["wholeReceived"])
            self.assertIsNone(row["options"]["bufferMs"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_rejects_unsupported_prefix_requests_before_build(self):
        arguments = dict(engine="apple", trim_sweep=False, trim_end_ms=0, realtime=False,
                         prefix_after_speech_ms=300, end_silence_ms=None)
        with patch.object(evaluation, "build") as build:
            for changes in [dict(engine="parakeet-v3"), dict(realtime=True),
                            dict(trim_sweep=True), dict(prefix_after_speech_ms=-1),
                            dict(end_silence_ms=-1)]:
                with self.assertRaises(evaluation.EvalError):
                    evaluation.run(argparse.Namespace(**(arguments | changes)))
            build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
