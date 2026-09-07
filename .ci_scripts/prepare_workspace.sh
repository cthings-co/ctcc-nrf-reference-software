#!/usr/bin/env bash
#
# Prepare the west workspace and Python environment for a firmware build.
#
# Runs inside the Zephyr CI container, invoked by .github/workflows/build-firmwares.yml.
# It lives in a file rather than inline in the workflow on purpose: the workflow used to
# pass this body to `bash -lc '...'`, and a single apostrophe in a comment ("the SDK's
# whole development set") closed that quoted string, so every command past that line ran
# on the runner host instead of in the container. The failure surfaced as a bare
# `pip: command not found` pointing at the runner's temp script, which says nothing about
# the real cause. As a file, quoting inside this script is no longer load-bearing.
#
# Expects in the environment (passed by `docker run -e`): GITHUB_WORKSPACE, ZEPHYR_REPO,
# NRF_REPO, HOME.

set -euxo pipefail

WEST_WORKSPACE="$(dirname "$GITHUB_WORKSPACE")"
WEST_CONFIG="$WEST_WORKSPACE/.west/config"
MANIFEST_PATH="$(basename "$GITHUB_WORKSPACE")"

# We run as root in container but the mounted workspace is owned by the runner user.
# Tell git to trust the repos we access from the mounted workspace.
for safe_dir in "$GITHUB_WORKSPACE" "$ZEPHYR_REPO" "$NRF_REPO" \
                "$WEST_WORKSPACE/bootloader/mcuboot"; do
  git config --global --add safe.directory "$safe_dir"
done

safe_rm() {
  local p="$1"
  [ -e "$p" ] || return 0
  for i in 1 2 3; do
    rm -rf "$p" && return 0
    echo "rm -rf failed for $p (attempt $i), retrying..."
    sync || true
    sleep $((i * 2))
  done
  if [ -d "$p" ]; then
    find "$p" -mindepth 1 -xdev -exec rm -rf {} + 2>/dev/null || true
  fi
  rm -rf "$p" || true
  [ ! -e "$p" ] || { echo "ERROR: could not remove $p"; return 1; }
}

# Wipe west workspace content (sibling dirs)
safe_rm "$WEST_WORKSPACE/build"
safe_rm "$WEST_WORKSPACE/bootloader"
safe_rm "$WEST_WORKSPACE/modules"
safe_rm "$WEST_WORKSPACE/tools"
safe_rm "$WEST_WORKSPACE/test"
safe_rm "$WEST_WORKSPACE/nrfxlib"
safe_rm "$ZEPHYR_REPO"
safe_rm "$NRF_REPO"

if [ -f "$WEST_CONFIG" ] && grep -Eq "^[[:space:]]*path[[:space:]]*=[[:space:]]*$MANIFEST_PATH[[:space:]]*$" "$WEST_CONFIG"; then
  echo "Reusing existing west workspace at $WEST_WORKSPACE"
else
  safe_rm "$WEST_WORKSPACE/.west"
  # `west init -l` takes exactly ONE positional (the manifest repo);
  # the workspace is inferred as its parent. Passing a second arg
  # makes west exit 2 and (set -e) aborts the Prepare step.
  west init -l "$GITHUB_WORKSPACE"
fi

# Clean any stale lock files from interrupted runs
find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true

# Make git more tolerant on slow links
git config --global http.lowSpeedLimit 1
git config --global http.lowSpeedTime 600
git config --global http.postBuffer 524288000

# No shallow; imports work best with plain west update
for attempt in 1 2 3; do
  if west update --narrow; then
    break
  fi
  echo "west update failed on attempt $attempt"
  find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true
  [ "$attempt" -eq 3 ] && exit 1
  sleep $((attempt * 10))
done

# --clear because $HOME is .container-home on the mounted workspace and is NOT
# wiped by safe_rm above: a half-built venv from an interrupted run would
# survive, and `python3 -m venv` over an existing directory will not repair it.
python3 -m venv --clear "$HOME/venv"
. "$HOME/venv/bin/activate"

# Only what a build and an SBOM need, not the SDK's whole development set.
# zephyr/scripts/requirements.txt aggregates base + build-test + run-test + extras +
# compliance; nothing here runs twister, the docs build or the compliance checks, so
# only requirements-base.txt is installed. nrf/scripts/requirements.txt is already
# just base + build, so it stays whole.
#
# jinja2 is listed explicitly because `west ncs-sbom` imports it directly
# (nrf/scripts/west_commands/sbom/output_template.py) to render BOTH the HTML and the
# SPDX report, and it appears in none of the sets installed here - it used to arrive
# transitively through the compliance/docs tools in the aggregate file, so the SBOM
# worked by accident. Narrowing without this line would have produced builds with no
# SBOM and only a warning to say so.
#
# scancode-toolkit is deliberately NOT installed: the detector list excludes it
# (--optional-license-detectors ''), and requirements-west-ncs-sbom.txt would pull in
# scancode-toolkit[full] for a detector nothing asks for.
#
# Verified in a clean venv with exactly these installs: the sysbuild firmware builds
# for ctcc/nrf52840 and both SBOM outputs are produced. Still unpinned and unhashed - a
# committed lockfile installed with --require-hashes is the next step if reproducing a
# tagged build byte-for-byte ever matters.
pip install -U pip setuptools wheel
pip install -r "$ZEPHYR_REPO/scripts/requirements-base.txt"
# NOT allowed to fail. This file supplies cryptography, cbor2, click and
# zcbor - everything imgtool needs to sign an image, and part of what
# `west ncs-sbom` needs. Swallowing a partial install meant either a
# ModuleNotFoundError a job phase later with the real cause elsewhere, or
# a green artifact set with no SBOM in it. pip is not retried here, unlike
# `west update` above, so a transient index failure now fails the job.
pip install -r "$NRF_REPO/scripts/requirements.txt"
pip install jinja2

# Apply downstream patches. The pinned NCS Zephyr fork already
# ships the ctcc board (nRF52840/nRF9161); patches/zephyr/0002
# adds the nRF9151 target and the board fixes on top (so we no
# longer strip the board from the Zephyr tree). The remaining
# patches add the custom boot banner, sample/app overlays and the
# MCUboot serial-recovery configuration.
#
# An EMPTY patch set fails the job: a glob over a directory that
# does not exist expands to nothing, so a renamed or mistyped
# patches/<subdir> would otherwise apply ZERO patches and still
# build, and the resulting failure (a pristine SDK has no ctcc
# board) surfaces much later and much less clearly.
# PATCHES_OPTIONAL lists sets that are allowed to be empty; this
# repository builds a single SDK profile and patches both trees, so
# it is empty here. The list exists because the same helper is used
# where several SDK profiles are built and some sets are legitimately
# empty.
PATCHES_OPTIONAL=""
apply_patches() {
  local repo="$1" subdir="$2" p count=0
  for p in "$GITHUB_WORKSPACE/patches/$subdir"/*.patch; do
    [ -e "$p" ] || continue
    echo "Applying $(basename "$p") to $repo"
    git -C "$repo" apply "$p"
    count=$((count + 1))
  done
  if [ "$count" -gt 0 ]; then
    echo "Applied $count patch(es) from patches/$subdir/ to $repo"
    return 0
  fi
  case " $PATCHES_OPTIONAL " in
    *" $subdir "*)
      echo "No patches in patches/$subdir/ - expected" ;;
    *)
      echo "ERROR: no patches found in patches/$subdir/" >&2
      exit 1 ;;
  esac
}
apply_patches "$ZEPHYR_REPO" zephyr
apply_patches "$WEST_WORKSPACE/bootloader/mcuboot" mcuboot

. "$ZEPHYR_REPO/zephyr-env.sh"
