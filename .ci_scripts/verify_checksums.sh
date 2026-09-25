#!/usr/bin/env bash
#
#
#
#
#
#

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

find . -type f -name SHA256SUMS -print0 | LC_ALL=C sort -z > "${work}/sets"
sets=$(tr -cd '\0' < "${work}/sets" | wc -c)

if [ "${sets}" -eq 0 ]; then
  echo "ERROR: no SHA256SUMS anywhere under ${root_abs}" >&2
  echo "       the build stage published nothing, or published it somewhere else" >&2
  exit 1
fi

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
  if grep -q '^\\' "${sums}"; then
    echo "ERROR: ${sums} has an escaped filename (newline or backslash in a name)" >&2
    rc=1
    continue
  fi

  ( cd "${dir}" && sha256sum -c --quiet SHA256SUMS ) || rc=1

  sed -E 's/^[0-9a-f]{64} [ *]//' "${sums}" \
    | while IFS= read -r name; do printf '%s\n' "${rel:+${rel}/}${name}"; done \
    >> "${work}/covered"
done < "${work}/sets"

find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort > "${work}/all"
drop_ignored() {
  local f g skip
  while IFS= read -r f; do
    skip=0
    for g in ${ignores+"${ignores[@]}"}; do
      case "${f}" in ${g}) skip=1; break ;; esac
    done
    [ "${skip}" -eq 1 ] || printf '%s\n' "${f}"
  done
}

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
