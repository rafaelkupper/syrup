"""Offline checks for publisher-supplied release configuration."""
import base64
import contextlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import release


class PublisherConfigurationTests(unittest.TestCase):
    def arguments(self, root):
        return ["release.py", "--sparkle-tools", str(root / "tools"),
                "--feed-url", "https://updates.example.org/appcast.xml",
                "--release-repo", "example/releases", "--team-id", "TEAMID1234",
                "--public-key", base64.b64encode(bytes(range(32))).decode(),
                "--notary-profile", "example-notary", "--output", str(root / "output")]

    def test_preparation_passes_configuration_to_tools_and_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.arguments(root)
            commands = []

            def run(*command, **kwargs):
                command = [str(x) for x in command]
                commands.append(command)
                if "-exportArchive" in command:
                    exported = Path(command[command.index("-exportPath") + 1])
                    info = exported / "Syrup.app/Contents/Info.plist"
                    info.parent.mkdir(parents=True)
                    info.write_bytes(plistlib.dumps(dict(
                        CFBundleShortVersionString="1.0", CFBundleVersion="13",
                        SUFeedURL=args[4], SUPublicEDKey=args[10])))
                elif "submit" in command:
                    kwargs["stdout"].write('{"status":"Accepted","id":"fixture"}')
                    kwargs["stdout"].close()

            def zip_app(app, destination):
                destination.write_bytes(b"fixture archive")

            with patch("sys.argv", args), patch.object(release, "manifest", return_value=("1.0", 13)), \
                    patch.object(release.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(b"<rss/>"))), \
                    patch.object(release, "run", side_effect=run), patch.object(release, "zip_app", side_effect=zip_app), \
                    patch.object(release, "verify") as verify, patch.object(release, "verify_archive") as verify_archive, \
                    contextlib.redirect_stdout(io.StringIO()):
                release.main()
            output = (root / "output/1.0-13").resolve()
            receipt = json.loads((output / "review.json").read_text())
            self.assertEqual(receipt["distribution"], dict(
                feedURL=args[4], releaseRepo=args[6], teamID=args[8], publicKey=args[10]))
            self.assertEqual(plistlib.loads((output / "ExportOptions.plist").read_bytes())["teamID"], args[8])
            archive = next(command for command in commands if "archive" in command)
            self.assertIn("DEVELOPMENT_TEAM=" + args[8], archive)
            self.assertIn("SYRUP_UPDATE_FEED_URL=" + args[4], archive)
            self.assertIn("SYRUP_UPDATE_PUBLIC_KEY=" + args[10], archive)
            for command in commands:
                if "--keychain-profile" in command:
                    self.assertEqual(command[command.index("--keychain-profile") + 1], "example-notary")
            verify.assert_called_once_with(output / "exported/Syrup.app", "TEAMID1234")
            verify_archive.assert_called_once_with(output / "Syrup-1.0.zip", "TEAMID1234")

    def test_invalid_configuration_fails_before_network_or_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            valid = self.arguments(Path(directory))
            cases = [("--team-id", "short"), ("--public-key", "invalid"),
                     ("--feed-url", "http://updates.example.org/feed"), ("--release-repo", "missing-owner")]
            for flag, value in cases:
                args = valid.copy()
                args[args.index(flag) + 1] = value
                with self.subTest(flag=flag), patch("sys.argv", args), \
                        patch.object(release.urllib.request, "urlopen") as network, \
                        patch.object(release, "run") as run, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        release.main()
                    self.assertEqual(raised.exception.code, 2)
                    network.assert_not_called()
                    run.assert_not_called()

    def test_publish_rejects_a_different_publisher(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.arguments(root) + ["--publish", str(root / "review")]
            review = root / "review"
            review.mkdir()
            (review / "review.json").write_text(json.dumps(dict(version="1.0", build=13,
                zip="Syrup.zip", distribution={})))
            with patch("sys.argv", args), patch.object(release, "manifest", return_value=("1.0", 13)), \
                    patch.object(release.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(b"<rss/>"))), \
                    patch.object(release, "run") as run:
                with self.assertRaisesRegex(SystemExit, "publisher configuration"):
                    release.main()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
