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

# Fail on a missing variable BEFORE building, not after. APP_NAME is only read after
# the image is built and signed (the mergehex call and the SBOM label), so under
# `set -u` a by-hand firmware build used to run to completion and then abort on the
# last few lines. Default it to the application directory's name - which is what the
# workflow passes anyway - and check the rest up front.
APP_NAME="${APP_NAME:-$(basename "${FW_DIR}")}"
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
# SPDX document. Best-effort: never fail the build over SBOM generation.
# (Zephyr's `west spdx` is intentionally not used - it does not support
# sysbuild; see https://github.com/zephyrproject-rtos/zephyr/issues/105917.)
ncs_sbom() {
  local img="$1" label="$2"
  if [ ! -f "${img}/zephyr/zephyr.elf" ]; then
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
    echo "ncs-sbom: wrote ${SBOM_DIR}/${label}.sbom.{html,spdx}"
  else
    echo "::warning::west ncs-sbom failed for ${img}"
  fi
}

# Defensive scrub: an SBOM must never carry embedded credentials. west ncs-sbom's
# git-info detector records each source's remote via `git remote get-url`. GitHub's
# actions/checkout keeps the token in .git/config's extraheader (not the remote
# URL), so a clean checkout does not leak here - but redact any "user:secret@host"
# userinfo from the generated SBOMs as belt-and-suspenders (e.g. if a PAT is ever
# embedded in a remote), then fail closed if a credential still remains.
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
    "build/${APP_NAME}/zephyr/zephyr.signed.hex"

  # SBOM for the application image and the embedded MCUboot.
  ncs_sbom "build/${APP_NAME}" "${APP_NAME}"
  ncs_sbom build/mcuboot mcuboot

  assert_approtect     "build/${APP_NAME}/zephyr/.config" "${APP_NAME}"
  assert_usb_identity  "build/${APP_NAME}/zephyr/.config" "${APP_NAME}" 0xF00F
  assert_approtect     build/mcuboot/zephyr/.config "${APP_NAME}:mcuboot"
  assert_usb_identity  build/mcuboot/zephyr/.config "${APP_NAME}:mcuboot" 0x0101

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
fi

# Redact any credential that a tokenized git remote may have leaked into the
# SBOMs, and fail the build if one survives.
scrub_sbom_credentials
