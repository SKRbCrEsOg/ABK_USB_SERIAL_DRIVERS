# Third-Party Notices

This module does not bundle or redistribute any third-party source code. It only
toggles kernel configuration symbols and, when needed, appends link lines to the
kernel tree's existing `drivers/usb/serial/Makefile` and updates the GKI
`modules.bzl` module list.

The USB serial drivers referenced by this module are part of the Linux kernel
sources pulled by the ABK build (for example the AOSP `kernel/common` tree) and
are licensed under GPL-2.0. Refer to the upstream kernel sources for their
license headers:

- `drivers/usb/serial/*` — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial>
- `drivers/usb/class/cdc-acm.c` — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/class/cdc-acm.c>

The generated `.ko` files are compiled from the target kernel tree during the ABK
build and are not distributed by this repository.
