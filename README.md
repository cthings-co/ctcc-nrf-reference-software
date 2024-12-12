# Reference software for CTHINGS.CO nRF Connectivity Cards

This repository consists of Reference Software compatible with nrf-sdk and all board files which are needed
for firmware development on Connectivity Cards. Please note, that Open Bootloader (MCUboot) which is delivered with nRF
Connectivity Cards is meant only for development as the root certificate for signing binaries is public (https://github.com/nrfconnect/sdk-mcuboot).
For more information how to make the firmware production ready please reach out: support@cthings.co

## Preparing development environment

These instructions assume you know how to setup nrf-sdk (Zephyr RTOS) environment, for more information please see: https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/installation.html and Getting Started guide: https://docs.zephyrproject.org/latest/develop/getting_started/index.html

On Linux machine:
```
mkdir project && cd project
```

```
west init -m https://github.com/cthings-co/ctcc-nrf-reference-software
```

```
west update
```

Remove board files from the main Zephyr repository to avoid duplicates with this repository:
```
rm -rf zephyr/boards/ct/ctcc
```


Copy `pm_static.yml` and `sysbuild` files to configure your application to be compatible with the Open Bootloader:
```
cp -r ctcc-nrf-reference-software/boards/ct/ctcc/nrf-sdk/<soc>/* ctcc-nrf-reference-software/firmware/
```

Build example firmware (nrf52840):
```
cd ctcc-nrf-reference-software/firmware
```

```
west build -b ctcc/nrf52840
```

Build example firmware for non-secure target (nrf9161):
```
west build -b ctcc/nrf9161/ns
```

To load the produced firmware over Open Bootloader, please install `smpmgr`:
```
pip install smpmgr
```
for more details about `smpmgr` please reach out to: https://github.com/intercreate/smpmgr

Loading firmware procedure:

* By default Open Bootloader waits for 5 seconds for any prompt from `smpmgr` then it proceeds to load firmware image
* Upon powering up the device (or after a reset) issue: `smpmgr --mtu 128 --port /dev/ttyACM0 image state-read`, to get a list of available images (on factory defult the list should be empty). This command will also stop the Bootloader from booting further
* To load produced firmware: `smpmgr --mtu 128 --port /dev/ttyACM0 image upload build/firmware/zephyr/zephyr.signed.bin`
* See if the image has been loaded (there should be one image on the list): `smpmgr --mtu 128 --port /dev/ttyACM0 image state-read`
* Reboot the device to boot into image: `smpmgr --mtu 128 --port /dev/ttyACM0 os reset`
 
After rebooting, the device will enter Bootloader again, wait 5 seconds and then it should boot the loaded firmware. To check the result, try to connect to the console e.g. using `picocom`: `sudo picocom -b 115000 /dev/ttyACM0`.

If you want to flash whole bootloader + image through e.g. external debugger, please install `nrfjprog` (https://docs.nordicsemi.com/bundle/ug_gsg_ses/page/UG/gsg/install_nrf_command_line_tools.html). Run following commands:

* `nrfjprog --recover -f nrf52` (or nrf91)
* `nrfjprog --program build/merged.hex --sectorerase --verify -f nrf52` (or nrf91)

## Software considerations

* By default Open Bootloader (MCUboot) is delievered with `root-ec-p256.pem` public certificate (https://github.com/nrfconnect/sdk-mcuboot/blob/main/root-ec-p256.pem), in order to make your application work, you should use the same certificate to sign your binary - in this repository correct certificate is automatically selected.
* Open Bootloader delivered on stock nRF52840 Card does not support PERST on mPCIe/M.2, in order to reboot the card after flashing over `smpmgr`, the `reset` command has to be issued.
* This repository by default sets `gpio-as-nreset` for nRF52840 Cards, therefore the application built within this repository will have a support for PERST.
* Open Bootloader can be only identified on USB on nRF52840 which has PID=0101. For nRF9161 Cards it is not possible, because the Card has on-board USB-UART converter, in the result it's not possible to say when Open Bootloader switches to application based on logs from USB. The indicator that may suggest that Bootloader booted an image is when it's not possible to issue `smpmgr` commands.
