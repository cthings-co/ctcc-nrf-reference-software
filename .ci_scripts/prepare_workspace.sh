#!/usr/bin/env bash
#
#
#

set -euxo pipefail

WEST_WORKSPACE="$(dirname "$GITHUB_WORKSPACE")"
MANIFEST_PATH="$(basename "$GITHUB_WORKSPACE")"


stale_root_owned=0
for stale in "$WEST_WORKSPACE/build" "$WEST_WORKSPACE/bootloader" \
             "$WEST_WORKSPACE/modules" "$WEST_WORKSPACE/tools" \
             "$WEST_WORKSPACE/test" "$WEST_WORKSPACE/nrfxlib" \
             "$WEST_WORKSPACE/.west" "$ZEPHYR_REPO" "$NRF_REPO" \
             "$HOME/venv" "$HOME/.gitconfig"; do
  [ -e "$stale" ] || continue
  [ -O "$stale" ] && continue
  echo "::error::$stale is owned by uid $(stat -c %u "$stale"), not by the build uid $(id -u)"
  stale_root_owned=1
done
if [ "$stale_root_owned" -ne 0 ]; then
  echo "Left over from the old root prepare container. Repair this runner once with:" >&2
  echo "  sudo chown -R $(id -u):$(id -g) $WEST_WORKSPACE" >&2
  exit 1
fi

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

wipe_west_trees() {
  safe_rm "$WEST_WORKSPACE/build"
  safe_rm "$WEST_WORKSPACE/bootloader"
  safe_rm "$WEST_WORKSPACE/modules"
  safe_rm "$WEST_WORKSPACE/tools"
  safe_rm "$WEST_WORKSPACE/test"
  safe_rm "$WEST_WORKSPACE/nrfxlib"
  safe_rm "$ZEPHYR_REPO"
  safe_rm "$NRF_REPO"
}

wipe_west_trees

#
if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
  echo "python3 in this image has no ensurepip; trying to install python3-venv"
  apt-get install -y python3-venv \
    || (apt-get update && apt-get install -y python3-venv) \
    || true
  python3 -c "import ensurepip" >/dev/null 2>&1 || {
    echo "ERROR: this image cannot create a virtualenv (python3 has no" >&2
    echo "       ensurepip) and python3-venv could not be installed." >&2
    echo "       Check the ZEPHYR_CI_IMAGE pin in the workflow." >&2
    exit 1
  }
fi

python3 -m venv --clear "$HOME/venv"
. "$HOME/venv/bin/activate"
pip install -U pip setuptools wheel

WEST_VERSION="1.5.0"
pip install "west==$WEST_VERSION"

python3 -V
west --version

#
safe_rm "$WEST_WORKSPACE/.west"
west init -l "$GITHUB_WORKSPACE"

west config manifest.path "$MANIFEST_PATH"
west config manifest.file west.yml

find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true

git config --global http.lowSpeedLimit 1
git config --global http.lowSpeedTime 600
git config --global http.postBuffer 524288000

#
#
#
#
GIT_CREDENTIALS_FILE="$HOME/.git-credentials"

clear_github_auth() {
  rm -f "$GIT_CREDENTIALS_FILE" || true
  git config --global --unset credential.helper || true
}
clear_github_auth
trap clear_github_auth EXIT

if [ -n "${GITHUB_FETCH_TOKEN:+set}" ]; then
  git config --global credential.helper store
  : > "$GIT_CREDENTIALS_FILE"
  chmod 600 "$GIT_CREDENTIALS_FILE"
  set +x
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_FETCH_TOKEN" >> "$GIT_CREDENTIALS_FILE"
  set -x
  echo "github.com: authenticated fetch enabled (token kept out of remote URLs)"
else
  echo "github.com: no GITHUB_FETCH_TOKEN - fetching anonymously, subject to GitHub per-IP rate limits" >&2
fi

#
#
#
for attempt in 1 2 3; do
  if west update --narrow -o=--depth=1; then
    break
  fi
  echo "west update failed on attempt $attempt"
  find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true
  if [ "$attempt" -eq 3 ]; then
    echo "state of the workspace filesystem after three failed attempts:"
    df -h "$WEST_WORKSPACE" || true
    df -i "$WEST_WORKSPACE" || true
    exit 1
  fi
  echo "wiping the west trees so the retry starts from an empty working tree"
  wipe_west_trees
  sleep $((attempt * 10))
done

#
#
#
pip install -r "$ZEPHYR_REPO/scripts/requirements-base.txt"
pip install -r "$NRF_REPO/scripts/requirements.txt"
pip install jinja2
#
#
pip install -e "$WEST_WORKSPACE/bootloader/mcuboot/scripts"
python -c 'import imgtool, pathlib; print("imgtool", imgtool.imgtool_version, "resolved from", pathlib.Path(imgtool.__file__).resolve().parent)'

#
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
apply_patches "$NRF_REPO" nrf-sdk

installed_west="$(pip show west | sed -n "s/^Version: //p")"
if [ "$installed_west" != "$WEST_VERSION" ]; then
  echo "ERROR: west is now $installed_west, but this workspace was resolved with" >&2
  echo "       the pinned $WEST_VERSION. An SDK requirement file has raised its" >&2
  echo "       minimum past the pin - bump WEST_VERSION in this script in the" >&2
  echo "       same commit that bumps the SDK." >&2
  exit 1
fi

pip freeze --local > "$GITHUB_WORKSPACE/python-requirements.lock"

. "$ZEPHYR_REPO/zephyr-env.sh"
