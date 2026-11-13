#!/usr/bin/env python3
import argparse
import hashlib
import json
import base64
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def manifest():
    text = (ROOT / "project.yml").read_text()
    version = re.search(r'MARKETING_VERSION: "([\d.]+)"', text)[1]
    build = int(re.search(r'CURRENT_PROJECT_VERSION: (\d+)', text)[1])
    return version, build


def feed_build(data):
    root = ET.fromstring(data)
    values = [int(node.text) for node in root.iter(NS + "version")]
    values += [int(node.attrib[NS + "version"]) for node in root.iter("enclosure") if NS + "version" in node.attrib]
    return max(values, default=0)


def zip_app(app, archive):
    # By default ditto stores extended attributes as ._ entries. Only ditto and Archive Utility merge those back.
    # Any other unzip writes them into the signed bundle as real files, and Gatekeeper rejects its broken seal.
    run("ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", app, archive)


def verify_archive(archive, team_id):
    with zipfile.ZipFile(archive) as contents:
        stray = [name for name in contents.namelist() if name.startswith("__MACOSX/") or Path(name).name.startswith("._")]
    if stray:
        raise SystemExit(f"Archive holds {len(stray)} AppleDouble entries, such as {stray[0]}")
    for extract in (["ditto", "-x", "-k", archive], ["unzip", "-q", archive, "-d"]):
        with tempfile.TemporaryDirectory(prefix="syrup-extract-") as tmp:
            run(*extract, tmp)
            verify(Path(tmp) / "Syrup.app", team_id)


def verify(app, team_id):
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    for nested in app.rglob("*"):
        if nested.suffix in (".xpc", ".app", ".framework") or (nested.is_file() and nested.name == "Autoupdate"):
            run("codesign", "--verify", "--strict", "--verbose=2", nested)
            entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(nested)], stderr=subprocess.DEVNULL)
            helper_entitlements = plistlib.loads(entitlements) if entitlements else {}
            if any(helper_entitlements.get(key) for key in ("com.apple.security.device.audio-input", "com.apple.security.network.client", "com.apple.security.get-task-allow")):
                raise SystemExit(f"Unexpected app or debug entitlement on helper: {nested}")
            details = subprocess.check_output(["codesign", "-dv", "--verbose=4", str(nested)], stderr=subprocess.STDOUT).decode()
            if f"TeamIdentifier={team_id}" not in details.splitlines() or "Timestamp=" not in details or "runtime" not in details:
                raise SystemExit(f"Missing Developer ID, timestamp, or hardened runtime: {nested}")
    details = subprocess.check_output(["codesign", "-dv", "--verbose=4", str(app)], stderr=subprocess.STDOUT).decode()
    if "runtime" not in details or "Timestamp=" not in details or f"TeamIdentifier={team_id}" not in details.splitlines():
        raise SystemExit("Missing hardened runtime, timestamp, or team")
    entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
    if plistlib.loads(entitlements).get("com.apple.security.get-task-allow", False):
        raise SystemExit("Release has get-task-allow")
    for binary in (app / "Contents/MacOS/Syrup", app / "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"):
        arches = subprocess.check_output(["lipo", "-archs", str(binary)]).decode().split()
        if set(arches) != {"arm64", "x86_64"}:
            raise SystemExit(f"Not universal: {binary}")
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=4", app)


def main():
    parser = argparse.ArgumentParser(description="Prepare a notarized Sparkle release for review, or publish a previously reviewed directory.")
    parser.add_argument("--publish", type=Path, metavar="REVIEW_DIRECTORY")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/updates")
    parser.add_argument("--sparkle-tools", type=Path, required=True, help="Sparkle 2.10.1 bin directory")
    parser.add_argument("--feed-url", required=True, help="Publisher's HTTPS appcast URL")
    parser.add_argument("--release-repo", required=True, help="Publisher's GitHub owner/repository")
    parser.add_argument("--team-id", required=True, help="Apple Developer team ID")
    parser.add_argument("--public-key", required=True, help="Base64 Sparkle Ed25519 public key")
    parser.add_argument("--notary-profile", help="Local notarytool profile (required for preparation)")
    args = parser.parse_args()
    if not args.publish and not args.notary_profile:
        parser.error("--notary-profile is required for preparation")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("--team-id must contain 10 uppercase letters or digits")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.release_repo):
        parser.error("--release-repo must be owner/repository")
    if not args.feed_url.startswith("https://"):
        parser.error("--feed-url must use HTTPS")
    try:
        if len(base64.b64decode(args.public_key, validate=True)) != 32:
            raise ValueError
    except ValueError:
        parser.error("--public-key must be a base64-encoded 32-byte Ed25519 public key")
    distribution = dict(feedURL=args.feed_url, releaseRepo=args.release_repo,
                        teamID=args.team_id, publicKey=args.public_key)
    version, build = manifest()
    with urllib.request.urlopen(args.feed_url, timeout=30) as response:
        current_feed = response.read()
    if build <= feed_build(current_feed):
        raise SystemExit("Manifest build must be greater than every published feed build")
    tools = args.sparkle_tools.resolve()
    if args.publish:
        review = args.publish.resolve()
        receipt = json.loads((review / "review.json").read_text())
        archive = review / receipt["zip"]
        if receipt["version"] != version or receipt["build"] != build:
            raise SystemExit("Review receipt does not match manifest")
        if receipt["distribution"] != distribution:
            raise SystemExit("Review receipt does not match publisher configuration")
        for name, expected in receipt["sha256"].items():
            if hashlib.sha256((review / name).read_bytes()).hexdigest() != expected:
                raise SystemExit(f"Review artifact changed: {name}")
        verify_archive(archive, args.team_id)
        run("swift", ROOT / "script/verify-update.swift", archive, review / "appcast.xml", receipt["publicKey"])
        with tempfile.TemporaryDirectory(prefix="syrup-publish-") as tmp:
            checkout = Path(tmp) / "releases"
            run("gh", "repo", "clone", args.release_repo, checkout)
            if (checkout / "appcast.xml").read_bytes() != current_feed:
                raise SystemExit("Release repo and live feed disagree")
            run("gh", "release", "create", f"v{version}", archive, "--repo", args.release_repo, "--title", f"Syrup {version}", "--notes", f"Syrup {version}")
            shutil.copy2(review / "appcast.xml", checkout / "appcast.xml")
            run("git", "-C", checkout, "add", "appcast.xml")
            run("git", "-C", checkout, "commit", "-m", f"Syrup {version}")
            run("git", "-C", checkout, "push")
        return
    output = args.output.resolve() / f"{version}-{build}"
    output.mkdir(parents=True, exist_ok=False)
    (output / "appcast.xml").write_bytes(current_feed)
    run("xcodegen", cwd=ROOT)
    archive = output / "Syrup.xcarchive"
    run("xcodebuild", "-scheme", "Syrup", "-configuration", "Release", "-destination", "generic/platform=macOS", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "-archivePath", archive, "archive", "OTHER_CODE_SIGN_FLAGS=--timestamp", "CODE_SIGN_IDENTITY=Developer ID Application", f"DEVELOPMENT_TEAM={args.team_id}", f"SYRUP_UPDATE_FEED_URL={args.feed_url}", f"SYRUP_UPDATE_PUBLIC_KEY={args.public_key}", cwd=ROOT)
    options = output / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps(dict(method="developer-id", signingStyle="manual", signingCertificate="Developer ID Application", teamID=args.team_id)))
    exported = output / "exported"
    run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", exported, "-exportOptionsPlist", options)
    app = exported / "Syrup.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != str(build):
        raise SystemExit("Archive version differs from manifest")
    if info["SUFeedURL"] != args.feed_url or info["SUPublicEDKey"] != args.public_key:
        raise SystemExit("Archive update configuration differs from publisher configuration")
    submission = output / "submission.zip"
    zip_app(app, submission)
    run("xcrun", "notarytool", "submit", submission, "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json", stdout=(output / "notarization.json").open("w"))
    notarization = json.loads((output / "notarization.json").read_text())
    if notarization["status"] != "Accepted":
        raise SystemExit("Notarization was not accepted")
    run("xcrun", "notarytool", "log", notarization["id"], "--keychain-profile", args.notary_profile, output / "notarization-log.json")
    run("xcrun", "stapler", "staple", app)
    verify(app, args.team_id)
    final = output / f"Syrup-{version}.zip"
    zip_app(app, final)
    verify_archive(final, args.team_id)
    submission.unlink()
    run(tools / "generate_appcast", "--maximum-deltas", "0", "--download-url-prefix", f"https://github.com/{args.release_repo}/releases/download/v{version}/", output)
    run("swift", ROOT / "script/verify-update.swift", final, output / "appcast.xml", info["SUPublicEDKey"])
    receipt = dict(version=version, build=build, zip=final.name, publicKey=info["SUPublicEDKey"], distribution=distribution, sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (final, output / "appcast.xml")})
    (output / "review.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Prepared for review at {output}. Nothing published.")


if __name__ == "__main__":
    main()
