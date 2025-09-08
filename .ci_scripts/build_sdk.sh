#!/bin/bash

echo "BUILD_TYPE: ${BUILD_TYPE}"

if [ $IFACE = "usb" ]; then
  # PID (applied for targets with USB device)
  echo "CONFIG_USB_DEVICE_PID=0x0101" >> sysbuild/mcuboot.conf
fi

if [ $BUILD_TYPE = "firmware" ] || [ $BUILD_TYPE = "bootloader" ]; then
  # Copy SoC configs
  cp -a ${CTCC_SDK_CONFIGS}/${SOC}/* .
fi

# Build
if [ $NS = true ]; then
	west build -b ${BRD}/${SOC}/ns -p always -- ${BUILD_OPTS}
else
	west build -b ${BRD}/${SOC} -p always -- ${BUILD_OPTS}
fi
