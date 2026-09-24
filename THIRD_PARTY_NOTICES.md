# Third-Party Notices

This module bundles one third-party driver and otherwise only toggles kernel
configuration symbols, appends link lines to the kernel tree's existing
`drivers/usb/serial/Makefile`, adds a `config USB_SERIAL_CH343` entry to
`drivers/usb/serial/Kconfig` when missing, and updates the GKI `modules.bzl`
module list.

## Bundled sources

| File | Origin | License |
| --- | --- | --- |
| `files/drivers/ch343.c` | `driver/ch343.c` from [WCHSoftGroup/ch343ser_linux](https://github.com/WCHSoftGroup/ch343ser_linux) | GPL-2.0-or-later |
| `files/drivers/ch343.h` | `driver/ch343.h` from [WCHSoftGroup/ch343ser_linux](https://github.com/WCHSoftGroup/ch343ser_linux) | GPL-2.0 |

Upstream: <https://github.com/WCHSoftGroup/ch343ser_linux>

Copyright (C) Nanjing Qinheng Microelectronics Co., Ltd. (WCH). The files are
byte-for-byte upstream copies. WCH's driver adapts to kernel differences through
`LINUX_VERSION_CODE` guards and is used here for the CH342/CH343/CH344/CH346/
CH347/CH9101/CH9102/CH9103/CH9104/CH9105/CH9143/CH9111/CH9114 families.

## Kernel-tree drivers

The remaining USB serial drivers referenced by this module are part of the Linux
kernel sources pulled by the ABK build (for example the AOSP `kernel/common`
tree) and are licensed under GPL-2.0. Refer to the upstream kernel sources for
their license headers:

- `drivers/usb/serial/*` — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/serial>
- `drivers/usb/class/cdc-acm.c` — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/class/cdc-acm.c>

The generated `.ko` files are compiled from the target kernel tree during the ABK
build and are not distributed by this repository.
