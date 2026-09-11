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
#      means the build stage published nothing, which must not package silently;
#      with EXPECTED_SETS in the environment this is tightened from "at least
#      one" to "exactly that many" (see below),
#   3. every file under the root is covered by a SHA256SUMS entry, so an image
#      copied in after its checksums were generated, or a directory whose
#      SHA256SUMS never got written, cannot ship unverifiable. Coverage is
#      compared as a SET (sort -u both sides), so this proves at-least-one entry
#      per file, not exactly-one.
#
# Usage: verify_checksums.sh <artifact-root> [ignore-glob ...]
#
# EXPECTED_SETS (optional, from the environment): how many SHA256SUMS files the
# caller knows must be there. Without it the strongest statement this script can
# make is "the tree is not empty", so a tree that arrives with eight of the nine
# sets the build matrix produces verifies perfectly clean, and the release archive
# is packaged one firmware short with a valid .zip.sha256 over it. Every checksum
# in the chain certifies what arrived; only this certifies that all of it did.
#
# Ignore globs are matched against the whole path relative to <artifact-root>, and
# are meant for files the packaging job itself writes there (its own *.zip and
# *.zip.sha256), which are covered by the archive checksum instead.
#
# A glob matches at ANY DEPTH: `case` patterns are not path-aware, so a `*.zip`
# meant for the packaging job's archive at the root would also match a zip
# published INSIDE an artifact set (an mcumgr/DFU update package, say) and quietly
# excuse it from the coverage check. Name a root file precisely if that is what
# you mean. CI passes no globs at all - the packaging job deletes its own archive
# before calling this and writes it afterwards - so that path is defensive rather
# than exercised.

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

# NUL-delimited here: artifact names come from board/SoC/app variables and should
# never contain spaces, but a checksum tool that mangles an unexpected name is
# worse than one that refuses it. The coverage listing further down is
# newline-delimited instead, which is safe in the other direction: a name
# containing a newline splits into two lines that match nothing, so it is
# REPORTED as uncovered rather than passing silently.
find . -type f -name SHA256SUMS -print0 | LC_ALL=C sort -z > "${work}/sets"
sets=$(tr -cd '\0' < "${work}/sets" | wc -c)

if [ "${sets}" -eq 0 ]; then
  echo "ERROR: no SHA256SUMS anywhere under ${root_abs}" >&2
  echo "       the build stage published nothing, or published it somewhere else" >&2
  exit 1
fi

# "At least one set" is the weakest possible form of the rule that an empty set
# must not ship a vacuous checksum file. A caller that knows how many sets it is
# expecting gets the strong form, because the interesting failure is not an empty
# tree - a tree one set SHORT is verified, packaged, checksummed and released as
# though it were complete: a matrix row that succeeded while uploading nothing, an
# upload that expired before the packaging job ran, an artifact that did not come
# back down. Nothing else in the chain looks at how many sets there are.
if [ -n "${EXPECTED_SETS:-}" ]; then
  case "${EXPECTED_SETS}" in
    ''|*[!0-9]*)
      echo "ERROR: EXPECTED_SETS must be a whole number, got '${EXPECTED_SETS}'" >&2
      exit 2
      ;;
  esac
  if [ "${sets}" -ne "${EXPECTED_SETS}" ]; then
    echo "ERROR: expected ${EXPECTED_SETS} artifact set(s) under ${root_abs}, found ${sets}" >&2
    echo "       the sets that did arrive:" >&2
    tr '\0' '\n' < "${work}/sets" | sed -e 's|^\./||' -e 's|^|         |' >&2
    exit 1
  fi
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
# Drop the caller's ignore globs from a list of root-relative paths.
drop_ignored() {
  local f g skip
  while IFS= read -r f; do
    skip=0
    for g in ${ignores+"${ignores[@]}"}; do
      # shellcheck disable=SC2254  # $g is a glob on purpose
      case "${f}" in ${g}) skip=1; break ;; esac
    done
    [ "${skip}" -eq 1 ] || printf '%s\n' "${f}"
  done
}

# BOTH sides are filtered. An ignored path that a SHA256SUMS happens to name has
# to drop out of the covered list as well, or it survives there, is missing from
# the on-disk list, and gets reported as listed-but-absent.
drop_ignored < "${work}/all"     > "${work}/actual"
drop_ignored < "${work}/covered" > "${work}/covered.f"

LC_ALL=C sort -u "${work}/actual"    > "${work}/actual.s"
LC_ALL=C sort -u "${work}/covered.f" > "${work}/covered.s"

uncovered=$(LC_ALL=C comm -23 "${work}/actual.s" "${work}/covered.s")
if [ -n "${uncovered}" ]; then
  echo "ERROR: these files are published but listed in no SHA256SUMS:" >&2
  printf '%s\n' "${uncovered}" | sed 's/^/  /' >&2
  rc=1
fi

# sha256sum -c already reports a listed-but-absent file as FAILED open or read;
# naming them here says which set is short rather than only that one is.
absent=$(LC_ALL=C comm -13 "${work}/actual.s" "${work}/covered.s")
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
