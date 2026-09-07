#!/bin/bash
set -euo pipefail

echo "BUILD_TYPE: ${BUILD_TYPE}"

# The ctcc board lives in Zephyr (the pinned NCS zephyr fork already ships
# nRF52840/nRF9161; patches/zephyr/0002 adds the nRF9151 target and the board
# fixes on top, applied during CI prep). This repository is a Zephyr module
# that provides the example firmware application, its drivers and the per-board
# configuration under firmware/. Board-level app configs
# (firmware/boards/ctcc_<soc>[_ns].conf and .overlay) and the sysbuild config
# (firmware/sysbuild.conf) are picked up automatically by the build system - and so is
# the MCUboot image config: sysbuild adopts firmware/sysbuild/mcuboot/ as that image's
# APPLICATION_CONFIG_DIR because the application being built IS firmware/. This used
# to pass -Dmcuboot_CONF_FILE/-Dmcuboot_DTC_OVERLAY_FILE as well, which configured the
# loader through a different mechanism from the one a customer's plain `west build`
# uses - two code paths for the same result, only one of them documented. Verified
# equivalent: with and without those arguments the loader's generated .config is
# byte-identical, ctcc PID 0x0101 and product string included.
# Repo root: GitHub Actions sets GITHUB_WORKSPACE; fall back to this script's own
# location so the reference flow can also be run by hand or under another CI.
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FW_DIR="${REPO_ROOT}/firmware"

# Zephyr checkout. The workflow exports this; default it to the sibling of the repo
# root, which is where west puts zephyr in a standard workspace and is the same value
# the workflow passes. Without a default, `set -u` aborts a by-hand firmware build on
# the one line that needs it - the mergehex call that assembles merged.hex - and does
# so only after the whole image has been built and signed.
ZEPHYR_REPO="${ZEPHYR_REPO:-${REPO_ROOT}/../zephyr}"

# The Zephyr SDK is bundled in the CI image, so the image pin and this path are two
# halves of one fact (the workflow declares them side by side, with a table of which
# image ships which SDK). Bumping one without the other leaves ZEPHYR_SDK_INSTALL_DIR
# pointing at a directory that does not exist, and the build then dies inside cmake
# with a toolchain error that says nothing about the image - so check it here, before
# a single object is compiled. Zephyr states what it wants machine-readably in
# zephyr/SDK_VERSION (1.0.1 for the pinned NCS v3.4.0).
#
# Only checked when the variable is set: a by-hand build may legitimately leave it
# unset and let Zephyr find an SDK through its CMake package registry instead.
#
# A differing MAJOR version is fatal because cmake will reject it outright
# (zephyr/cmake/modules/FindHostTools.cmake asks for `find_package(Zephyr-sdk 1.0)`,
# which no 0.17.x SDK satisfies); a differing patch level is only a warning, because
# the SDK package declares itself compatible across those and SDK_VERSION is the
# version Zephyr would INSTALL, not a hard floor.
if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
  if [ ! -d "${ZEPHYR_SDK_INSTALL_DIR}" ]; then
    echo "::error::ZEPHYR_SDK_INSTALL_DIR=${ZEPHYR_SDK_INSTALL_DIR} does not exist - the CI image supplies the Zephyr SDK, so this usually means the image pin moved and the SDK path did not"
    exit 1
  fi
  sdk_want=""
  if [ -f "${ZEPHYR_REPO}/SDK_VERSION" ]; then
    sdk_want="$(tr -d '[:space:]' < "${ZEPHYR_REPO}/SDK_VERSION")"
  fi
  # The SDK records its own version at the root of the install tree; fall back to the
  # conventional zephyr-sdk-<version> directory name when that file is not there.
  if [ -f "${ZEPHYR_SDK_INSTALL_DIR}/sdk_version" ]; then
    sdk_have="$(tr -d '[:space:]' < "${ZEPHYR_SDK_INSTALL_DIR}/sdk_version")"
  else
    sdk_have="$(basename "${ZEPHYR_SDK_INSTALL_DIR}")"
    sdk_have="${sdk_have#zephyr-sdk-}"
  fi
  if [ -n "${sdk_want}" ] && [ "${sdk_have}" != "${sdk_want}" ]; then
    if [ "${sdk_have%%.*}" != "${sdk_want%%.*}" ]; then
      echo "::error::Zephyr SDK mismatch: ${ZEPHYR_REPO}/SDK_VERSION asks for ${sdk_want} but ZEPHYR_SDK_INSTALL_DIR=${ZEPHYR_SDK_INSTALL_DIR} provides ${sdk_have}; the CI image tag and the SDK path are one pin, move both"
      exit 1
    fi
    echo "::warning::Zephyr SDK ${sdk_have} at ${ZEPHYR_SDK_INSTALL_DIR}, but ${ZEPHYR_REPO}/SDK_VERSION asks for ${sdk_want}"
  fi
  echo "Zephyr SDK ${sdk_have} at ${ZEPHYR_SDK_INSTALL_DIR} (zephyr/SDK_VERSION: ${sdk_want:-unknown})"
fi

# Fail on a missing variable BEFORE building, not after. APP_NAME is only read after
# the image is built and signed (the mergehex call and the SBOM label), so under
# `set -u` a by-hand firmware build used to run to completion and then abort on the
# last few lines. Default it to the application directory's name - which is what the
# workflow passes anyway - and check the rest up front.
APP_NAME="${APP_NAME:-$(basename "${FW_DIR}")}"

# Two different names that happen to be equal for everything this repository builds:
# IMAGE_NAME is the sysbuild main-image build subdirectory (build/<IMAGE_NAME>/zephyr),
# which sysbuild derives from the application directory's basename; APP_NAME is the
# label the artifacts are published under. An out-of-tree application that calls its
# main image something generic - "app", "ncp", "coprocessor" - makes them differ, and
# then a build that succeeded fails at the mergehex/assert lines below on a path that
# was never going to exist. Default IMAGE_NAME to APP_NAME so nothing has to set it
# until that day.
IMAGE_NAME="${IMAGE_NAME:-${APP_NAME}}"
: "${BUILD_TYPE:?BUILD_TYPE must be set (firmware | bootloader | test)}"
: "${BRD:?BRD must be set (e.g. ctcc)}"
: "${SOC:?SOC must be set (e.g. nrf52840, nrf9151, nrf9161)}"
: "${NS:?NS must be set (true for the /ns board variant, false otherwise)}"

# ctcc/nrf52840 build-level DTS overlay, applied to the application image AND the
# MCUboot image. Extra overlays are additive: they do not replace the MCUboot
# configuration directory's app.overlay.
#
#   ctcc_nrf52840_uicr.overlay - reset-as-GPIO (mPCIe/M.2 PERST#). Applied to the
#     Open Bootloader too: without it a card that has only ever run the standalone
#     loader has no PERST reset until an application boots once.
#
# The flash layout is deliberately NOT overridden here - it comes from the board
# devicetree, so this stays a stock SDK build. Nothing is applied for nRF91, whose
# reset pin is not configurable this way, or for the assembly test, which is a
# standalone image flashed over SWD.
CTCC_DTS_OVERLAYS=""
if [ "${SOC:-}" = "nrf52840" ]; then
  for _overlay in "${FW_DIR}/ctcc_nrf52840_uicr.overlay"; do
    [ -f "${_overlay}" ] || continue
    CTCC_DTS_OVERLAYS="${CTCC_DTS_OVERLAYS:+${CTCC_DTS_OVERLAYS};}$(realpath "${_overlay}")"
  done
fi

part_overlay_args=()
if [ -n "${CTCC_DTS_OVERLAYS}" ]; then
  part_overlay_args+=("-DEXTRA_DTC_OVERLAY_FILE=${CTCC_DTS_OVERLAYS}"
                      "-Dmcuboot_EXTRA_DTC_OVERLAY_FILE=${CTCC_DTS_OVERLAYS}")
fi

# SBOM output directory (collected as an artifact). Kept under build/ so the
# workflow's Collect step picks it up alongside the images.
SBOM_DIR="build/sbom"
# License detectors for west ncs-sbom. scancode-toolkit is intentionally
# excluded so the runner does not need that heavy dependency; SPDX-License-
# Identifier tags plus full-text/git detection are sufficient here.
SBOM_DETECTORS="spdx-tag,full-text,external-file,git-info"

cmake_args=()
if [ -n "${BUILD_OPTS:-}" ]; then
  # BUILD_OPTS is split on whitespace, and that split cannot honour quoting: `read -a`
  # treats a quote character as ordinary text, so a value like -DX="a b" would arrive
  # as two broken words rather than as one argument. Every value passed today is a
  # whitespace-free -DSYMBOL=value token, so splitting is correct - but this script is
  # documented as a flow a customer runs by hand, which is exactly where someone writes
  # a quoted value. Fail loudly rather than mis-split it in silence.
  case "${BUILD_OPTS}" in
    *\"*|*\'*)
      echo "ERROR: BUILD_OPTS contains a quote character: ${BUILD_OPTS}" >&2
      echo "       Values are split on whitespace and quoting is not honoured, so this" >&2
      echo "       would be mis-split. Pass the option through a conf fragment, or extend" >&2
      echo "       this script to take an array instead of a string." >&2
      exit 1
      ;;
  esac
  read -r -a build_opts_array <<< "${BUILD_OPTS}"
  cmake_args+=("${build_opts_array[@]}")
fi

if [ "${NS}" = true ]; then
  board="${BRD}/${SOC}/ns"
else
  board="${BRD}/${SOC}"
fi

# west ncs-sbom (NCS) - generate a Software Bill of Materials for a build. It
# works for every build, including sysbuild multi-image, because it walks the
# ninja dependency tree from zephyr.elf. Emits an HTML license report and an
# SPDX document.
# (Zephyr's `west spdx` is intentionally not used - it does not support
# sysbuild; see https://github.com/zephyrproject-rtos/zephyr/issues/105917.)
#
# Best-effort on an ordinary run, MANDATORY on a release. The SBOM is an advertised
# per-firmware deliverable - the README says every artifact directory ships one under
# its own SHA256SUMS - but every failure path here used to warn and return 0, so a
# release could be cut, packaged, checksummed and attached to a GitHub Release with no
# SBOM in it and nothing in the log but a ::warning:: nobody reads. The failure was
# invisible precisely on the one run where it matters.
#
# Requiredness lives HERE, per image, and not only in the workflow's collect step: a
# firmware row generates TWO SBOMs (the application image and the embedded MCUboot,
# below), so a check on the sbom DIRECTORY passes as long as either one of them
# succeeded - and the one that silently went missing can be the binary that actually
# ships. GITHUB_EVENT_NAME is forwarded into the build container by the workflow; it
# is unset for a by-hand build, which therefore stays best-effort, as it should.
ncs_sbom() {
  local img="$1" label="$2" required=0
  [ "${GITHUB_EVENT_NAME:-}" = "release" ] && required=1
  if [ ! -f "${img}/zephyr/zephyr.elf" ]; then
    if [ "${required}" = 1 ]; then
      echo "::error::ncs-sbom: ${img}/zephyr/zephyr.elf not found, cannot generate the SBOM for ${label} - a release must ship one per image"
      exit 1
    fi
    echo "::warning::ncs-sbom: ${img}/zephyr/zephyr.elf not found, skipping"
    return 0
  fi
  mkdir -p "${SBOM_DIR}"
  # The git-info detector walks every input file, including the read-only Zephyr
  # SDK toolchain (not a git checkout), which spams "not a git repository" /
  # "does not provide valid git remote information" on stderr. Drop just that
  # known-benign noise - keeping git provenance for the real, git-tracked sources
  # and surfacing any genuine error; the process substitution leaves west's own
  # exit status intact for the if below.
  if west ncs-sbom -d "${img}" \
      --license-detectors "${SBOM_DETECTORS}" --optional-license-detectors '' \
      --output-html "${SBOM_DIR}/${label}.sbom.html" \
      --output-spdx "${SBOM_DIR}/${label}.sbom.spdx" \
      2> >(grep -vE 'fatal: not a git repository|does not provide valid git remote information|Command "git" reported errors' >&2); then
    # west can exit 0 having written nothing usable, so test the files: the deliverable
    # is the SBOM, not the exit status. A zero-byte .spdx satisfies every existence
    # check further down the chain - `ls -A`, `find -type f`, the SHA256SUMS glob - and
    # would ship, checksummed, as if it were an SBOM.
    if [ ! -s "${SBOM_DIR}/${label}.sbom.spdx" ] || [ ! -s "${SBOM_DIR}/${label}.sbom.html" ]; then
      if [ "${required}" = 1 ]; then
        echo "::error::west ncs-sbom reported success but wrote no SBOM for ${label} - a release must ship one per image"
        exit 1
      fi
      echo "::warning::west ncs-sbom reported success but wrote no SBOM for ${label}"
      return 0
    fi
    echo "ncs-sbom: wrote ${SBOM_DIR}/${label}.sbom.{html,spdx}"
  else
    if [ "${required}" = 1 ]; then
      echo "::error::west ncs-sbom failed for ${img} - a release must ship an SBOM per image"
      exit 1
    fi
    echo "::warning::west ncs-sbom failed for ${img}"
  fi
}

# Defensive scrub: an SBOM must never carry embedded credentials. west ncs-sbom's
# git-info detector records each source's remote via `git remote get-url`
# (nrf/scripts/west_commands/sbom/git_info_detector.py). GitHub's actions/checkout
# keeps the token in .git/config's extraheader (not the remote URL), so a clean
# checkout does not leak here - but redact any "user:secret@host" userinfo from the
# generated SBOMs as belt-and-suspenders (e.g. if a PAT is ever embedded in a
# remote), then fail closed if a credential still remains.
#
# The corollary, for anyone adding authentication to the fetch path later: a token
# belongs in git's credential store, keyed by host, and NEVER in a remote URL or in
# `git config url.<base>.insteadOf`. get-url expands insteadOf, so the token would be
# written straight into the published SPDX - which this repository attaches to a
# public GitHub Release. That is the whole reason this function exists, and the
# reason it fails closed rather than merely warning.
scrub_sbom_credentials() {
  [ -d "${SBOM_DIR}" ] || return 0
  # Match ANY userinfo before '@': both user:secret@ and single-field token@
  # (e.g. https://ghp_xxx@github.com), so the fail-closed check below cannot miss
  # a token-only URL. (SSH-style git@host has no '://', so it is not matched.)
  local cred_re='://[^/@[:space:]]+@'
  local scrubbed=0 f
  while IFS= read -r -d '' f; do
    if grep -qE "${cred_re}" "${f}"; then
      echo "::warning::credential found in ${f#"${SBOM_DIR}"/}, redacting"
      sed -i -E "s#(://)[^/@[:space:]]+@#\1#g" "${f}"
      scrubbed=$((scrubbed + 1))
    fi
  done < <(find "${SBOM_DIR}" -type f -print0)
  if (( scrubbed > 0 )); then
    echo "::warning::redacted embedded credentials from ${scrubbed} SBOM file(s)"
  fi
  if grep -rIlE "${cred_re}" "${SBOM_DIR}" >/dev/null 2>&1; then
    echo "::error::SBOM still contains embedded credentials after scrub"
    exit 1
  fi
}
# Run the scrub from an EXIT trap rather than as the last statement of the script. As
# the last statement it only ever covered a clean finish: a failed west build, or a
# failed assert_approtect/assert_usb_identity, exited first and left whatever SBOMs the
# build had already written unscrubbed under build/sbom - on a self-hosted runner that
# this workflow reuses between jobs, and that the next job does not wipe. The trap
# covers those paths too. `|| true` keeps a hiccup in the scrubber from replacing the
# real failure exit status; the fail-closed `exit 1` above is unaffected, because exit
# from a function exits the shell, so it is never reached by the `||`.
trap 'scrub_sbom_credentials || true' EXIT

# Post-build assertions. Both read an image's GENERATED .config, not its prj.conf, so
# what they check is what the build actually resolved - including anything a board
# defconfig, a Kconfig choice default or an SDK patch pulled in behind this repo's back.
# They run on every image the pipeline publishes.

# patches/zephyr/0003 defaults BOTH APPROTECT choices to LOCK for every ctcc image, so
# an image that is meant to stay debuggable has to opt out explicitly - and that opt-out
# is a handful of lines spread over as many files. Dropping one is silent: the image
# still builds and boots, and then permanently writes UICR.APPROTECT (and on nRF91,
# UICR.SECUREAPPROTECT via TF-M) on the first card it runs on. There is no way back on
# that card. So assert the posture rather than trusting the opt-out to still be there.
#
# The reference images ship debuggable, which is what a template should do; the board
# default remains LOCK, so a customer who wants a locked production build gets it by
# removing their opt-out and setting APPROTECT_EXPECT=lock to have it checked positively.
assert_approtect() {
  local cfg="$1" label="$2" expect="${3:-${APPROTECT_EXPECT:-open}}" tz=n ns=n
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_ARMV8_M_SE=y' "${cfg}" && tz=y
  grep -q '^CONFIG_ARM_NONSECURE_FIRMWARE=y' "${cfg}" && ns=y

  if [ "${expect}" = "lock" ]; then
    grep -q '^CONFIG_NRF_APPROTECT_LOCK=y' "${cfg}" || {
      echo "::error::${label}: NRF_APPROTECT_LOCK is not y - this image would ship with an open debug port"; exit 1; }
    if [ "${tz}" = y ]; then
      grep -q '^CONFIG_NRF_SECURE_APPROTECT_LOCK=y' "${cfg}" || {
        echo "::error::${label}: NRF_SECURE_APPROTECT_LOCK is not y on a TrustZone part - the SECURE access port would stay open"; exit 1; }
    fi
    if [ "${ns}" = n ]; then
      grep -q '^CONFIG_CTCC_APP_PROTECT=y' "${cfg}" || {
        echo "::error::${label}: CTCC_APP_PROTECT is not y in a secure image - nothing writes UICR, so the lock would last only until the next boot"; exit 1; }
    fi
    echo "approtect: ${label}: locked"
    return 0
  fi

  # Each of these is a separate way for the board-wide LOCK default to reach a published
  # image. The SECURE check is deliberately not gated on ${tz}: the choice it comes from
  # depends on the nRF91 series, so the symbol does not exist on nRF52840 and the grep
  # cannot false-positive there - and not gating it means a change in how TrustZone is
  # detected cannot quietly weaken this check.
  grep -q '^CONFIG_CTCC_APP_PROTECT=y' "${cfg}" && {
    echo "::error::${label}: CTCC_APP_PROTECT=y in an image that must stay debuggable - it would write UICR.APPROTECT"; exit 1; }
  grep -q '^CONFIG_NRF_APPROTECT_LOCK=y' "${cfg}" && {
    echo "::error::${label}: NRF_APPROTECT_LOCK=y in an image that must stay debuggable"; exit 1; }
  grep -q '^CONFIG_NRF_SECURE_APPROTECT_LOCK=y' "${cfg}" && {
    echo "::error::${label}: NRF_SECURE_APPROTECT_LOCK=y in an image that must stay debuggable - TF-M would write UICR.SECUREAPPROTECT on its first boot"; exit 1; }
  echo "approtect: ${label}: open, as a reference image must be"
}

# The USB identity is what a host matches on, so a wrong or defaulted PID makes an image
# enumerate as something else - or as Zephyr's sample device. The expected PID is passed
# in rather than derived, because a firmware build contains two images with two different
# PIDs. nRF91 has no USB device controller, so there is nothing to check there.
assert_usb_identity() {
  local cfg="$1" label="$2" want_pid="$3" sym vid pid mfr
  case "${SOC}" in nrf52840) ;; *) return 0 ;; esac
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }

  for sym in CDC_ACM_SERIAL BOOT_SERIAL_CDC_ACM_STRING USB_DEVICE; do
    vid="$(sed -n "s/^CONFIG_${sym}_VID=//p" "${cfg}" | head -1)"
    [ -n "${vid}" ] && break
  done
  if [ -z "${vid}" ]; then
    echo "::error::${label}: no USB VID set by any known symbol family (CDC_ACM_SERIAL, BOOT_SERIAL_CDC_ACM_STRING, USB_DEVICE) - the image would take the stack's default identity"
    exit 1
  fi
  case "${vid}" in
    0x37A1|0x37a1|14241) ;;
    *) echo "::error::${label}: USB VID is ${vid}, expected 0x37A1 (${sym}_VID)"; exit 1 ;;
  esac

  pid="$(sed -n "s/^CONFIG_${sym}_PID=//p" "${cfg}" | head -1)"
  [ -n "${pid}" ] || { echo "::error::${label}: ${sym}_PID is unset - the image would take the stack's default PID"; exit 1; }
  [ "$((pid))" -eq "$((want_pid))" ] || {
    echo "::error::${label}: USB PID is ${pid}, expected ${want_pid}"; exit 1; }

  mfr="$(sed -n "s/^CONFIG_${sym}_MANUFACTURER[A-Z_]*=//p" "${cfg}" | head -1)"
  case "${mfr}" in
    '"CTHINGS.CO"') ;;
    '') echo "::error::${label}: ${sym} manufacturer string is unset, expected \"CTHINGS.CO\""; exit 1 ;;
    *) echo "::error::${label}: USB manufacturer is ${mfr}, expected \"CTHINGS.CO\""; exit 1 ;;
  esac
  echo "usb identity: ${label}: ${vid}:${pid} ${mfr} (${sym}_*)"
}

# Report TF-M's REAL flash headroom on nRF91, because the linker's own number does not.
# This one reports and warns; it deliberately never fails the build (see below).
#
# TF-M links with -Wl,--print-memory-usage, so all six nRF91 rows of this matrix print a
# FLASH line for the secure image into the job log, and that line is the only flash
# figure a reader ever sees for TF-M. It measures neither how much flash TF-M uses nor
# how much room is left, because TF-M's nRF platform anchors the CMSE veneer section
# (.gnu.sgstubs) near the top of an SPU region rather than after the code:
#
#   TFM_LINKER_VENEERS_START = ALIGN(0x8000) - 0x400
#                              + (. > ALIGN(0x8000) - 0x400 ? 0x8000 : 0)
#
# (SPU_FLASH_REGION_SIZE 0x8000, TFM_LINKER_VENEERS_SIZE 0x400, in the generated
# platform/common/nrf91/partition/region_defs.h). ld reports USED as the span from the
# region start to the end of the LAST section, so the whole gap between the code and
# that anchor is counted as used, and the same figure is printed for any code size that
# still fits below the anchor. Measured on ctcc/nrf9151/ns: code+rodata ends at 0x207c0,
# the veneers sit at 0x27c00, and 29,760 of the 96,832 bytes ld calls used are hole.
#
# The number that IS worth knowing is the distance to the anchor - but as a step, not as
# a wall. When TF-M does reach it the veneers hop a whole 32 KB SPU region up and the
# secure image grows by 32 KB in one go, with nothing in the log to announce it; the
# percentage simply jumps. On this board that is survivable: slot0_s_partition is 256 KB
# (0x10000 + 0x40000, from the SDK's nrf91xx_partition.dtsi) and TF-M uses about a
# quarter of it, so the region absorbs several such steps and ld itself fails hard -
# "region FLASH overflowed" - on the one that does not fit. That is why nothing here
# exits non-zero: a gate 1 KB before a step that costs 32 KB out of ~160 KB of spare
# would stop green builds over a non-problem. Product firmware that pins a tight secure
# partition is the case that wants the warning below turned into a hard failure.
#
# Parsed straight out of the ELF section headers, so it needs no toolchain binary beyond
# python3, and the anchor is derived from the image rather than hardcoded as 0x27c00 -
# an SDK bump or a layout change moves it and the report follows. Not called for the
# bootloader rows: those build the same /ns application only to keep its MCUboot child,
# throw the image away, and would print the firmware row's number a second time.
TFM_HEADROOM_MIN=1024
report_tfm_headroom() {
  local dir="$1" label="$2" axf="" c
  case "${SOC}" in nrf91*) ;; *) return 0 ;; esac
  for c in "${dir}/tfm/bin/tfm_s.axf" "${dir}/tfm/api_ns/bin/tfm_s.axf"; do
    [ -f "${c}" ] && { axf="${c}"; break; }
  done
  # No TF-M in this build (a secure, non-/ns nRF91 image): nothing to measure.
  [ -n "${axf}" ] || return 0
  # A reporting step must not be able to break a build that otherwise passed, so an
  # unreadable image is a warning here rather than a non-zero exit.
  local failed="::warning::${label}: could not measure TF-M headroom from ${axf}"
  python3 - "${axf}" "${label}" "${TFM_HEADROOM_MIN}" <<'PYEOF' || echo "${failed}"
import re, struct, sys

path, label, min_free = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = open(path, "rb").read()
if d[:4] != b"\x7fELF":
    print(f"::warning::{label}: {path} is not an ELF file, not measuring TF-M headroom")
    sys.exit(0)
# 32-bit little-endian ARM ELF: section header table offset, entry size and count,
# plus the index of the section that holds the section names.
e_shoff, e_shentsize, e_shnum, e_shstrndx = (
    struct.unpack_from("<I", d, 0x20)[0], struct.unpack_from("<H", d, 0x2E)[0],
    struct.unpack_from("<H", d, 0x30)[0], struct.unpack_from("<H", d, 0x32)[0])

def sh(i):
    o = e_shoff + i * e_shentsize
    name, _typ, flags, addr, off, size = struct.unpack_from("<IIIIII", d, o)
    return name, flags, addr, off, size

strtab_off = sh(e_shstrndx)[3]

def name_at(n):
    return d[strtab_off + n:d.index(b"\0", strtab_off + n)].decode()

SHF_ALLOC = 0x2
placed = sorted((addr, size, name_at(n))
                for n, flags, addr, _off, size in map(sh, range(e_shnum))
                if flags & SHF_ALLOC and size and addr)
veneer = next(((a, s) for a, s, nm in placed if nm == ".gnu.sgstubs"), None)
if veneer is None:
    print(f"tfm headroom: {label}: no .gnu.sgstubs veneer section, nothing to measure")
    sys.exit(0)
anchor = veneer[0]
# Everything below the anchor is the flash image; TF-M's RAM sections live at
# 0x20000000 and are excluded by the same comparison.
below = [(a, s) for a, s, _nm in placed if a < anchor]
if not below:
    print(f"tfm headroom: {label}: nothing placed below the veneer anchor {anchor:#x}")
    sys.exit(0)
code_end = max(a + s for a, s in below)
free = anchor - code_end
content = sum(s for _a, s in below) + veneer[1]
print(f"tfm headroom: {label}: {content} B of content, code+rodata ends {code_end:#x},"
      f" CMSE veneers anchored {anchor:#x} -> {free} B free below the anchor")

# Quote ld's own arithmetic back, so the report names the number the build printed
# instead of leaving the reader to reconcile two figures. -Wl,-Map writes this file
# next to the ELF; if it is absent the measurement above still stands on its own.
try:
    mapped = open(re.sub(r"\.axf$", ".map", path), errors="replace").read()
except OSError:
    mapped = ""
m = re.search(r"^Name\s+Origin\s+Length.*?^FLASH\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)",
              mapped, re.M | re.S)
if m:
    start, length = int(m.group(1), 16), int(m.group(2), 16)
    used = anchor + veneer[1] - start
    print(f"tfm headroom: {label}: the build's own FLASH line reads {used} B of"
          f" {length} B ({100.0 * used / length:.2f}%) - it measures to the end of the"
          f" veneers, so {free} B of that is the hole, not code")
if free < min_free:
    print(f"::warning::{label}: only {free} B left below the CMSE veneer anchor"
          f" {anchor:#x} - the next TF-M growth moves the veneers up a whole 32 KB SPU"
          f" region and the secure image grows by 32 KB in one step")
PYEOF
}

# The signed-image format and the loader upgrade mode together decide whether a card that
# already carries a published Open Bootloader can install a published application image.
# Nothing in this repository states either of them: firmware/sysbuild.conf deliberately leaves
# the mode at the NCS default (SB_CONFIG_MCUBOOT_MODE_SWAP_USING_MOVE) and takes the partitions
# from the board devicetree, while README documents the resulting slot map and swap behaviour
# as a property of the release. Both are therefore inherited from SDK defaults that an SDK bump
# can change with no diff in this tree to show for it, and the failure surfaces on a bench, on
# a card that then needs SWD to recover.
#
# Read what the build ACTUALLY produced instead of inferring it from Kconfig. The inference is
# not sound: nrf/cmake/sysbuild/image_signing.cmake:72 branches on
# CONFIG_PARTITION_MANAGER_ENABLED and only the non-PM branch (:91) consults
# CONFIG_MCUBOOT_IMGTOOL_OVERWRITE_ONLY at all, so the same Kconfig can produce either
# `--overwrite-only --align 1` (no trailer) or `--align <write-block-size>` (a swap trailer
# reserved at the end of the slot). Those are two different on-flash formats. The generated
# imgtool command line is the only statement of which one was made, and unlike a comment it
# cannot drift from the build.
#
# The mode symbol is read as well, because the command line alone cannot separate the swap
# variants: swap-using-move and swap-using-offset are both signed --align <write-block-size>
# with no --overwrite-only, and they use the slot differently. Neither half is sufficient.
#
# Measured on this SDK for ctcc/nrf9151 - this is the line these checks pin:
#   imgtool.py sign --version 1.3.0+0 --slot-size 0x70000 --header-size 0x200 --pad-header
#     --align 4 --rom-fixed 0x50000 -k <key> ... zephyr.signed.bin
assert_signed_image_format() {
  local cfg="$1" ninja="$2" label="$3" cmd="" align="" ovr=n
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_PARTITION_MANAGER_ENABLED=y' "${cfg}" && {
    echo "::error::${label}: PARTITION_MANAGER_ENABLED=y - this build partitions from devicetree, and the Partition Manager branch of image_signing.cmake signs with a different command line"; exit 1; }
  grep -q '^CONFIG_MCUBOOT_BOOTLOADER_MODE_SWAP_USING_MOVE=y' "${cfg}" || {
    echo "::error::${label}: MCUBOOT_BOOTLOADER_MODE_SWAP_USING_MOVE is not y - the upgrade mode is no longer the one the published loaders implement"; exit 1; }

  [ -f "${ninja}" ] || {
    echo "::error::${label}: no ${ninja} - cannot read the imgtool command line the build generated"; exit 1; }
  # awk, not `grep | head`: the invocation is spelled `imgtool sign` on some SDKs and
  # `<path>/imgtool.py sign` on this one, and a grep matching neither exits 1 - which under
  # `set -euo pipefail` kills the script on this very line, before the error below can say
  # why. awk matches both spellings, stops at the first hit and exits 0 whether or not it
  # found anything, so an unrecognised build is REPORTED instead of aborting mutely.
  cmd="$(awk 'match($0, /imgtool(\.py)?[ ]+sign[^&|]*/) {
                print substr($0, RSTART, RLENGTH); exit }' "${ninja}")"
  if [ -z "${cmd}" ]; then
    echo "::error::${label}: no imgtool sign invocation in ${ninja} - the image is signed by the build, so if that moved this guard has to follow it"
    exit 1
  fi
  align="$(printf '%s\n' "${cmd}" | awk 'match($0, /--align[ ]+[0-9]+/) {
                s = substr($0, RSTART, RLENGTH); sub(/--align[ ]+/, "", s); print s }')"
  case "${cmd}" in *--overwrite-only*) ovr=y ;; esac

  if [ "${ovr}" = y ] || [ -z "${align}" ] || [ "${align}" = 1 ]; then
    echo "::error::${label}: the signed image format changed from what every card in the field was given"
    echo "::error::${label}: expected a swap image (--align greater than 1, no --overwrite-only); found --overwrite-only=${ovr}, --align=${align:-<unset>}"
    echo "::error::${label}: imgtool line: ${cmd}"
    echo "::error::${label}: an overwrite-only image reserves no swap trailer, so a loader built for swap cannot install it - serial recovery and FOTA have to be re-qualified on a deployed card before this ships"
    exit 1
  fi
  echo "image format: ${label}: swap-using-move, signed --align ${align}, no --overwrite-only (swap trailer reserved)"
}

# The loader half of the same invariant, read from MCUboot's own generated .config. This is
# what the standalone Open Bootloader rows publish, and it is the copy that gets programmed
# over SWD once and then left on the card for its lifetime - so it is the half that cannot be
# re-qualified cheaply. It has to implement the swap the images above are signed for.
assert_loader_upgrade_mode() {
  local cfg="$1" label="$2" sym
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_BOOT_SWAP_USING_MOVE=y' "${cfg}" || {
    echo "::error::${label}: BOOT_SWAP_USING_MOVE is not y - this loader does not implement the upgrade the published images are signed for, and a card already carrying the current loader would have to be reflashed over SWD before it could take an update"; exit 1; }
  # Named one at a time rather than checked as "nothing else is set": every one of these is a
  # complete, buildable, bootable upgrade algorithm, so a Kconfig default that moves the choice
  # to one of them yields an image that looks fine everywhere except on a card. Naming them
  # makes the failure say which mode it moved to.
  for sym in SINGLE_APPLICATION_SLOT BOOT_UPGRADE_ONLY BOOT_SWAP_USING_OFFSET \
             BOOT_SWAP_USING_SCRATCH BOOT_DIRECT_XIP BOOT_RAM_LOAD; do
    grep -q "^CONFIG_${sym}=y" "${cfg}" && {
      echo "::error::${label}: CONFIG_${sym}=y alongside BOOT_SWAP_USING_MOVE - the loader upgrade mode changed"; exit 1; }
  done
  echo "upgrade mode: ${label}: swap-using-move"
}

if [ "${BUILD_TYPE}" = "bootloader" ]; then
  # Open Bootloader (standalone MCUboot). Built as the sysbuild MCUboot CHILD image of
  # the example application, NOT via --no-sysbuild, so it goes through NCS's MCUboot
  # image configuration exactly like the loader embedded in a firmware build: same
  # signature type and crypto backend, the same TF-M fragment on /ns targets (sysbuild
  # adds nrf/modules/mcuboot/tfm.conf itself), and the same slot/upgrade mode. The two
  # loaders this CI publishes - the standalone one and the one inside merged.hex -
  # therefore cannot drift apart. The application image is built and thrown away; the
  # workflow collects only build/mcuboot/zephyr/*. MCUboot still runs in the secure
  # domain: sysbuild builds the child image for the secure variant of the board itself.
  #
  # The application is firmware/, this repository's own. It used to be a stock Zephyr
  # sample (samples/basic/blinky) with the ctcc MCUboot configuration COPIED INTO the
  # SDK checkout beside it - which wrote into the user's zephyr/ tree, appended to a
  # file it did not own, never cleaned up, and made the published loader depend on that
  # sample continuing to build for every ctcc target. Using firmware/ removes all of
  # that, and also removes the -DCONFIG_* opt-outs that had to be passed on the command
  # line because a stock sample carries none of this repository's own: firmware/prj.conf
  # and firmware/boards/ have them. Verified equivalent: the loader's generated .config
  # is byte-identical to what the placeholder build produced.
  west build \
    --sysbuild \
    -b "${board}" \
    -d build \
    -p always \
    "${FW_DIR}" \
    -- \
    "${part_overlay_args[@]}" \
    "${cmake_args[@]}"

  ncs_sbom build/mcuboot mcuboot

  assert_approtect     build/mcuboot/zephyr/.config "open_bootloader"
  assert_usb_identity  build/mcuboot/zephyr/.config "open_bootloader" 0x0101
  assert_loader_upgrade_mode build/mcuboot/zephyr/.config "open_bootloader"

elif [ "${BUILD_TYPE}" = "firmware" ]; then
  # Application image built together with MCUboot via sysbuild.
  west build \
    --sysbuild \
    -b "${board}" \
    -d build \
    -p always \
    "${FW_DIR}" \
    -- \
    "${part_overlay_args[@]}" \
    "${cmake_args[@]}"

  # Partition Manager (which used to emit build/merged.hex) is deprecated in
  # NCS and disabled here in favour of DTS-based partitioning. Assemble the
  # single full-flash image (MCUboot + signed application, with TF-M already
  # included in the signed image for *_ns targets) using Zephyr's in-tree
  # mergehex helper, so it does not depend on the Nordic command-line tools.
  python3 "${ZEPHYR_REPO}/scripts/build/mergehex.py" \
    --overlap error \
    -o build/merged.hex \
    build/mcuboot/zephyr/zephyr.hex \
    "build/${IMAGE_NAME}/zephyr/zephyr.signed.hex"

  # SBOM for the application image and the embedded MCUboot. Read from the image
  # directory (IMAGE_NAME), labelled with the artifact name (APP_NAME).
  ncs_sbom "build/${IMAGE_NAME}" "${APP_NAME}"
  ncs_sbom build/mcuboot mcuboot

  assert_approtect     "build/${IMAGE_NAME}/zephyr/.config" "${APP_NAME}"
  assert_usb_identity  "build/${IMAGE_NAME}/zephyr/.config" "${APP_NAME}" 0xF00F
  assert_approtect     build/mcuboot/zephyr/.config "${APP_NAME}:mcuboot"
  assert_usb_identity  build/mcuboot/zephyr/.config "${APP_NAME}:mcuboot" 0x0101
  report_tfm_headroom  "build/${IMAGE_NAME}" "${APP_NAME}"
  assert_loader_upgrade_mode build/mcuboot/zephyr/.config "${APP_NAME}:mcuboot"
  assert_signed_image_format "build/${IMAGE_NAME}/zephyr/.config" \
                             "build/${IMAGE_NAME}/build.ninja" "${APP_NAME}"

else
  # Tests and other standalone applications (built from the current directory).
  #
  # Built with --no-sysbuild deliberately. west enables sysbuild by default, but
  # there is nothing for it to orchestrate here: the assembly test is a single
  # standalone image with no bootloader (it is flashed over SWD, and on nRF52840 it
  # links at 0x0 and replaces the Open Bootloader). Going through sysbuild only
  # bought a BOOTLOADER_NONE image one directory deeper, plus a sysbuild.conf whose
  # SB_CONFIG_PARTITION_MANAGER=n suggested a choice was being made when Partition
  # Manager is a sysbuild concept in the first place. Without sysbuild the image
  # lands in build/zephyr/ and the flash layout comes from devicetree, which is what
  # this build always wanted. On the nRF91 *_ns targets TF-M is still built as part
  # of it, so build/zephyr/tfm_merged.hex is the image to flash.
  # firmware/VERSION is the single source of truth for the boot banner
  # (APP_VERSION_STRING) and the MCUboot image-header version. An application built
  # from its own directory - the assembly test - carries no VERSION, so without this
  # Zephyr generates no app_version.h, the banner falls back to its generic form and
  # the image announces no revision at all. Copied rather than duplicated as a second
  # tracked file, so there is exactly one version to bump.
  # Copied on every build, not only when absent: the installed file is a generated
  # artefact (gitignored), so a copy left by an earlier build must not survive a
  # version bump. Skipping the copy made the image keep reporting the old version -
  # measured, an assembly image announcing 1.2.0 after firmware/VERSION went to 1.3.0 -
  # which is the exact traceability failure this file exists to prevent. Invisible in
  # CI, where every checkout is fresh, and silent for anyone building locally.
  if [ ! -f "${FW_DIR}/VERSION" ]; then
    echo "WARNING: ${FW_DIR}/VERSION not found; '${APP_NAME}' built without an app version" >&2
  elif [ "$(pwd)" != "$(cd "${FW_DIR}" && pwd)" ]; then
    cp -a "${FW_DIR}/VERSION" VERSION
  fi

  west build --no-sysbuild -b "${board}" -p always -- "${cmake_args[@]}"

  ncs_sbom build "${APP_NAME}"

  assert_approtect     build/zephyr/.config "${APP_NAME}"
  assert_usb_identity  build/zephyr/.config "${APP_NAME}" 0xF00F
  report_tfm_headroom  build "${APP_NAME}"
fi
