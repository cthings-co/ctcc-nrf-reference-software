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
# NRF_REPO, HOME. Optionally GITHUB_FETCH_TOKEN - see the github.com authentication
# block below; with it unset the west fetches are anonymous and this script still runs
# to completion, so a fork or a hand-run still works.

set -euxo pipefail

WEST_WORKSPACE="$(dirname "$GITHUB_WORKSPACE")"
MANIFEST_PATH="$(basename "$GITHUB_WORKSPACE")"

# No `git config --global --add safe.directory` list any more, and no chown after this
# script: the container runs as the uid that owns the mounted workspace
# (docker run -u "$HOST_UID:$HOST_GID"), so git already sees matching ownership on every
# tree it touches. The old list was incomplete in a way that only the later chown hid -
# it named four repos, while `west ncs-sbom` runs `git remote get-url` in every module
# under modules/ as well.

# One-time transition guard. A runner that last ran the old root container can still
# hold root-owned west trees, and as the runner user we can no longer delete them:
# safe_rm below would spend ~18s retrying each path and then fail with a bare
# "could not remove", which says nothing about ownership. Check only the paths this
# script deletes and recreates - that is exactly the set the root container used to
# write - and name the one-line repair. Cheap: a handful of stat calls, not a walk.
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

# Wipe west workspace content (sibling dirs). A function rather than a straight run
# of safe_rm calls because the `west update` retry loop below needs exactly the same
# set: a failed update leaves a project half checked out, and git then refuses every
# retry with "untracked working tree files would be overwritten by checkout" - so the
# retries can only help if the tree they retry into is empty again.
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

# The Python environment is built HERE, before `west init` and `west update`,
# and that order is the whole point of this block. Until it moved up, two
# different wests were involved in one build: the manifest was resolved and the
# SDK checked out by whatever west the pinned CI image happens to bake in, while
# the build step activates this venv and runs `west build` / `west ncs-sbom`
# with the west that pip put here - and the SDK only asks for `west>=1.4.0`
# (nrf/scripts/requirements-base.txt), so that second one was PyPI-latest and
# could change under the repository with nothing in the diff to explain the
# resulting failure. Everything this repository publishes is signed,
# version-stamped firmware, so the tool that produces it is pinned like the SDK
# and the CI image are.
#
# Guard `python3 -m venv` against an image whose python3 has no ensurepip. The
# pinned image has it, so the probe is a no-op today; it is here because bumping
# ZEPHYR_CI_IMAGE is an anticipated, routine change (see the comment on it in
# .github/workflows/build-firmwares.yml) and without this the bump would fail on
# the venv line with a message about ensurepip, which says nothing about what
# actually changed. The recovery is best-effort on purpose: the prepare step
# runs as root today, but this script must not start failing if it ever stops
# doing so - the named error below is what has to survive, not the apt-get.
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

# --clear because $HOME is .container-home on the mounted workspace and is NOT
# wiped by safe_rm above: a half-built venv from an interrupted run would
# survive, and `python3 -m venv` over an existing directory will not repair it.
python3 -m venv --clear "$HOME/venv"
. "$HOME/venv/bin/activate"
pip install -U pip setuptools wheel

# The single west that resolves the manifest below AND builds the images in the
# next workflow step. Bump it deliberately, in its own reviewable commit, the
# way the SDK revision in west.yml and ZEPHYR_CI_IMAGE are bumped. 1.5.0
# satisfies both minimums declared by the pinned NCS v3.4.0 checkout
# (zephyr/scripts/requirements-base.txt asks west>=0.14.0,
# nrf/scripts/requirements-base.txt asks west>=1.4.0), so the SDK requirement
# installs further down find it already satisfied and leave it alone; the check
# after those installs makes sure that stays true.
WEST_VERSION="1.5.0"
pip install "west==$WEST_VERSION"

# Print what is actually going to resolve and build, so the job log answers
# "which west and which python produced this image" on its own.
python3 -V
west --version

# Re-initialise the workspace unconditionally. This block used to reuse an
# existing $WEST_WORKSPACE/.west whenever its config already carried a
# `path = <manifest repo>` line, and wipe it only otherwise - but that branch
# saved nothing: every west-managed tree is wiped just above, so `west update`
# below re-fetches them either way, and all the reuse preserved was the config
# file itself, which `west init -l` rewrites in milliseconds. What it did
# preserve was every OTHER key a previous - possibly interrupted - run had left
# in that config, on a self-hosted runner where nine matrix rows share one
# workspace. The rest of this script (the safe_rm retry above, the *.lock
# sweeps below) is written on the assumption that the previous run may have
# died mid-write; this line now agrees with it.
#
# Note WHICH .west: the workspace topdir is the PARENT of the manifest repo, so
# the config dir is $WEST_WORKSPACE/.west and NOT $GITHUB_WORKSPACE/.west.
# Removing the wrong one leaves a reused runner holding the previous job's
# manifest pointer, `west update` then pulls a different SDK, and the failure
# surfaces much later as patches that will not apply.
safe_rm "$WEST_WORKSPACE/.west"
# `west init -l` takes exactly ONE positional (the manifest repo);
# the workspace is inferred as its parent. Passing a second arg
# makes west exit 2 and (set -e) aborts the Prepare step.
# Not tolerated with `|| true`: safe_rm above already fails loudly if it could
# not remove .west, and a west that still found some other topdir must abort
# here rather than let the two commands below write our manifest pointer into
# a workspace we did not mean to touch.
west init -l "$GITHUB_WORKSPACE"

# `west init -l` has just written both of these, so on the normal path they are
# redundant - state them anyway. Together they are the WHOLE manifest pointer,
# and the code this replaced asserted only half of it: it grepped manifest.path
# and never looked at manifest.file, so a config carrying a different `file =`
# was reused as-is. Two idempotent commands also beat a regex over west's own
# config format. `west config` writes the local (workspace) scope by default,
# which is exactly $WEST_WORKSPACE/.west/config.
west config manifest.path "$MANIFEST_PATH"
west config manifest.file west.yml

# Clean any stale lock files from interrupted runs
find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true

# Make git more tolerant on slow links
git config --global http.lowSpeedLimit 1
git config --global http.lowSpeedTime 600
git config --global http.postBuffer 524288000

# ---------------------------------------------------------------------------
# Authenticate the github.com fetches that `west update` is about to make.
#
# WHY: GitHub throttles ANONYMOUS git traffic per source IP, and answers a
# throttled request with 401 - a credential challenge - not 429. With no tty to
# prompt on, git dies with `could not read Username for 'https://github.com': No
# such device or address`, which reads like a misconfiguration and not like a
# rate limit. It also presents as a random PARTIAL failure rather than a clean
# refusal: on a shared IP some fetches get through and most do not, so a job
# making one GitHub fetch fails outright while a job making sixty sees roughly a
# quarter of them through. This repository is close to the worst case for it -
# west.yml sets import: true on sdk-nrf, so a single `west update` is on the
# order of a hundred fetches, and the matrix runs nine of them per pipeline from
# one self-hosted runner whose egress IP is shared with every other workload on
# that machine. The three-attempt retry around `west update` below does not help:
# it re-enters the same per-IP limit ten and twenty seconds later, so it triples
# the wall clock and still fails. An authenticated fetch is not subject to the
# anonymous limit at all.
#
# Note that the credential actions/checkout sets up does nothing for this: it is
# an http.extraheader in THIS repository's .git/config, and west's projects are
# separate clones with their own configs.
#
# HOW, and this part is the bit not to "simplify" later: the token goes into
# git's credential store, keyed by host, and NEVER into a remote URL.
# `west ncs-sbom` records each project's remote via `git remote get-url`, so a
# tokenized URL would be copied verbatim into the SPDX document that this
# pipeline publishes to a public GitHub Release. url.insteadOf is rejected for
# exactly that reason - get-url expands it, so it is a tokenized URL wearing a
# hat - and being global it also lingers on a non-ephemeral runner. A global
# http.extraheader is rejected too: git sends it to every https host it talks to,
# not just github.com, which is a strictly wider blast radius than a store keyed
# by hostname. scrub_sbom_credentials in build_sdk.sh stays as the fail-closed
# backstop; it is a backstop, not a licence to leak.
#
# The token is OPTIONAL. With GITHUB_FETCH_TOKEN unset this whole block is a
# no-op and fetches stay anonymous, so a fork, a local run or a runner without
# the secret still builds whenever GitHub is not throttling.
# ---------------------------------------------------------------------------
GIT_CREDENTIALS_FILE="$HOME/.git-credentials"

# HOME here is $WORKSPACE_ROOT/.container-home on the MOUNTED workspace of a
# reused self-hosted runner - it is deliberately not in the safe_rm list above,
# because the venv lives there - so anything written to it outlives the job.
# Clear whatever a previously killed run left behind BEFORE deciding what to do
# (a stale token is also a dead token, and silently retrying with it would look
# like an auth failure rather than a leftover), and clear ours again on the way
# out, on the failure paths as well as the happy one. The workflow repeats the
# removal with `if: always()` for the case where the container is killed outright
# and this trap never runs.
clear_github_auth() {
  rm -f "$GIT_CREDENTIALS_FILE" || true
  git config --global --unset credential.helper || true
}
clear_github_auth
trap clear_github_auth EXIT

# ${VAR:+set} and not "$VAR": with `set -x` on, `[ -n "$GITHUB_FETCH_TOKEN" ]`
# traces as `[ -n ghs_realtokenhere ]` and the token is in the log before the
# script has done anything with it. The :+ form expands to the fixed string
# "set" or to nothing, so the trace stays truthful and carries no secret. This
# was caught by running the block under `set -x` with a fake token and grepping
# the trace; do not fold it back into a plain -n test.
if [ -n "${GITHUB_FETCH_TOKEN:+set}" ]; then
  git config --global credential.helper store
  # Create the file and lock it down BEFORE the token goes into it, so it is
  # never even briefly readable by another uid on this shared machine.
  : > "$GIT_CREDENTIALS_FILE"
  chmod 600 "$GIT_CREDENTIALS_FILE"
  # This script runs under `set -x` (the set -euxo pipefail at the top). Without
  # turning the trace off for exactly this one line, the expanded printf writes
  # the token verbatim into the job log. GitHub Actions does mask a secret it
  # knows about, but that masking matches on the literal string and is a last
  # resort, not a design.
  set +x
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_FETCH_TOKEN" >> "$GIT_CREDENTIALS_FILE"
  set -x
  echo "github.com: authenticated fetch enabled (token kept out of remote URLs)"
else
  echo "github.com: no GITHUB_FETCH_TOKEN - fetching anonymously, subject to GitHub per-IP rate limits" >&2
fi

# Shallow, and only correct because of the `--narrow` already on this line.
# With --narrow west fetches the pinned revision itself as the refspec (west's
# app/project.py takes the else-branch of `_maybe_sha(rev) and not self.narrow`),
# so `-o=--depth=1` - which west hands straight to `git fetch` - yields exactly
# one commit and it IS the pinned SHA. Without --narrow west fetches
# refs/heads/*, and a depth-1 branch tip need not contain the pinned commit.
#
# This comment used to read "No shallow; imports work best with plain west
# update". That is not true of this manifest: west.yml here is a single
# `nrf`/sdk-nrf project at v3.4.0 with `import: true`, the same resolution the
# private nrf-ctcc-firmwares pipeline has been doing with
# `west update --narrow -o=--depth=1` in every one of its build jobs. Full
# history re-cloned the entire NCS tree - several GB - once per matrix row, nine
# times per run at max-parallel: 1, and that is most of what the workflow's
# disk-reclaim block exists to survive.
#
# Nothing downstream needs the history:
#   - patches are applied with `git -C <repo> apply` (apply_patches below), which
#     only touches the working tree - no `git am`, no three-way merge against an
#     ancestor commit;
#   - `west ncs-sbom`'s git-info detector runs only `git rev-parse HEAD`,
#     `git remote get-url` and `git status --porcelain --ignored`
#     (nrf/scripts/west_commands/sbom/git_info_detector.py) - no describe, no
#     tags, no log walk, so SBOM provenance is unchanged;
#   - the firmware version comes from firmware/VERSION, not from git.
# The one visible change is Zephyr's BUILD_VERSION: gen_version_h.cmake runs
# `git describe --abbrev=12 --always`, which with no tags fetched returns a bare
# SHA. It reaches only the GENERIC boot banner - the one patches/zephyr/0001
# replaces with APP_VERSION_STRING - and the application half of it is already a
# bare SHA today, because the build job checks this repo out with fetch-depth: 1.
#
# If a shallow fetch of a pinned SHA ever fails it is one project's host refusing
# a by-SHA want; exempt that project rather than dropping --depth for the tree.
for attempt in 1 2 3; do
  if west update --narrow -o=--depth=1; then
    break
  fi
  echo "west update failed on attempt $attempt"
  find "$WEST_WORKSPACE" -name "*.lock" -type f -delete || true
  if [ "$attempt" -eq 3 ]; then
    # State before giving up, because the interesting failures here are not network
    # errors. A checkout that dies with "unable to write new index file" is out of
    # space OR out of inodes, and `df -h` alone cannot tell those apart - measured on
    # a runner reporting 29G free while one row failed and the other eight passed.
    echo "state of the workspace filesystem after three failed attempts:"
    df -h "$WEST_WORKSPACE" || true
    df -i "$WEST_WORKSPACE" || true
    exit 1
  fi
  # Deleting the trees before retrying, not just the lock files. Removing locks
  # recovers an interrupted git; it does nothing for a project whose working tree was
  # half written, and git refuses to check out over those files, so attempts 2 and 3
  # failed identically to attempt 1 for a reason that had nothing to do with attempt
  # 1's cause. The re-fetch this costs is the price of a retry that can actually pass.
  echo "wiping the west trees so the retry starts from an empty working tree"
  wipe_west_trees
  sleep $((attempt * 10))
done

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
# for ctcc/nrf52840 and both SBOM outputs are produced. These three sets are still
# unpinned and unhashed - west is the exception, pinned above because it is the one
# tool that both resolves the manifest and builds the images. What the resolver
# actually chose is recorded at the end of this script and published beside the
# firmware, so a build can at least be reconstructed after the fact; installing from
# a committed lockfile with --require-hashes is the step that would make it
# reproducible in advance.
pip install -r "$ZEPHYR_REPO/scripts/requirements-base.txt"
# NOT allowed to fail. This file plus requirements-base.txt above happen to cover
# imgtool's declared dependencies - cryptography, intelhex, click, cbor2 and pyyaml,
# the install_requires of bootloader/mcuboot/scripts/setup.py - and part of what
# `west ncs-sbom` needs. Swallowing a partial install meant either a
# ModuleNotFoundError a job phase later with the real cause elsewhere, or
# a green artifact set with no SBOM in it. pip is not retried here, unlike
# `west update` above, so a transient index failure now fails the job.
pip install -r "$NRF_REPO/scripts/requirements.txt"
pip install jinja2
# imgtool, from the MCUboot revision THIS build uses - not from PyPI, not from the CI
# image. Nothing above installs the imgtool PACKAGE:
# bootloader/mcuboot/scripts/imgtool.py is a bare `from imgtool import main` with no
# sys.path manipulation, so it imports only because Python puts the script's own
# directory on sys.path[0] - run that same script under `python -P`, which turns that
# off, and it dies with `ModuleNotFoundError: No module named 'imgtool'`. Its declared
# dependencies (cryptography, intelhex, click, cbor2, pyyaml) are likewise satisfied
# only by the two requirements files above happening to carry them for their own
# reasons. The editable install turns both accidents into statements and buys the
# property worth having deliberately: the tool that signs an image is always from the
# same revision as the loader that has to verify its signature.
#
# It does NOT change which imgtool CMake picks here. FindHostTools.cmake in the pinned
# Zephyr runs find_program(IMGTOOL imgtool.py HINTS <mcuboot>/scripts/ NAMES imgtool
# NAMES_PER_DIR), and NAMES_PER_DIR searches the HINTS directory first trying every
# name in it, so the in-tree script still wins over the `imgtool` console script this
# install drops into the venv. On an older Zephyr that find_program is a bare PATH
# search and the console script would win instead - which is exactly the point: after
# this line both discovery paths land on the same revision.
#
# -e so a later patch under scripts/ stays live rather than snapshotted. The egg-info
# it writes goes to $WEST_WORKSPACE/bootloader/mcuboot/scripts/, outside the repo
# checkout, and the workflow's `sudo chown -R` over $WORKSPACE_ROOT after this step
# hands that and the .pth in $HOME/venv back to the runner user.
pip install -e "$WEST_WORKSPACE/bootloader/mcuboot/scripts"
# Print which imgtool the venv actually resolves, so a stale wheel pulled in by some
# other requirement shows up here instead of as an unexplained signature later.
python -c 'import imgtool, pathlib; print("imgtool", imgtool.imgtool_version, "resolved from", pathlib.Path(imgtool.__file__).resolve().parent)'

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

# The SDK requirement files installed above ask only for `west>=...`, which the
# pin already satisfies, so pip left west alone - assert that instead of
# assuming it. If a future SDK raises its minimum past WEST_VERSION, pip quietly
# upgrades west right here and the images are once again built by a floating
# tool, with the manifest still having been resolved by the pinned one. That is
# exactly the split this script was reordered to remove, so it fails loudly and
# names the fix rather than being discovered later from a build that changed for
# no reason anyone can point at.
installed_west="$(pip show west | sed -n "s/^Version: //p")"
if [ "$installed_west" != "$WEST_VERSION" ]; then
  echo "ERROR: west is now $installed_west, but this workspace was resolved with" >&2
  echo "       the pinned $WEST_VERSION. An SDK requirement file has raised its" >&2
  echo "       minimum past the pin - bump WEST_VERSION in this script in the" >&2
  echo "       same commit that bumps the SDK." >&2
  exit 1
fi

# Record the exact Python environment that produced this workspace, and ship it.
# `west ncs-sbom` walks source repositories and git metadata, so the SBOM this
# build publishes says which sdk-nrf revision an image came from and nothing
# about the cryptography, imgtool, zcbor or nrf-regtool that generated and
# signed it - and apart from west above, every one of those floats. The Collect
# step copies this file in beside the images, so a published artifact set
# carries the environment it was built in; that matters more here than in a
# product repository, because this one exists to be reproduced by somebody else.
# Committing the result as .ci_scripts/python-constraints.txt and passing `-c`
# to the pip installs above is the next step if a tagged build ever has to be
# reproduced byte-for-byte.
pip freeze --local > "$GITHUB_WORKSPACE/python-requirements.lock"

. "$ZEPHYR_REPO/zephyr-env.sh"
