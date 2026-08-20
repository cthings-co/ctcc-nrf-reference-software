# Reference software for CTHINGS.CO nRF Connectivity Cards

This repository consists of reference software compatible with nRF Connect SDK
for firmware development on Connectivity Cards. It relies on the ``ctcc``
board support being available in the Zephyr workspace it is built against.
Please note that the Open Bootloader (MCUboot) built here **verifies application
images against** MCUboot's default development key (`root-ec-p256.pem`,
https://github.com/nrfconnect/sdk-mcuboot), whose private half is public - anyone can
sign an image it accepts, so it is meant for development. The loader image itself is
not signed: nothing verifies a bootloader on these parts, it is what runs first from
flash. This repository points both the loader's verification key and the application's
signing key at that same development key, so an image built here boots on a card
carrying this loader. On
nRF52840 the loader identifies itself over USB as `37a1:0101` (`lsusb -d 37a1:`);
a card whose Open Bootloader verifies a different key rejects images built here,
and flashing this repository's loader over SWD is what makes them usable (see
[Building the Open Bootloader on its own](#building-the-open-bootloader-on-its-own)).
For that, or anything else firmware-production related, please reach out:
support@cthings.co

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

Apply the downstream SDK patches (they add the `ctcc/nrf9151` target and the
board/bootloader fixes on top of what the pinned nRF Connect SDK already ships,
plus the MCUboot serial-recovery config and the boot banner). From the west
workspace root:
```
for p in "$PWD"/ctcc-nrf-reference-software/patches/zephyr/*.patch;   do git -C zephyr           apply "$p"; done
for p in "$PWD"/ctcc-nrf-reference-software/patches/mcuboot/*.patch;  do git -C bootloader/mcuboot apply "$p"; done
```
CI performs this step automatically, in the `apply_patches` helper in
`.github/workflows/build-firmwares.yml` (not in `.ci_scripts/build_sdk.sh`, which
only builds). A patch set that comes out empty fails the job. Note that
`west update` does **not** discard local modifications - it does a
`git checkout --detach` at the pinned revision, so the patches stay applied and must
not be applied a second time. To start over, reset the trees yourself and then re-run
the loops:

```
git -C zephyr reset --hard && git -C zephyr clean -fd
git -C bootloader/mcuboot reset --hard && git -C bootloader/mcuboot clean -fd
```

Build example firmware (nrf52840):
```
cd ctcc-nrf-reference-software/firmware
```

```
west build -p always -b ctcc/nrf52840
```

Build example firmware for non-secure target (nrf9161 or nrf9151):
```
west build -p always -b ctcc/nrf9161/ns     # or: ctcc/nrf9151/ns
```

`-p always` because both commands use the same `build/` directory: without it the
second one reuses the first board's CMake cache and fails. Use distinct `-d` directories
instead if you want to keep both around.

Board-specific application fragments now live in
``firmware/boards/*.conf`` and ``firmware/boards/*.overlay``.

`firmware/` has to be built from inside a west workspace where this repository is a
Zephyr module - which is what the steps above set up. `firmware/prj.conf` assigns
`CONFIG_CTCC_APP_PROTECT`, a symbol this repository's own `drivers/misc/app_protect`
declares, so pointing `west build` at the directory from an unrelated workspace fails
Kconfig rather than silently dropping the opt-out.
They are applied automatically by the Zephyr build system for matching CTCC
targets.

A firmware build produces the application **and** the Open Bootloader: sysbuild is
enabled by default, so `build/mcuboot/zephyr/zephyr.hex` is the loader that
belongs with `build/firmware/zephyr/zephyr.signed.hex`.

### Building the Open Bootloader on its own

The Open Bootloader is MCUboot built as the sysbuild MCUboot *child image* of a
example application, so that it goes through exactly the same image configuration as
the loader inside a firmware build - same signature type, same crypto backend, same
slot mode, and on `/ns` targets the same TF-M fragment. `firmware/sysbuild/mcuboot/`
is picked up automatically, because the application being built is `firmware/` itself.
From the west workspace root:

```
CTCC_REPO="$PWD/ctcc-nrf-reference-software"
cd "$CTCC_REPO/firmware"
BRD=ctcc SOC=nrf52840 NS=false BUILD_TYPE=bootloader \
  bash "$CTCC_REPO/.ci_scripts/build_sdk.sh"
```

The published loader carries **no in-band version**: `firmware/VERSION` reaches the
application's image header and boot banner, not MCUboot, and the `VERSION bump` gate
does not give the loader one either. On nRF52840 the only thing a host can read back is
the CDC ACM product string and `37a1:0101`, which are the same in every release. So
identify a loader by the release archive it came from, not by asking the card - or bump
its product string per release if that matters to you.

The loader is `build/mcuboot/zephyr/zephyr.hex`; the application image is built and
discarded. Use `SOC=nrf9151` or `SOC=nrf9161` with `NS=true` for the nRF91 cards.
Replacing a loader on a card requires SWD - serial recovery only writes the
application slot.

This used to build a stock Zephyr sample as the placeholder and copy
`firmware/sysbuild/mcuboot/` into it, which meant writing into your `zephyr/`
checkout, appending to a file the SDK owns, and leaving both behind. Building
`firmware/` instead needs no copy, touches nothing outside this repository, and gives
a byte-identical loader configuration.

### Assembling a full-flash image (merged.hex)

Partition Manager is disabled, so a plain `west build` does not emit
`merged.hex`. `.ci_scripts/build_sdk.sh` assembles it for `BUILD_TYPE=firmware`
using Zephyr's own helper (no Nordic command-line tools needed); by hand, from
`firmware/` after a build:

```
python3 "$ZEPHYR_BASE/scripts/build/mergehex.py" --overlap error \
  -o build/merged.hex \
  build/mcuboot/zephyr/zephyr.hex \
  build/firmware/zephyr/zephyr.signed.hex
```

On `/ns` targets TF-M is already inside the signed application image, so these two
inputs are the whole flash.

### Flash map

The example uses the flash map from the **board devicetree** - nothing here pins or
overrides it, so this is a stock SDK build. The two SoCs do not share a map, so both
are given here.

nRF52840 (1 MB flash):

```
mcuboot   0x00000..0x12000
image-0   0x12000..0x87000   (slot0, 0x75000)
image-1   0x87000..0xfc000   (slot1, 0x75000)
storage   0xfc000..0x100000
```

nRF9151 / nRF9161 (1 MB flash) - from ``nordic/nrf91xx_partition.dtsi``, which the
ctcc board includes without overriding it. On ``/ns`` targets slot0 is further split
into a secure and a non-secure half (0x40000 / 0x30000) and TF-M occupies the secure
one; the signed image spans both:

```
mcuboot   0x00000..0x10000
image-0   0x10000..0x80000   (slot0, 0x70000)
image-1   0x80000..0xf0000   (slot1, 0x70000)
tfm_ps    0xf0000..0xf4000
tfm_its   0xf4000..0xf6000
tfm_otp   0xf6000..0xf8000
storage   0xf8000..0x100000
```

Both maps use equal slots, which is what MCUboot's swap algorithms want:
``swap_move.c`` accepts primary == secondary (or primary one sector larger) and
``swap_offset.c`` accepts the mirror of that, so equal is the only ratio both take.
Partition Manager is deprecated and off by default in this SDK, hence plain
devicetree partitions.

> **A card flashed from this repository is not interchangeable with a
> factory-flashed one**, in either direction.
>
> Two independent things differ, and either one alone is enough to stop a
> cross-flash. The images built here are signed with MCUboot's public development key
> (above), so a loader that verifies any other key rejects them at signature
> verification - and equally, a loader built here rejects an image not signed with
> that development key. Separately, the flash layout here is whatever the pinned
> SDK's devicetree specifies: the table above is this repository's map, and nothing
> guarantees a card arrived carrying the same one. Where the two disagree about where
> slot0 begins, serial recovery writes to the wrong place.
>
> The consequence does not depend on knowing which of the two applies to a given
> card: **do not serial-recover across that boundary in either direction.** Flash the
> full ``merged.hex`` from this repository over SWD once, and everything from then on
> is self-consistent. To return a card to its factory firmware, contact
> support@cthings.co.
>
> One change in this release also affects cards flashed from an **earlier release of
> this repository**, on nRF52840 only: `image-0` is now 0x75000 (was 0x76000) and
> `image-1` starts at 0x87000 (was 0x88000), so that the two slots are equal - MCUboot's
> swap requires that, and the previous pair was rejected by `boot_slots_compatible()`.
> `boot_partition`, slot0's **origin** and `storage` are unchanged, so an image built
> here still boots and still serial-recovers to the same address; only a DFU that goes
> *through slot1* on a card carrying the older loader is affected. Reflashing
> ``merged.hex`` over SWD once resolves it. Nothing else moved: the nRF91 `storage`
> partition is deliberately pinned to the geometry earlier releases produced.

The one build-level overlay that *is* applied for nRF52840, to both the application
and the MCUboot child image, is ``firmware/ctcc_nrf52840_uicr.overlay``: it sets
``gpio-as-nreset`` so the card can be reset over the mPCIe/M.2 PERST# line, and it
goes to the loader too because a card that has only ever run the standalone loader
would otherwise have no PERST reset until an application boots once. Pass it as
``-DEXTRA_DTC_OVERLAY_FILE`` and ``-Dmcuboot_EXTRA_DTC_OVERLAY_FILE`` for a manual
``west build``; the overlay header shows the exact command. Without it, a plain
``west build`` still gives the *application* ``gpio-as-nreset``
(``firmware/boards/ctcc_nrf52840.overlay``) but leaves the loader without it.

``gpio-as-nreset`` is not a hex record: it makes the MDK write ``UICR->PSELRESET``
and reset once, on the first boot of an image that carries it - so expect one extra
reboot the first time a fresh card runs such an image. On nRF91 the reset pin is not
configurable this way, so no overlay applies there.

### MCUboot configuration

``firmware/sysbuild.conf`` asks for MCUboot and nothing else, so the upgrade mode is
the SDK default (``SB_CONFIG_MCUBOOT_MODE_SWAP_USING_MOVE``): two slots, with an
update installed into the secondary and swapped in on the next boot. Serial recovery
writes the primary slot directly and works the same either way, which is what the
loading procedure below uses.

What the loader itself contains is configured in ``firmware/sysbuild/mcuboot/`` -
serial recovery over USB CDC ACM on nRF52840 and over UART on nRF91, plus the CTCC
USB descriptors. sysbuild picks that directory up automatically as the MCUboot
image's application configuration directory (it does this for any
``<app>/sysbuild/<image>/``), and it *replaces* - does not merge with - MCUboot's
own ``prj.conf`` and ``boards/`` directory. The corollary is that anything the
loader needs must live under ``firmware/``.

Product firmware may want to deviate from all of this - a single-slot loader saves
the ~4 KB of swap machinery, and a pinned flash map keeps compatibility with cards
already in the field. Neither belongs in an example.

To load the produced firmware over Open Bootloader, please install `smpmgr`:
```
pip install smpmgr
```
for more details about `smpmgr` please reach out to: https://github.com/intercreate/smpmgr

Which port to use depends on the card, because the two families expose serial
recovery over different hardware:

* **nRF52840** - the loader brings up its own USB CDC ACM
  (`CONFIG_MCUBOOT_SERIAL` over USB), so the port is a `/dev/ttyACM*` that appears
  and disappears with the loader, `37a1:0101` for the open-key build.
* **nRF9151 / nRF9161** - the loader uses UART
  (`CONFIG_BOOT_SERIAL_UART=y` in `firmware/sysbuild/mcuboot/boards/ctcc_nrf91*.conf`)
  routed through the on-board USB-UART converter, so the port is a `/dev/ttyUSB*`
  at **115200** baud and is present whether the loader or the application is
  running.

Loading firmware procedure (`/dev/ttyACM0` below is the nRF52840 case - use your
card's port from the list above):

* By default Open Bootloader waits for 5 seconds for any prompt from `smpmgr` then it proceeds to load firmware image
* Upon powering up the device (or after a reset) issue: `smpmgr --mtu 132 --port /dev/ttyACM0 image state-read`, to get a list of available images (on factory defult the list should be empty). This command will also stop the Bootloader from booting further
* To load produced firmware: `smpmgr --mtu 132 --port /dev/ttyACM0 image upload build/firmware/zephyr/zephyr.signed.bin`
* See if the image has been loaded (there should be one image on the list): `smpmgr --mtu 132 --port /dev/ttyACM0 image state-read`
* Reboot the device to boot into image: `smpmgr --mtu 132 --port /dev/ttyACM0 os reset`
 
After rebooting, the device will enter Bootloader again, wait 5 seconds and then it should boot the loaded firmware. To check the result, try to connect to the console e.g. using `picocom`: `sudo picocom -b 115200 /dev/ttyACM0` (or the `/dev/ttyUSB*` port on an nRF91 card).

If you want to flash whole bootloader + image through e.g. external debugger, please install `nrfjprog` (https://docs.nordicsemi.com/bundle/ug_gsg_ses/page/UG/gsg/install_nrf_command_line_tools.html). The combined `firmware/build/merged.hex` (Open Bootloader + signed application) is assembled by the CI build script (`.ci_scripts/build_sdk.sh`, which runs Zephyr's `scripts/build/mergehex.py`); a plain `west build` does not emit it, because Partition Manager is disabled - see [Assembling a full-flash image](#assembling-a-full-flash-image-mergedhex) for the command to run it by hand. Run following commands:

* `nrfjprog --recover -f nrf52` (or nrf91)
* `nrfjprog --program firmware/build/merged.hex --sectorerase --verify -f nrf52` (or nrf91)

### Verifying a download

CI publishes checksums alongside the images, so a download can be checked before
anything is flashed. Every firmware's artifact directory carries a `SHA256SUMS`
covering all of its files (images and SBOM), and the packaged archive is published
with a `.zip.sha256` beside it.

The workflow also reads them back before packaging - `.ci_scripts/verify_checksums.sh`
re-checks every `SHA256SUMS` in the downloaded artifact tree and fails the release
rather than publish a set that does not match, or a directory whose files are not
all covered - so a mismatch on your download points at the download, not the build:

```
sha256sum -c ctcc-firmwares-<tag>.zip.sha256
unzip ctcc-firmwares-<tag>.zip
cd nrf9151-firmware && sha256sum -c SHA256SUMS
```

## Assembly test

`tests/assembly/` is the production-line qualification image: a ztest application
that exercises the card's own hardware - GPIO, its console (USB CDC ACM on
nRF52840, `uart0` on nRF91), and on the **nRF91 targets only** the external flash
over SPI. The flash tests are compiled in by `CONFIG_SPI_NOR`
(`target_sources_ifdef` in `tests/assembly/CMakeLists.txt`), which
`boards/ctcc_nrf9151_ns.conf` and `boards/ctcc_nrf9161_ns.conf` set and the
nRF52840 board conf does not, so an nRF52840 run does not qualify the flash part.
It is **not** an application to ship - it is a bring-up tool, and it is
deliberately built and flashed differently from the firmware:

```
cd ctcc-nrf-reference-software/tests/assembly
west build --no-sysbuild -b ctcc/nrf52840   # or: ctcc/nrf9151/ns , ctcc/nrf9161/ns
```

* It is a single standalone image: `--no-sysbuild`, no bootloader, flash layout
  straight from devicetree. Outputs land in `build/zephyr/`. (CI builds it the same
  way - see `.ci_scripts/build_sdk.sh`.)
* It is built **without** MCUboot, so it must be flashed over **SWD**; it cannot
  be loaded through an installed Open Bootloader.
* On **nRF52840** the image links at flash origin 0x0 (the board only selects
  `USE_DT_CODE_PARTITION` for the `/ns` nRF91 targets), so flashing it
  **overwrites the Open Bootloader**. Reflash a loader afterwards - see
  [Building the Open Bootloader on its own](#building-the-open-bootloader-on-its-own).
* On **nRF9151 / nRF9161** the flashable file is `build/zephyr/tfm_merged.hex`
  (TF-M plus the non-secure image). `zephyr.hex` alone is the non-secure half and
  does not boot. Nothing is placed at 0x0 by this build, so a loader already on the
  card survives - and will not find a valid image, because this one is not
  MCUboot-signed and does not sit where the loader looks. **Erase it first**, which
  also leaves the card in the same state the nRF52840 note above describes:

  ```
  nrfjprog --recover -f nrf91          # or --chiperase
  nrfjprog --program build/zephyr/tfm_merged.hex --sectorerase --verify -f nrf91
  ```

  Reflash a loader afterwards if the card needs one - see
  [Building the Open Bootloader on its own](#building-the-open-bootloader-on-its-own).
* It deliberately does **not** lock the debug port (`tests/assembly/prj.conf`), so
  a card that has run the assembly test can still be programmed without
  `nrfjprog --recover`. So does every other image in this repository - nothing
  built here locks a card; see
  [Software considerations](#software-considerations).
* Console: on nRF52840 it appears as USB `37a1:f00f` "CTCC-ASSEMBLY"; on nRF91 it
  is `uart0` through the on-board USB-UART converter at 115200.

## Software considerations

* The Open Bootloader built here uses the `root-ec-p256.pem` development key
  (https://github.com/nrfconnect/sdk-mcuboot/blob/main/root-ec-p256.pem), and this
  repository selects it automatically for both the loader and the application, so
  images built here boot on cards flashed from here. A card whose Open Bootloader
  verifies a different key rejects them; check the loader's USB identity as
  described at the top of this README.
* **Nothing built here locks the debug port**, so a card stays reprogrammable over
  SWD without `nrfjprog --recover`. The ctcc board *defaults the
  `NRF_APPROTECT_HANDLING` choice to `NRF_APPROTECT_LOCK`* for every image
  (`patches/zephyr/0003`) - a choice **default**, which a `.conf` can override, not a
  `select`, which it could not. Left alone it would lock APPROTECT on first boot by up
  to three independent paths: the MDK's `SystemInit()` (the SDK compiles it with
  `ENABLE_APPROTECT`, a volatile per-boot FORCEPROTECT), the
  `drivers/misc/app_protect` SYS_INIT helper, which writes UICR.APPROTECT and resets,
  and on the `/ns` targets TF-M, which writes both UICR words permanently and is the
  *only* actor there, because the helper is excluded from a non-secure image and the
  NS image's own `SystemInit` never runs the handler.
  Every image built here opts out, on **both** of nRF91's access ports:
  `CONFIG_NRF_APPROTECT_USE_UICR=y` selects the SoC's default handling for the first
  port, `CONFIG_CTCC_APP_PROTECT=n` keeps the helper out of the image, and
  `CONFIG_NRF_SECURE_APPROTECT_USE_UICR=y` does the same for nRF91's *second*, secure
  port. That last symbol is declared for every Nordic SoC but depends on
  `SOC_NRF5340_CPUAPP || SOC_SERIES_NRF91`, so assigning it on nRF52840 would only log
  a Kconfig warning - which is why it lives in the per-board fragments rather than
  beside the other two. That is nine matrix images plus the
  MCUboot child of each firmware build - see `firmware/prj.conf`,
  `firmware/boards/ctcc_nrf91*_ns.conf`, `firmware/sysbuild/mcuboot/prj.conf`,
  `firmware/sysbuild/mcuboot/boards/ctcc_nrf91*.conf`, `tests/assembly/prj.conf` and
  `tests/assembly/boards/ctcc_nrf91*_ns.conf`. That is deliberate for a development reference signed
  with MCUboot's public key - locking would protect nothing while making the card
  awkward to work with. **Production firmware must lock**, on the bootloader as well
  as the application; do that in your product repository.
* Open Bootloader delivered on stock nRF52840 Card does not support PERST on mPCIe/M.2, in order to reboot the card after flashing over `smpmgr`, the `reset` command has to be issued.
* This repository sets `gpio-as-nreset` for nRF52840 Cards, so images built here
  support PERST. Built through `.ci_scripts/build_sdk.sh` that covers **both** the
  application and the Open Bootloader (`firmware/ctcc_nrf52840_uicr.overlay`); a
  plain `west build` configures it for the application only
  (`firmware/boards/ctcc_nrf52840.overlay`), which means a card running just the
  standalone loader still has no PERST. Either way the pin is configured by a
  one-time UICR write on first boot, which costs one extra reset.
* The Open Bootloader can only be identified over USB on nRF52840, where it brings
  up its own CDC ACM - `37a1:0101` for the loader built here. On nRF9151/nRF9161
  Cards it cannot: the Card exposes an on-board USB-UART converter whose USB
  identity does not change when the loader hands over, so USB alone never tells you
  whether the loader or the application is running. The practical indicator is that
  `smpmgr` commands stop being answered once an image has been booted.
