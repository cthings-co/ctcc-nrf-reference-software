#!/bin/bash
set -euo pipefail

echo "BUILD_TYPE: ${BUILD_TYPE}"

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FW_DIR="${REPO_ROOT}/firmware"

ZEPHYR_REPO="${ZEPHYR_REPO:-${REPO_ROOT}/../zephyr}"

#
#
if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
  if [ ! -d "${ZEPHYR_SDK_INSTALL_DIR}" ]; then
    echo "::error::ZEPHYR_SDK_INSTALL_DIR=${ZEPHYR_SDK_INSTALL_DIR} does not exist - the CI image supplies the Zephyr SDK, so this usually means the image pin moved and the SDK path did not"
    exit 1
  fi
  sdk_want=""
  if [ -f "${ZEPHYR_REPO}/SDK_VERSION" ]; then
    sdk_want="$(tr -d '[:space:]' < "${ZEPHYR_REPO}/SDK_VERSION")"
  fi
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

APP_NAME="${APP_NAME:-$(basename "${FW_DIR}")}"

IMAGE_NAME="${IMAGE_NAME:-${APP_NAME}}"
: "${BUILD_TYPE:?BUILD_TYPE must be set (firmware | bootloader | test)}"
: "${BRD:?BRD must be set (e.g. ctcc)}"
: "${SOC:?SOC must be set (e.g. nrf52840, nrf9151, nrf9161)}"
: "${NS:?NS must be set (true for the /ns board variant, false otherwise)}"

#
#
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

SBOM_DIR="build/sbom"
SBOM_DETECTORS="spdx-tag,full-text,external-file,git-info"

cmake_args=()
if [ -n "${BUILD_OPTS:-}" ]; then
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

if [ "${CI_ARTIFACT_SANITIZATION:-0}" = 1 ]; then
  cmake_args+=(-DCONFIG_BUILD_OUTPUT_STRIP_PATHS=y)
fi

if [ "${NS}" = true ]; then
  board="${BRD}/${SOC}/ns"
else
  board="${BRD}/${SOC}"
fi

#
#
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
  if west ncs-sbom -d "${img}" \
      --license-detectors "${SBOM_DETECTORS}" --optional-license-detectors '' \
      --output-html "${SBOM_DIR}/${label}.sbom.html" \
      --output-spdx "${SBOM_DIR}/${label}.sbom.spdx" \
      2> >(grep -vE 'fatal: not a git repository|does not provide valid git remote information|Command "git" reported errors' >&2); then
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

#
scrub_sbom_credentials() {
  [ -d "${SBOM_DIR}" ] || return 0
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
trap 'scrub_sbom_credentials || true' EXIT


#
assert_approtect() {
  local cfg="$1" label="$2" expect="${3:-${APPROTECT_EXPECT:-open}}" nrf91=n ns=n
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_ARM_NONSECURE_FIRMWARE=y' "${cfg}" && ns=y
  case "${SOC}" in nrf91*) nrf91=y ;; esac

  case "${expect}" in
  lock)
    grep -q '^CONFIG_NRF_APPROTECT_LOCK=y' "${cfg}" || {
      echo "::error::${label}: NRF_APPROTECT_LOCK is not y - this image would ship with an open debug port"; exit 1; }
    if [ "${nrf91}" = y ]; then
      grep -q '^CONFIG_NRF_SECURE_APPROTECT_LOCK=y' "${cfg}" || {
        echo "::error::${label}: NRF_SECURE_APPROTECT_LOCK is not y on nRF91 - the secure access port would stay open"; exit 1; }
    fi
    if [ "${ns}" = n ]; then
      grep -q '^CONFIG_CTCC_APP_PROTECT=y' "${cfg}" || {
        echo "::error::${label}: CTCC_APP_PROTECT is not y in a secure image - nothing writes UICR, so the lock would last only until the next boot"; exit 1; }
    fi
    echo "approtect: ${label}: locked"
    ;;
  open)
    grep -q '^CONFIG_NRF_APPROTECT_USE_UICR=y' "${cfg}" || {
      echo "::error::${label}: NRF_APPROTECT_USE_UICR is not y - the reference image does not explicitly select open APPROTECT handling"; exit 1; }
    if [ "${nrf91}" = y ]; then
      grep -q '^CONFIG_NRF_SECURE_APPROTECT_USE_UICR=y' "${cfg}" || {
        echo "::error::${label}: NRF_SECURE_APPROTECT_USE_UICR is not y - the nRF91 reference image does not explicitly select open secure-APPROTECT handling"; exit 1; }
    fi

    grep -q '^CONFIG_CTCC_APP_PROTECT=y' "${cfg}" && {
      echo "::error::${label}: CTCC_APP_PROTECT=y in an image that must stay debuggable - it would write UICR.APPROTECT"; exit 1; }
    grep -q '^CONFIG_NRF_APPROTECT_LOCK=y' "${cfg}" && {
      echo "::error::${label}: NRF_APPROTECT_LOCK=y in an image that must stay debuggable"; exit 1; }
    grep -q '^CONFIG_NRF_SECURE_APPROTECT_LOCK=y' "${cfg}" && {
      echo "::error::${label}: NRF_SECURE_APPROTECT_LOCK=y in an image that must stay debuggable - TF-M would write UICR.SECUREAPPROTECT on its first boot"; exit 1; }
    echo "approtect: ${label}: open, as a reference image must be"
    ;;
  *)
    echo "::error::${label}: invalid APPROTECT expectation '${expect}' (expected open or lock)"
    exit 1
    ;;
  esac
}

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

#
#
#
#
#
TFM_HEADROOM_MIN=1024
report_tfm_headroom() {
  local dir="$1" label="$2" axf="" c
  case "${SOC}" in nrf91*) ;; *) return 0 ;; esac
  for c in "${dir}/tfm/bin/tfm_s.axf" "${dir}/tfm/api_ns/bin/tfm_s.axf"; do
    [ -f "${c}" ] && { axf="${c}"; break; }
  done
  [ -n "${axf}" ] || return 0
  local failed="::warning::${label}: could not measure TF-M headroom from ${axf}"
  python3 - "${axf}" "${label}" "${TFM_HEADROOM_MIN}" <<'PYEOF' || echo "${failed}"
import re, struct, sys

path, label, min_free = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = open(path, "rb").read()
if d[:4] != b"\x7fELF":
    print(f"::warning::{label}: {path} is not an ELF file, not measuring TF-M headroom")
    sys.exit(0)
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
below = [(a, s) for a, s, _nm in placed if a < anchor]
if not below:
    print(f"tfm headroom: {label}: nothing placed below the veneer anchor {anchor:#x}")
    sys.exit(0)
code_end = max(a + s for a, s in below)
free = anchor - code_end
content = sum(s for _a, s in below) + veneer[1]
print(f"tfm headroom: {label}: {content} B of content, code+rodata ends {code_end:#x},"
      f" CMSE veneers anchored {anchor:#x} -> {free} B free below the anchor")

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

#
#
#
assert_image_version() {
  local version_file="$1" cfg="$2" ninja="$3" image="$4" label="$5"
  local key value expected configured
  local -a parts=() values=() configured_values=() command_versions=()

  [ -f "${version_file}" ] || {
    echo "::error::${label}: ${version_file} is missing; cannot determine the image version"; exit 1; }
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  [ -f "${ninja}" ] || {
    echo "::error::${label}: no ${ninja}; cannot verify the imgtool version argument"; exit 1; }
  [ -f "${image}" ] || {
    echo "::error::${label}: no signed image at ${image}; cannot verify its header version"; exit 1; }

  for key in VERSION_MAJOR VERSION_MINOR PATCHLEVEL VERSION_TWEAK; do
    mapfile -t values < <(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\\1/p" "${version_file}")
    if [ "${#values[@]}" -ne 1 ] || [ "${values[0]}" -gt 255 ]; then
      echo "::error::${label}: ${version_file} must contain one ${key} in the range 0..255"; exit 1
    fi
    parts+=("${values[0]}")
  done
  expected="${parts[0]}.${parts[1]}.${parts[2]}+${parts[3]}"

  mapfile -t configured_values < <(sed -nE 's/^CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION="([^"]*)"$/\1/p' "${cfg}")
  if [ "${#configured_values[@]}" -ne 1 ]; then
    echo "::error::${label}: ${cfg} has no unique CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION"; exit 1
  fi
  configured="${configured_values[0]}"
  if [ "${configured}" != "${expected}" ]; then
    echo "::error::${label}: CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION=${configured}, expected ${expected} from ${version_file}"; exit 1
  fi

  mapfile -t command_versions < <(awk 'match($0, /imgtool(\.py)?[ ]+sign[^&|]*/) {
    command = substr($0, RSTART, RLENGTH)
    if (match(command, /--version[[:space:]]+[^[:space:]]+/)) {
      value = substr(command, RSTART, RLENGTH)
      sub(/^--version[[:space:]]+/, "", value)
      print value
    }
  }' "${ninja}")
  if [ "${#command_versions[@]}" -eq 0 ]; then
    echo "::error::${label}: no imgtool --version argument found in ${ninja}"; exit 1
  fi
  for value in "${command_versions[@]}"; do
    if [ "${value}" != "${expected}" ]; then
      echo "::error::${label}: imgtool signs with ${value}, expected ${expected} from ${version_file}"; exit 1
    fi
  done

  python3 - "${image}" "${expected}" "${label}" <<'PYEOF'
from pathlib import Path
from struct import unpack_from
import sys

path, expected, label = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    with path.open("rb") as image_file:
        data = image_file.read(28)
except OSError as error:
    print(f"::error::{label}: cannot read {path}: {error}", file=sys.stderr)
    sys.exit(1)

if len(data) < 28:
    print(f"::error::{label}: {path} is too short for an MCUboot image header", file=sys.stderr)
    sys.exit(1)
if unpack_from("<I", data, 0)[0] != 0x96F3B83D:
    print(f"::error::{label}: {path} does not begin with an MCUboot image header", file=sys.stderr)
    sys.exit(1)

major, minor, revision, build = unpack_from("<BBHI", data, 20)
actual = f"{major}.{minor}.{revision}+{build}"
if actual != expected:
    print(f"::error::{label}: signed image header is {actual}, expected {expected}", file=sys.stderr)
    sys.exit(1)
print(f"image version: {label}: {actual}")
PYEOF
}

assert_signed_image_format() {
  local cfg="$1" ninja="$2" label="$3" cmd="" align="" ovr=n
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_PARTITION_MANAGER_ENABLED=y' "${cfg}" && {
    echo "::error::${label}: PARTITION_MANAGER_ENABLED=y - this build partitions from devicetree, and the Partition Manager branch of image_signing.cmake signs with a different command line"; exit 1; }
  grep -q '^CONFIG_MCUBOOT_BOOTLOADER_MODE_SWAP_USING_MOVE=y' "${cfg}" || {
    echo "::error::${label}: MCUBOOT_BOOTLOADER_MODE_SWAP_USING_MOVE is not y - the upgrade mode is no longer the one the published loaders implement"; exit 1; }

  [ -f "${ninja}" ] || {
    echo "::error::${label}: no ${ninja} - cannot read the imgtool command line the build generated"; exit 1; }
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

assert_loader_upgrade_mode() {
  local cfg="$1" label="$2" sym
  [ -f "${cfg}" ] || { echo "::error::${label}: no .config at ${cfg}"; exit 1; }
  grep -q '^CONFIG_BOOT_SWAP_USING_MOVE=y' "${cfg}" || {
    echo "::error::${label}: BOOT_SWAP_USING_MOVE is not y - this loader does not implement the upgrade the published images are signed for, and a card already carrying the current loader would have to be reflashed over SWD before it could take an update"; exit 1; }
  for sym in SINGLE_APPLICATION_SLOT BOOT_UPGRADE_ONLY BOOT_SWAP_USING_OFFSET \
             BOOT_SWAP_USING_SCRATCH BOOT_DIRECT_XIP BOOT_RAM_LOAD; do
    grep -q "^CONFIG_${sym}=y" "${cfg}" && {
      echo "::error::${label}: CONFIG_${sym}=y alongside BOOT_SWAP_USING_MOVE - the loader upgrade mode changed"; exit 1; }
  done
  echo "upgrade mode: ${label}: swap-using-move"
}

if [ "${BUILD_TYPE}" = "bootloader" ]; then
  #
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
  west build \
    --sysbuild \
    -b "${board}" \
    -d build \
    -p always \
    "${FW_DIR}" \
    -- \
    "${part_overlay_args[@]}" \
    "${cmake_args[@]}"

  python3 "${ZEPHYR_REPO}/scripts/build/mergehex.py" \
    --overlap error \
    -o build/merged.hex \
    build/mcuboot/zephyr/zephyr.hex \
    "build/${IMAGE_NAME}/zephyr/zephyr.signed.hex"

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
  assert_image_version "${FW_DIR}/VERSION" "build/${IMAGE_NAME}/zephyr/.config" \
                       "build/${IMAGE_NAME}/build.ninja" \
                       "build/${IMAGE_NAME}/zephyr/zephyr.signed.bin" "${APP_NAME}"

else
  #
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
