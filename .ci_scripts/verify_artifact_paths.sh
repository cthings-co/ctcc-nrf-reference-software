#!/usr/bin/env bash
#
#

set -euo pipefail

usage() {
	printf 'usage: %s <artifact-directory> <forbidden-path> [<forbidden-path> ...]\n' \
		"${0##*/}" >&2
	exit 2
}

die() {
	printf '::error::%s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 2 ] || usage

artifact_dir="$1"
shift
[ -d "$artifact_dir" ] || die "artifact directory does not exist: $artifact_dir"

forbidden_paths=()
for path in "$@"; do
	[ -n "$path" ] || continue
	path="${path%/}"
	[ "$path" != / ] || die 'refusing to scan for the root directory'
	forbidden_paths+=("$path")
done
[ "${#forbidden_paths[@]}" -gt 0 ] || usage

relative_name() {
	printf '%s' "${1#"$artifact_dir"/}"
}

report_leak() {
	printf '::error::artifact %s contains private build path %s\n' \
		"$(relative_name "$1")" "$2" >&2
}

check_path_in_file() {
	local file="$1"
	python3 - "$file" "${forbidden_paths[@]}" <<'PY'
import sys

filename = sys.argv[1]
needles = tuple(path.encode('utf-8').lower() for path in sys.argv[2:])
# SPDX represents a root-relative file as "./home/...". A period is a path
# separator here, not part of a component, so it must not hide a forbidden root.
component_bytes = b'abcdefghijklmnopqrstuvwxyz0123456789_-'
keep = max((len(needle) for needle in needles), default=1) + 1


def find_path(data, final=False):
    for needle in needles:
        start = 0
        while True:
            start = data.find(needle, start)
            if start < 0:
                break
            end = start + len(needle)
            if end == len(data) and not final:
                start += 1
                continue
            before_ok = start == 0 or data[start - 1] not in component_bytes
            after_ok = end == len(data) or data[end] not in component_bytes
            if before_ok and after_ok:
                return needle
            start += 1
    return None


def scan(chunks):
    previous = b''
    for chunk in chunks:
        data = previous + chunk.lower()
        found = find_path(data)
        if found:
            return found
        previous = data[-keep:]
    return find_path(previous, final=True)


try:
    with open(filename, 'rb') as artifact:
        found = scan(iter(lambda: artifact.read(65536), b''))
except OSError as error:
    print(f'error: {error}')
    raise SystemExit(2)

if found:
    print(found.decode('utf-8', 'replace'))
    raise SystemExit(1)
PY
}

check_zip() {
	local file="$1" result
	if result="$(python3 - "$file" "${forbidden_paths[@]}" <<'PY'
import sys
import zipfile

archive = sys.argv[1]
needles = tuple(path.encode('utf-8').lower() for path in sys.argv[2:])
# SPDX represents a root-relative file as "./home/...". A period is a path
# separator here, not part of a component, so it must not hide a forbidden root.
component_bytes = b'abcdefghijklmnopqrstuvwxyz0123456789_-'
keep = max((len(needle) for needle in needles), default=1) + 1


def find_path(data, final=False):
    for needle in needles:
        start = 0
        while True:
            start = data.find(needle, start)
            if start < 0:
                break
            end = start + len(needle)
            if end == len(data) and not final:
                start += 1
                continue
            before_ok = start == 0 or data[start - 1] not in component_bytes
            after_ok = end == len(data) or data[end] not in component_bytes
            if before_ok and after_ok:
                return needle
            start += 1
    return None


def scan(chunks):
    previous = b''
    for chunk in chunks:
        data = previous + chunk.lower()
        found = find_path(data)
        if found:
            return found
        previous = data[-keep:]
    return find_path(previous, final=True)

try:
    with zipfile.ZipFile(archive) as package:
        for item in package.infolist():
            name = item.filename.encode('utf-8', 'surrogateescape').lower()
            found = find_path(name, final=True)
            if found:
                print(found.decode('utf-8', 'replace'))
                raise SystemExit(1)
            if item.is_dir():
                continue
            with package.open(item) as member:
                found = scan(iter(lambda: member.read(65536), b''))
                if found:
                    print(found.decode('utf-8', 'replace'))
                    raise SystemExit(1)
except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
    print(f'error: {error}')
    raise SystemExit(2)
PY
)"; then
		return 0
	fi
	case "$result" in
	error:*) die "cannot inspect zip artifact $(relative_name "$file"): ${result#error: }" ;;
	*)       report_leak "$file" "$result"; return 1 ;;
	esac
}

check_file() {
	local file="$1" result status
	if result="$(check_path_in_file "$file")"; then
		:
	else
		status=$?
		case "$status:$result" in
			1:*) report_leak "$file" "$result"; return 1 ;;
			2:error:*) die "cannot inspect artifact $(relative_name "$file"): ${result#error: }" ;;
			*) die "cannot inspect artifact $(relative_name "$file")" ;;
		esac
	fi
	case "$file" in
	*.zip) check_zip "$file" ;;
	esac
}

file_list="$(mktemp "${TMPDIR:-/tmp}/verify-artifact-paths.XXXXXX")" || die 'cannot create artifact file list'
trap 'rm -f "$file_list"' EXIT
if ! find "$artifact_dir" -type f -print0 > "$file_list"; then
	die "cannot enumerate artifact directory: $artifact_dir"
fi

file_count=0
while IFS= read -r -d '' file; do
	file_count=$((file_count + 1))
	if ! check_file "$file"; then
		die 'published artifact path sanitization failed'
	fi
done < "$file_list"

[ "$file_count" -gt 0 ] || die "artifact directory contains no files: $artifact_dir"

printf 'artifact paths: no private CI roots in %s\n' "$artifact_dir"
