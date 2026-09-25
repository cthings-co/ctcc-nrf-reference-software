# Copyright (c) 2026 CTHINGS.CO
# SPDX-License-Identifier: Apache-2.0
#
# Fail a pull request that does not bump the Zephyr-style VERSION file.
#
# Reads the diff the workflow writes to version_compare.diff, reconstructs the old
# and new file from it, and compares the parsed versions - so it needs no second
# checkout of the base revision. The VERSION file is recognised by its contents,
# not by its path, so it works wherever the file lives (firmware/VERSION here).
#
# VERSION is the single source of truth for both the MCUboot image-header version
# (CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION) and the boot banner, so an unbumped
# VERSION means two different images ship claiming the same revision.

import re
import sys
from pathlib import Path

PATCH_NAME = "version_compare.diff"

INT_KEYS = ["VERSION_MAJOR", "VERSION_MINOR", "PATCHLEVEL", "VERSION_TWEAK"]
STR_KEY = "EXTRAVERSION"

# Zephyr puts EXTRAVERSION into APP_VERSION_EXTENDED_STRING (a C string literal) and
# into generated artifact names, so restrict it to characters that survive both.
EXTRA_RE = re.compile(r"^[A-Za-z0-9._-]*$")

def iter_file_sections(diff_text: str):
    parts = re.split(r"(?m)^diff --git ", diff_text)
    for p in parts[1:]:
        section = "diff --git " + p
        m = re.match(r"^diff --git a/(.+?) b/(.+?)\n", section)
        if not m:
            continue
        yield (m.group(1), m.group(2), section)

def reconstruct_old_new(section: str) -> tuple[str, str]:
    old_lines, new_lines = [], []

    for line in section.splitlines():
        if line.startswith(("diff --git ", "index ", "--- ", "+++ ")):
            continue

        if line.startswith("@@"):
            # Handle: @@ -2,4 +2,4 @@ VERSION_MAJOR = 1
            m = re.match(r"^@@.*@@(.*)$", line)
            trailing = m.group(1) if m else ""
            trailing = trailing.lstrip()  # becomes "VERSION_MAJOR = 1" or ""
            if trailing:
                old_lines.append(trailing)
                new_lines.append(trailing)
            continue

        if not line:
            continue

        tag = line[0]
        if tag not in (" ", "-", "+"):
            continue

        content = line[1:]
        if tag == " ":
            old_lines.append(content)
            new_lines.append(content)
        elif tag == "-":
            old_lines.append(content)
        elif tag == "+":
            new_lines.append(content)

    return ("\n".join(old_lines) + "\n", "\n".join(new_lines) + "\n")

# Absent keys default instead of raising. The diff is generated with full context
# (-U99 in the workflow, see .github/workflows/build-firmwares.yml), so a complete
# VERSION file normally arrives and every key is present - but a key must never be
# able to turn a legitimate bump into a crash or a false "not bumped": a narrower
# diff simply drops trailing keys (Zephyr treats an absent key as 0 / empty
# anyway), and the old side of an ADDED file has no keys at all.
def parse_version_text(text: str):
    def get_int(key: str) -> int:
        m = re.search(rf"^\s*{re.escape(key)}\s*=\s*([0-9]+)\s*$", text, re.MULTILINE)
        return int(m.group(1)) if m else 0

    def get_str(key: str) -> str:
        m = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", text, re.MULTILINE)
        return m.group(1).strip() if m else ""

    major = get_int("VERSION_MAJOR")
    minor = get_int("VERSION_MINOR")
    patch = get_int("PATCHLEVEL")
    tweak = get_int("VERSION_TWEAK")
    extra = get_str("EXTRAVERSION")
    return (major, minor, patch, tweak, extra)

# Recognise the file by any of its numeric keys, not by all five. Requiring all of
# them made the gate reject legitimate bumps: with git's default three lines of
# context, changing the first line (VERSION_MAJOR) drops EXTRAVERSION from the
# reconstructed text and changing the last (EXTRAVERSION) drops VERSION_MAJOR, so
# the file was not recognised at all and the run failed with "No Zephyr-style
# VERSION file change found in diff."
def is_version_file(text: str) -> bool:
    return any(re.search(rf"(?m)^\s*{re.escape(k)}\s*=", text) for k in INT_KEYS)

def fmt(v) -> str:
    major, minor, patch, tweak, extra = v
    base = f"{major}.{minor}.{patch}"
    if extra:
        base += f"-{extra}"
    return f"{base}+{tweak}"

# Only the four NUMBERS are compared, deliberately - EXTRAVERSION is ignored.
#
# What a shipped image carries is major.minor.patch+tweak: that is the format imgtool
# signs with (CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION) and what APP_VERSION_TWEAK_STRING
# renders. EXTRAVERSION reaches neither. So an EXTRAVERSION-only edit - 1.2.0-rc1 ->
# 1.2.0-rc2, say - leaves every image header byte-identical to the previous release's,
# which is the exact thing this gate exists to prevent. An earlier version of this
# function ordered the extras lexically and returned "bumped" for that, so a whole
# release could be cut on a version no image reports.
def cmp_versions(old, new) -> int:
    if old[:4] < new[:4]:
        return -1
    if old[:4] > new[:4]:
        return 1
    return 0

def main() -> int:
    diff_path = Path(PATCH_NAME)
    if not diff_path.exists():
        print(f"Diff file not found: {PATCH_NAME}", file=sys.stderr)
        return 2

    diff_text = diff_path.read_text(encoding="utf-8", errors="replace")

    candidates = []
    for a_path, b_path, section in iter_file_sections(diff_text):
        old_text, new_text = reconstruct_old_new(section)
        if is_version_file(old_text) or is_version_file(new_text):
            candidates.append((b_path, old_text, new_text))

    if not candidates:
        print("No Zephyr-style VERSION file change found in diff.", file=sys.stderr)
        return 1

    failed = False
    for path, old_text, new_text in candidates:
        old_v = parse_version_text(old_text)
        new_v = parse_version_text(new_text)

        # A pull request that ADDS the VERSION file has nothing on the old side;
        # that is a bump from nothing, not an error.
        if not is_version_file(old_text):
            print(f"{path}: OK new VERSION file {fmt(new_v)}")
            continue

        bad_extra = [v[4] for v in (old_v, new_v) if v[4] and not EXTRA_RE.match(v[4])]
        if bad_extra:
            print(f"{path}: EXTRAVERSION {bad_extra[0]!r} is not [A-Za-z0-9._-]*", file=sys.stderr)
            print("        it is emitted into a C string literal and into artifact file names,",
                  file=sys.stderr)
            print("        so anything else corrupts the build rather than the version.",
                  file=sys.stderr)
            failed = True

        if cmp_versions(old_v, new_v) >= 0:
            if old_v[:4] == new_v[:4] and old_v[4] != new_v[4]:
                print(f"{path}: only EXTRAVERSION changed ({fmt(old_v)} -> {fmt(new_v)}); "
                      "that is not a bump", file=sys.stderr)
                print("        imgtool signs with major.minor.patch+tweak and EXTRAVERSION is not"
                      " part of it,", file=sys.stderr)
                print("        so every image would ship with the same header version as before."
                      " Raise one", file=sys.stderr)
                print("        of VERSION_MAJOR / VERSION_MINOR / PATCHLEVEL / VERSION_TWEAK.",
                      file=sys.stderr)
            else:
                print(f"{path}: version not bumped! (was: {fmt(old_v)} < got: {fmt(new_v)})", file=sys.stderr)
            failed = True
        else:
            print(f"{path}: OK bumped {fmt(old_v)} -> {fmt(new_v)}")

    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
