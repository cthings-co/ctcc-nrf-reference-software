#!/usr/bin/env bash
# Read back the SHA256SUMS files the build stage produced, before anything is
# packaged or published.
#
# Writing SHA256SUMS is only half of the job. Until this script existed nothing
# ever read them back, so an artifact set that arrived truncated from the build
# stage was packaged anyway and the archive checksum then certified the corrupt
# contents - the customer's `sha256sum -c` was the first check in the chain that
# actually ran. This runs it on the publishing side, where a failure is cheap.
#
# Three things are checked; any of them failing fails the job:
#   1. every SHA256SUMS verifies (sha256sum -c),
#   2. at least one set is present, and none is empty - an empty artifact root
#      means the build stage published nothing, which must not package silently,
#   3. every file under the root is covered by exactly one SHA256SUMS entry, so
#      an image copied in after its checksums were generated, or a directory
#      whose SHA256SUMS never got written, cannot ship unverifiable.
#
# Usage: verify_checksums.sh <artifact-root> [ignore-glob ...]
#
# Ignore globs are matched against the path relative to <artifact-root>, and are
# meant for files the packaging job itself writes there (its own *.zip and
# *.zip.sha256), which are covered by the archive checksum instead.

set -euo pipefail

root=${1:-}
if [ -z "${root}" ]; then
  echo "usage: $0 <artifact-root> [ignore-glob ...]" >&2
  exit 2
fi
if [ ! -d "${root}" ]; then
  echo "ERROR: not a directory: ${root}" >&2
  exit 1
fi
shift
ignores=("$@")

cd "${root}"
root_abs=$(pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# NUL-delimited throughout: artifact names come from board/SoC/app variables and
# should never contain spaces, but a checksum tool that mangles an unexpected
# name is worse than one that refuses it.
find . -type f -name SHA256SUMS -print0 | LC_ALL=C sort -z > "${work}/sets"
sets=$(tr -cd '\0' < "${work}/sets" | wc -c)

if [ "${sets}" -eq 0 ]; then
  echo "ERROR: no SHA256SUMS anywhere under ${root_abs}" >&2
  echo "       the build stage published nothing, or published it somewhere else" >&2
  exit 1
fi

rc=0
: > "${work}/covered"

while IFS= read -r -d '' sums; do
  dir=${sums%/SHA256SUMS}
  rel=${dir#./}
  [ "${rel}" = "." ] && rel=""
  printf 'verifying %s\n' "${rel:-<root>}"

  if [ ! -s "${sums}" ]; then
    echo "ERROR: ${sums} is empty - nothing was collected for this set" >&2
    rc=1
    continue
  fi
  # GNU sha256sum escapes a name containing a newline or backslash by prefixing
  # the line with '\'. Rather than decode that, refuse it: no artifact of ours
  # has such a name, so it means something upstream is wrong.
  if grep -q '^\\' "${sums}"; then
    echo "ERROR: ${sums} has an escaped filename (newline or backslash in a name)" >&2
    rc=1
    continue
  fi

  ( cd "${dir}" && sha256sum -c --quiet SHA256SUMS ) || rc=1

  # Record what this set claims to cover, as paths relative to the root, so the
  # coverage check below can compare them against what is actually on disk.
  sed -E 's/^[0-9a-f]{64} [ *]//' "${sums}" \
    | while IFS= read -r name; do printf '%s\n' "${rel:+${rel}/}${name}"; done \
    >> "${work}/covered"
done < "${work}/sets"

# Everything on disk except the SHA256SUMS files themselves (a checksum file
# cannot list itself) and whatever the caller asked to ignore.
find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort > "${work}/all"
: > "${work}/actual"
while IFS= read -r f; do
  skip=0
  for g in ${ignores+"${ignores[@]}"}; do
    # shellcheck disable=SC2254  # $g is a glob on purpose
    case "${f}" in ${g}) skip=1; break ;; esac
  done
  [ "${skip}" -eq 1 ] || printf '%s\n' "${f}" >> "${work}/actual"
done < "${work}/all"

LC_ALL=C sort -u "${work}/actual"  > "${work}/actual.s"
LC_ALL=C sort -u "${work}/covered" > "${work}/covered.s"

uncovered=$(comm -23 "${work}/actual.s" "${work}/covered.s")
if [ -n "${uncovered}" ]; then
  echo "ERROR: these files are published but listed in no SHA256SUMS:" >&2
  printf '%s\n' "${uncovered}" | sed 's/^/  /' >&2
  rc=1
fi

# sha256sum -c already reports a listed-but-absent file as FAILED open or read;
# naming them here says which set is short rather than only that one is.
absent=$(comm -13 "${work}/actual.s" "${work}/covered.s")
if [ -n "${absent}" ]; then
  echo "ERROR: these files are listed in a SHA256SUMS but are not present:" >&2
  printf '%s\n' "${absent}" | sed 's/^/  /' >&2
  rc=1
fi

files=$(wc -l < "${work}/covered.s")
if [ "${rc}" -eq 0 ]; then
  echo "checksums OK: ${files} file(s) in ${sets} artifact set(s) under ${root_abs}"
else
  echo "checksum verification FAILED under ${root_abs}" >&2
fi
exit "${rc}"
