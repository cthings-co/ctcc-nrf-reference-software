# Copyright (c) 2024-2026 CTHINGS.CO
# SPDX-License-Identifier: Apache-2.0

# This CMake file is picked by the Zephyr build system because it is defined
# as the module CMake entry point (see zephyr/module.yml).

# The boot banner prints the firmware revision straight from the application
# version (APP_VERSION_STRING, from <zephyr/app_version.h>) - see
# patches/zephyr/0001-kernel-banner-.... Zephyr derives that from the
# application's VERSION file (firmware/VERSION for the reference application),
# which is also what imgtool stamps into the MCUboot image header
# (CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION), so the banner and the image version can
# no longer disagree. Nothing to wire up here.

add_subdirectory(drivers)
