#!/usr/bin/env python3
"""Sign payload bytes and bound release identities before distribution assembly.

Adapted from ObjcMarkdown's packaging/ci/sign-update-feed.py (Daniel Boyd).
UPDATE_ED_PRIVATE_KEY is a base64 Ed25519 seed (32 bytes, or seed+public 64).
UPDATE_ED_PUBLIC_KEY is the matching base64 public key (32 bytes). No key is
printed or fetched. --verify needs only the public key. --prepare-manifest
writes a private build input with updates.publicEDKey and requires any source
key to match. Nothing is published.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

PRIVATE_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
PUBLIC_PREFIX = bytes.fromhex("302a300506032b6570032100")


def decode(value, lengths, label):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError(f"{label} must be base64") from None
    if len(data) not in lengths:
        raise ValueError(f"{label} has an invalid key/signature length")
    return data


def public_key():
    return decode(os.environ.get("UPDATE_ED_PUBLIC_KEY", ""), (32,), "UPDATE_ED_PUBLIC_KEY")


def openssl(*args):
    result = subprocess.run(["openssl", *map(str, args)], capture_output=True)
    if result.returncode:
        raise ValueError(f"openssl {args[0]} failed")
    return result.stdout


def pem(path, label, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(b"-----BEGIN " + label + b"-----\n" + base64.encodebytes(data)
                     + b"-----END " + label + b"-----\n")


def version_message(package_id, version, channel, platform, sha256):
    """Packager v0.1.10's bound v1 statement; no trailing newline."""
    parts = ["gnustep-packager-update-v1", package_id, version, channel,
             platform, sha256.lower() if isinstance(sha256, str) else sha256]
    for part in parts:
        if not isinstance(part, str) or not part or any(
                char in part for char in "\n\r\v\f\x85\u2028\u2029"):
            raise ValueError("version signature fields must be nonempty single lines")
    return "\n".join(parts).encode("utf-8")


def assets(feed, directory):
    if feed.get("formatVersion") != 1:
        raise ValueError("unsupported feed format")
    result = []
    for release in feed.get("releases", []):
        for asset in release.get("assets", []):
            if asset.get("backend") == "appimage" and asset.get("platform") != "linux-x64":
                raise ValueError("AppImage update asset must name platform linux-x64")
            name = asset.get("name", "")
            if not name or Path(name).name != name or name in (".", ".."):
                raise ValueError("feed asset must have a plain file name")
            path = directory / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"missing regular payload: {name}")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if asset.get("sha256") != digest or asset.get("sizeBytes") != path.stat().st_size:
                raise ValueError(f"payload hash/size differs from feed: {name}")
            result.append((asset, path, release))
    if not result:
        raise ValueError("feed has no assets")
    return result


def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(prefix=".signed-feed-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def process(feed_path, directory, verify=False):
    expected = public_key()
    feed = json.loads(feed_path.read_text(encoding="utf-8-sig"))
    pairs = assets(feed, directory)
    with tempfile.TemporaryDirectory(prefix="pd-update-sign-") as tmp:
        work = Path(tmp)
        pub = work / "public.pem"
        pem(pub, b"PUBLIC KEY", PUBLIC_PREFIX + expected)
        if not verify:
            key = decode(os.environ.get("UPDATE_ED_PRIVATE_KEY", ""), (32, 64), "UPDATE_ED_PRIVATE_KEY")
            private = work / "private.pem"
            pem(private, b"PRIVATE KEY", PRIVATE_PREFIX + key[:32])
            actual_der = openssl("pkey", "-in", private, "-pubout", "-outform", "DER")
            if actual_der != PUBLIC_PREFIX + expected or (len(key) == 64 and key[32:] != expected):
                raise ValueError("private key does not match UPDATE_ED_PUBLIC_KEY")
        for asset, path, release in pairs:
            message = work / "version-message"
            message.write_bytes(version_message(feed.get("package", {}).get("id"),
                release.get("version"), feed.get("channel"),
                asset.get("platform"), asset.get("sha256")))
            if not verify:
                signature = openssl("pkeyutl", "-sign", "-inkey", private, "-rawin", "-in", path)
                if len(signature) != 64:
                    raise ValueError("invalid Ed25519 signature length")
                asset["edSignature"] = base64.b64encode(signature).decode("ascii")
                bound = openssl("pkeyutl", "-sign", "-inkey", private,
                                "-rawin", "-in", message)
                if len(bound) != 64:
                    raise ValueError("invalid version signature length")
                asset["versionSignature"] = base64.b64encode(bound).decode("ascii")
            signature = decode(asset.get("edSignature", ""), (64,), "edSignature")
            sig = work / "signature"
            sig.write_bytes(signature)
            openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub, "-rawin", "-in", path, "-sigfile", sig)
            sig.write_bytes(decode(asset.get("versionSignature", ""), (64,), "versionSignature"))
            openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub,
                    "-rawin", "-in", message, "-sigfile", sig)
    if not verify:
        # No partial feed is written when a later payload or signature fails.
        atomic_json(feed_path, feed)
    print(f"{'Verified' if verify else 'Signed and verified'} {len(pairs)} payload and bound version signature(s)")


def verify_asset(asset, path, package_id, version, channel):
    """Verify payload bytes and their bound release identity during assembly."""
    expected = public_key()
    signature = decode(asset.get("edSignature", ""), (64,), "edSignature")
    with tempfile.TemporaryDirectory(prefix="pd-update-verify-") as tmp:
        work = Path(tmp)
        pub = work / "public.pem"
        pem(pub, b"PUBLIC KEY", PUBLIC_PREFIX + expected)
        sig = work / "signature"
        sig.write_bytes(signature)
        openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub,
                "-rawin", "-in", path, "-sigfile", sig)
        message = work / "version-message"
        message.write_bytes(version_message(package_id, version, channel,
                                            asset.get("platform"), asset.get("sha256")))
        sig.write_bytes(decode(asset.get("versionSignature", ""), (64,), "versionSignature"))
        openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub,
                "-rawin", "-in", message, "-sigfile", sig)


def prepare_manifest(source, output):
    if source.resolve() == output.resolve() or output.exists():
        raise ValueError("generated manifest must be a new file")
    manifest = json.loads(source.read_text())
    encoded = base64.b64encode(public_key()).decode("ascii")
    configured = manifest["updates"].get("publicEDKey")
    if configured is not None and configured != encoded:
        raise ValueError("public key differs from the source manifest")
    manifest["updates"]["publicEDKey"] = encoded
    with output.open("x") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--prepare-manifest", action="store_true")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.prepare_manifest:
            if args.verify:
                parser.error("choose one operation")
            prepare_manifest(args.source, args.destination)
        else:
            process(args.source, args.destination, args.verify)
    except (OSError, ValueError) as error:
        parser.exit(1, f"update-signing: {error}\n")


if __name__ == "__main__":
    main()
