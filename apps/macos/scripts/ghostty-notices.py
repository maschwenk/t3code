#!/usr/bin/env python3
"""Collect notices from the pinned Ghostty source and its fetched Zig dependencies."""
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile

source, output = map(Path, sys.argv[1:])
cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", Path.home() / ".cache/zig")) / "p"
dependency = re.compile(r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"')
license_name = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|ofl|ftl)(?:[._-].*)?$", re.I)
pending = {}
for path in [source / "build.zig.zon", *sorted((source / "pkg").rglob("build.zig.zon"))]:
    pending.update({checksum: url for url, checksum in dependency.findall(path.read_text())})
sections = []
visited = set()
while pending:
    checksum = sorted(pending)[0]
    url = pending.pop(checksum)
    if checksum in visited:
        continue
    visited.add(checksum)
    archive = cache / (checksum + ".tar.gz")
    if not archive.exists():
        continue  # Lazy platform dependencies were not fetched by this build.
    notices = []
    with tarfile.open(archive) as package:
        for member in sorted(package.getmembers(), key=lambda item: item.name):
            if not member.isfile():
                continue
            path = PurePosixPath(member.name)
            if path.name == "build.zig.zon":
                text = package.extractfile(member).read().decode()
                pending.update({key: value for value, key in dependency.findall(text)})
            if license_name.fullmatch(path.name) and not path.name.endswith(".cfg"):
                text = package.extractfile(member).read().decode("utf-8", errors="replace")
                notices.append(f"--- {path.relative_to(path.parts[0])} ---\n{text}")
            elif checksum.startswith("z2d-") and str(path).endswith("/src/z2d.zig"):
                header = package.extractfile(member).read().decode().split("\n\n", 1)[0]
                notices.append(header)
                revision = re.search(r"z2d-([a-f0-9]{40})\.tar\.gz$", url).group(1)
                # z2d's Zig package omits these files; retrieve them from that exact source revision.
                for filename in ["LICENSE", "COPYING"]:
                    license_url = f"https://raw.githubusercontent.com/vancluever/z2d/{revision}/{filename}"
                    text = subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", license_url], check=True, capture_output=True).stdout.decode()
                    notices.append(f"--- {license_url} ---\n{text}")
            elif "/dcimgui.h" in member.name and "ANT61w" in checksum:
                header = package.extractfile(member).read().decode().split("// Library Version", 1)[0]
                notices.append(header)
    if not notices:
        raise SystemExit(f"No license notice found for {url}")
    sections.append(f"Source: {url}\nZig package hash: {checksum}\n\n" + "\n".join(notices))

sections.append((source / "vendor/nerd-fonts/LICENSE").read_text())
header = """GhosttyKit third-party notices

The bundled arm64 library is built from the revision in Vendor/GHOSTTY_VERSION.
Its source and the build scripts are available in https://github.com/Yash-Singh1/ghostty
and apps/macos/scripts/build-ghostty.sh. The source URLs below provide the exact
dependency versions, including the libintl and z2d sources. Build-time dependencies
and notices for optional portions of those source packages are included here too.
To modify or replace a library, edit that source dependency and rebuild GhosttyKit
with GHOSTTY_ALLOW_LOCAL_CHANGES=1, then rebuild T3 Native with apps/macos/build.sh.

"""
output.write_text(header + "\n\n========================================\n\n".join(sections))
