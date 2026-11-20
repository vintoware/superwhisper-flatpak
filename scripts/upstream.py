#!/usr/bin/env python3
"""Resolve and verify a Superwhisper release from its stable channel.

  upstream.py version [--channel-file F]
      Print the stable channel's version.

  upstream.py fetch --arch ARCH --key PUBKEY --cache DIR --out ENVFILE [--channel-file F]
      Download ARCH's release archive (reusing a verified copy in DIR), check its size
      and SHA-256 against the channel metadata and its minisign signature against the
      pinned upstream release key, then write shell assignments for the build:
      SW_VERSION SW_URL SW_SHA256 SW_SIZE SW_ARCHIVE SW_DATE SW_NOTES_URL.

The channel is https://tux.superwhisper.com/stable.json unless --channel-file names a
saved copy (CI resolves it once and hands the same file to every architecture's build).
Exits non-zero on any verification failure. Stdlib only; needs `minisign` for fetch.
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.request

CHANNEL_URL = "https://tux.superwhisper.com/stable.json"
ALLOWED_HOST = "https://tux.superwhisper.com/"
ARCHES = ("x86_64", "aarch64")
USER_AGENT = "superwhisper-flatpak-build"


def fetch(url, dest=None):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        if dest is None:
            return response.read()
        tmp = dest + ".part"
        with open(tmp, "wb") as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
        os.replace(tmp, dest)
    return None


def load_channel(channel_file):
    raw = open(channel_file, "rb").read() if channel_file else fetch(CHANNEL_URL)
    channel = json.loads(raw)
    if channel.get("schema") != 1:
        raise SystemExit(f"unsupported channel schema: {channel.get('schema')!r}")
    version = channel.get("version", "")
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        raise SystemExit(f"unexpected stable version format: {version!r}")
    return channel


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_version(args):
    print(load_channel(args.channel_file)["version"])


def cmd_fetch(args):
    channel = load_channel(args.channel_file)
    version = channel["version"]
    artifact = channel.get("artifacts", {}).get(args.arch)
    if not artifact:
        raise SystemExit(f"stable {version} has no {args.arch} archive")
    for field in ("url", "sha256", "size", "signature"):
        if field not in artifact:
            raise SystemExit(f"{args.arch}: channel metadata lacks {field!r}")
    for field in ("url", "signature"):
        if not artifact[field].startswith(ALLOWED_HOST):
            raise SystemExit(f"{args.arch}: {field} is not on {ALLOWED_HOST}: {artifact[field]}")
    if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):
        raise SystemExit(f"{args.arch}: malformed sha256")
    if not isinstance(artifact["size"], int) or artifact["size"] <= 0:
        raise SystemExit(f"{args.arch}: malformed size")
    # The URL becomes the extra-data source users download from for as long as this
    # build is published, so it must name this version (upstream keeps old releases).
    if f"/v{version}/" not in artifact["url"]:
        raise SystemExit(f"{args.arch}: url is not versioned: {artifact['url']}")

    os.makedirs(args.cache, exist_ok=True)
    archive = os.path.join(args.cache, os.path.basename(artifact["url"]))
    signature = archive + ".minisig"
    if os.path.exists(archive) and os.path.getsize(archive) == artifact["size"] \
            and sha256_of(archive) == artifact["sha256"]:
        print(f"{args.arch}: reusing {archive}", flush=True)
    else:
        print(f"{args.arch}: downloading {artifact['url']}", flush=True)
        fetch(artifact["url"], archive)
    fetch(artifact["signature"], signature)

    size = os.path.getsize(archive)
    if size != artifact["size"]:
        raise SystemExit(f"{args.arch}: size {size} != {artifact['size']}")
    if sha256_of(archive) != artifact["sha256"]:
        raise SystemExit(f"{args.arch}: sha256 mismatch")
    subprocess.run(["minisign", "-V", "-q", "-p", args.key, "-m", archive, "-x", signature], check=True)
    print(f"{args.arch}: {version} size, sha256 and minisign signature OK", flush=True)

    notes = channel.get("notesUrl", "")
    if not re.fullmatch(r"https://github\.com/[\w./-]+", notes):
        notes = "https://github.com/superultrainc/superwhisper-linux-releases/releases"
    date = channel.get("published", "")[:10]
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise SystemExit(f"unexpected published date: {channel.get('published')!r}")

    values = {
        "SW_VERSION": version,
        "SW_URL": artifact["url"],
        "SW_SHA256": artifact["sha256"],
        "SW_SIZE": str(artifact["size"]),
        "SW_ARCHIVE": os.path.abspath(archive),
        "SW_DATE": date,
        "SW_NOTES_URL": notes,
    }
    with open(args.out, "w") as f:
        for key, value in values.items():
            f.write(f"{key}={shlex.quote(value)}\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("version")
    p.add_argument("--channel-file")
    p.set_defaults(func=cmd_version)
    p = sub.add_parser("fetch")
    p.add_argument("--channel-file")
    p.add_argument("--arch", required=True, choices=ARCHES)
    p.add_argument("--key", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_fetch)
    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
