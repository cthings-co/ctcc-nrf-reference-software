# Contributing

Thanks for considering a contribution. This repository is Apache-2.0 licensed
(see [LICENSE](LICENSE)) and takes pull requests.

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by` line naming its author:

```
Signed-off-by: Your Name <your.email@example.com>
```

`git commit -s` adds it for you. By signing off you certify the
[Developer Certificate of Origin](https://developercertificate.org/) 1.1 - in
short, that you wrote the change or otherwise have the right to submit it under
this repository's licence.

CI checks this on every pull request (`DCO sign-off`). The trailer has to match
either the commit's author or its committer address; a missing or unrelated
sign-off fails the check. To fix a branch that is already pushed:

```
git rebase --signoff <base>      # add the trailer to every commit in the range
git push --force-with-lease
```

## Bump `firmware/VERSION`

`firmware/VERSION` is a Zephyr-style version file and the single source of truth
for two things: the boot banner (`APP_VERSION_STRING`) and the MCUboot
image-header version (`CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION`). Two images that
report the same revision cannot be told apart once they are on a card, so any
pull request that can change a built image must raise it.

CI enforces this (`VERSION bump`). Documentation-only pull requests are exempt -
the check skips when nothing under `firmware/`, `drivers/`, `dts/`, `patches/`,
`tests/`, `.ci_scripts/`, `.github/`, `Kconfig`, `CMakeLists.txt`,
`zephyr/module.yml` or `west.yml` changed, and also when the only changes there are
whitespace, Markdown or `LICENSE`.

A bump means raising one of `VERSION_MAJOR`, `VERSION_MINOR`, `PATCHLEVEL` or
`VERSION_TWEAK`. `EXTRAVERSION` on its own does **not** count: imgtool signs with
`major.minor.patch+tweak`, so an `EXTRAVERSION`-only edit leaves every image header
byte-identical to the previous release's, which is the condition this check exists to
prevent. Adding the file counts as a bump.

## Changing files under `patches/`

The `patches/` files are `git format-patch` output applied to the pinned nRF
Connect SDK trees, and they carry blob indices. **Never hand-edit them.**
Regenerate instead:

Run this from the **west workspace root** (the directory containing `zephyr/`,
`bootloader/`, `nrf/` and your clone of this repository), and note that `CTCC` is an
absolute path:

```
CTCC="$PWD/ctcc-nrf-reference-software"            # absolute: see the third bullet

git -C zephyr checkout -b tmp                      # pinned revision, clean tree
git -C zephyr am "$CTCC"/patches/zephyr/*.patch    # apply the current series, in order
# ... edit the source, then amend or add commits ...
rm "$CTCC"/patches/zephyr/*.patch                  # replace the set, do not merge into it
git -C zephyr format-patch --filename-max-length=128 \
    -o "$CTCC/patches/zephyr" <base>
```

The MCUboot series is the same with `git -C bootloader/mcuboot` and
`patches/mcuboot/`.

Three details in that recipe are load-bearing, and skipping any of them produces a
directory that no longer applies:

* **`--filename-max-length=128`.** The committed names are `format-patch` output at
  that length. At the default 64 it truncates them - this repository's longest name,
  `0002-boards-ct-ctcc-add-nRF9151-target-and-backport-DK-dongle-improvements.patch`,
  comes out as `0002-boards-ct-ctcc-add-nRF9151-target-and-backport-DK-do.patch` - so
  the regenerated files land beside the originals instead of
  replacing them, and the series ends up applied twice.
* **Absolute paths.** `git -C zephyr` changes directory *before* interpreting the rest
  of the command line, so a relative patch path is resolved against `zephyr/`, not
  against your shell's cwd. `git -C zephyr am patches/zephyr/*.patch` therefore fails
  with "can't open patch" even though the glob looks right from where you typed it.
* **Delete the old files first.** `format-patch` numbers its output from 0001 and knows
  nothing about what is already there. If a commit subject changed, or a patch was added
  or removed, the new names differ and the stale ones survive - leaving duplicates that
  fail on the second apply. Replacing the whole set is the only way to stay consistent.

Keeping the filenames exactly as `format-patch` emits them is what makes this
reproducible, so do not rename them by hand afterwards.

Then confirm the whole series still applies to a pristine checkout of the pinned
revision, in order, before committing:

```
for p in patches/zephyr/*.patch;  do git -C zephyr           apply "$p"; done
for p in patches/mcuboot/*.patch; do git -C bootloader/mcuboot apply "$p"; done
```

Keep both directories populated. CI applies each set with a glob, and a glob over a
directory that does not exist expands to nothing, so `apply_patches` fails the job when
a set comes out empty rather than building a pristine SDK that has no ctcc board. If you
ever need an intentionally empty set, add it to `PATCHES_OPTIONAL` in
`.github/workflows/build-firmwares.yml` and say why.

## Commit messages

* One logical change per commit.
* Subject: `topic: area: imperative summary` (for example
  `ctcc: nrf91: enable the on-board external flash from the board`), no trailing
  full stop, wrapped at 72 characters.
* Body: say what was wrong and why the change is right, not what the diff already
  shows. Include what you verified.
* Trailers last: `Signed-off-by` (see above), and `Assisted-by:` if a tool helped
  write the change.

## Serial Modem board support

`patches/nrf-sdk/` is gone from this repository, and with it the ctcc board files for
sdk-nrf's `applications/serial_lte_modem`. That application moved out of the SDK: it is
now the out-of-tree `ncs-serial-modem` add-on, so board support for it belongs there (or
in a repository that pulls the add-on in), not here.

If it is ever restored, note that the old board conf set `CONFIG_SLM_POWER_PIN=2` -
P0.02, which on this card is the mPCIe/M.2 `W_DISABLE#` input. The board devicetree
declares that pin as `ctcc_wdisable` and keeps it `status = "disabled"` precisely so
nothing drives it by accident. Pick a different pin, or leave `ctcc_wdisable` disabled
and document that the two uses are mutually exclusive.

## What the gates do and do not guarantee

`DCO sign-off` and `VERSION bump` are **review aids, not tamper-proof checks.** Both run
on `pull_request`, so they execute the workflow and scripts as they exist *in the pull
request* - a PR that edits them changes what checks itself. The DCO check also skips
merge commits and matches a `Signed-off-by` anywhere in the message rather than
requiring it as the last trailer.

That is a deliberate trade (it keeps the checks useful on forks) rather than an
oversight, but it means they are worth exactly as much as the review that accompanies
them. Require them as status checks in branch protection so a red result blocks the
merge, and read the diff for what the gates cannot see.

## What CI runs

* `DCO sign-off` and `VERSION bump` - on every pull request, on GitHub-hosted
  runners.
* `Build <target>` - the firmware/bootloader/assembly-test matrix, on a
  self-hosted runner with the Zephyr SDK. For safety it does **not** run for pull
  requests from forks; a maintainer builds those. Expect to be asked for build
  output if you cannot run it yourself.

Questions about production firmware, signing keys or hardware: support@cthings.co
