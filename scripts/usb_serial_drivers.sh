#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Core logic for the ABK USB serial drivers external module.
#
# Stage: after_patch (source tree integrated, before the final defconfig and
# build steps). The module:
#   1. locates drivers/usb/serial and detects the kernel version,
#   2. verifies the usbserial core sources and keep them built-in (=y),
#   3. enables the common USB-to-serial device drivers as modules (=m),
#   4. enables the CDC-ACM class driver as a module (covers ST-Link V2-1/V3),
#   5. updates the GKI modules.bzl list (drop usbserial.ko, add the modules),
#   6. exports the produced .ko names for the ABK kernel-module packaging step,
#   7. verifies every change landed.
#
# Every step is idempotent so the module can be re-run safely.
#
# Notes:
#   - GKI ships usbserial as a module; this module promotes it to built-in so
#     the device drivers can be shipped as small loadable modules.
#   - Drivers whose source/Kconfig is absent from the tree (for example ch343,
#     which is not part of AOSP GKI) are skipped with a warning instead of
#     failing the whole build.

# Echo the record table for the drivers this module manages.
# Format: kind|Kconfig symbol|module name|source file|modules.bzl entry
#   kind=serial -> $serial_dir, kind=class -> drivers/usb/class
abk_usb_serial_driver_table() {
  cat <<'EOF'
serial|USB_SERIAL_FTDI_SIO|ftdi_sio.ko|ftdi_sio.c|drivers/usb/serial/ftdi_sio.ko
serial|USB_SERIAL_PL2303|pl2303.ko|pl2303.c|drivers/usb/serial/pl2303.ko
serial|USB_SERIAL_CP210X|cp210x.ko|cp210x.c|drivers/usb/serial/cp210x.ko
serial|USB_SERIAL_CH341|ch341.ko|ch341.c|drivers/usb/serial/ch341.ko
serial|USB_SERIAL_CH343|ch343.ko|ch343.c|drivers/usb/serial/ch343.ko
serial|USB_SERIAL_OPTION|option.ko|option.c|drivers/usb/serial/option.ko
serial|USB_SERIAL_QUALCOMM|qcserial.ko|qcserial.c|drivers/usb/serial/qcserial.ko
serial|USB_SERIAL_TI|ti_usb_3410_5052.ko|ti_usb_3410_5052.c|drivers/usb/serial/ti_usb_3410_5052.ko
class|USB_ACM|cdc-acm.ko|cdc-acm.c|drivers/usb/class/cdc-acm.ko
EOF
}

# Hidden modules that are auto-selected by an enabled driver (Kconfig select).
# They are not written to the defconfig, but their .ko still has to be shipped.
# Format: enabled-symbol|module name|source file|modules.bzl entry
abk_usb_serial_dependency_table() {
  cat <<'EOF'
USB_SERIAL_OPTION|usb_wwan.ko|usb_wwan.c|drivers/usb/serial/usb_wwan.ko
USB_SERIAL_QUALCOMM|usb_wwan.ko|usb_wwan.c|drivers/usb/serial/usb_wwan.ko
EOF
}

# Locate drivers/usb/serial, supporting both the GKI common/ layout and a
# plain KERNEL_ROOT/drivers layout.
abk_usb_serial_dir() {
  abk_require_env KERNEL_ROOT

  if [ -d "$KERNEL_ROOT/common/drivers/usb/serial" ]; then
    printf '%s/common/drivers/usb/serial\n' "$KERNEL_ROOT"
  elif [ -d "$KERNEL_ROOT/drivers/usb/serial" ]; then
    printf '%s/drivers/usb/serial\n' "$KERNEL_ROOT"
  else
    abk_die "cannot locate drivers/usb/serial under KERNEL_ROOT=$KERNEL_ROOT"
  fi
}

# Echo the "<major>.<minor>" kernel version. Prefers the kernel Makefile and
# falls back to the ABK_BUILD_KERNEL_VERSION variable exported by ABK.
abk_usb_serial_kernel_version() {
  local common="$1"
  local makefile="$common/Makefile"
  local version patchlevel

  if [ -f "$makefile" ]; then
    version="$(awk '$1 == "VERSION" && $2 == "=" { print $3; exit }' "$makefile")"
    patchlevel="$(awk '$1 == "PATCHLEVEL" && $2 == "=" { print $3; exit }' "$makefile")"
    if [ -n "$version" ] && [ -n "$patchlevel" ]; then
      printf '%s.%s\n' "$version" "$patchlevel"
      return 0
    fi
  fi

  if [ -n "${ABK_BUILD_KERNEL_VERSION:-}" ]; then
    printf '%s\n' "$ABK_BUILD_KERNEL_VERSION"
    return 0
  fi

  abk_die "cannot determine kernel version from $makefile or ABK_BUILD_KERNEL_VERSION"
}

# usbserial core sources must exist; they are built into the kernel image and
# are never injected from another kernel version.
abk_usb_serial_require_core() {
  local dir="$1"
  local core

  for core in usb-serial.c generic.c bus.c; do
    if [ ! -f "$dir/$core" ]; then
      abk_die "required USB serial core source missing: $dir/$core (a full kernel tree ships it; do not mix another kernel's core)"
    fi
  done
}

# Ensure usbserial is linkable and the core Kconfig symbols exist.
abk_usb_serial_ensure_core() {
  local dir="$1"
  local makefile="$dir/Makefile"
  local kconfig="$dir/Kconfig"

  abk_require_file "$makefile"
  abk_require_file "$kconfig"

  if ! grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL\)' "$makefile"; then
    abk_append_line_once "$makefile" 'obj-$(CONFIG_USB_SERIAL)			+= usbserial.o'
  else
    abk_log "Makefile already links usbserial.o"
  fi

  if ! grep -Eq '^[[:space:]]*usbserial-y[[:space:]]*[:+]?=' "$makefile"; then
    abk_append_line_once "$makefile" 'usbserial-y := usb-serial.o generic.o bus.o'
  fi

  if ! abk_kconfig_has_config "$kconfig" USB_SERIAL; then
    abk_die "Kconfig does not define USB_SERIAL: $kconfig"
  fi
}

# Directory holding bundled driver sources shipped by this module.
abk_usb_serial_files_dir() {
  printf '%s/files\n' "$MODULE_DIR"
}

# CH343 is not part of AOSP GKI, so bundle the WCH driver and inject it only
# when the tree has none. An in-tree ch343.c is always preserved by default.
abk_usb_serial_install_ch343() {
  local dir="$1"
  local files target force

  force="${ABK_USB_SERIAL_FORCE_INJECT:-0}"
  files="$(abk_usb_serial_files_dir)"
  target="$dir/ch343.c"

  if [ -f "$target" ] && [ "$force" != "1" ]; then
    abk_log "in-tree ch343 driver kept: $target (set ABK_USB_SERIAL_FORCE_INJECT=1 to overwrite)"
    return 0
  fi

  abk_install_file "$files/drivers/ch343.c" "$dir/ch343.c"
  abk_install_file "$files/drivers/ch343.h" "$dir/ch343.h"
}

abk_usb_serial_ensure_ch343_makefile() {
  local dir="$1"
  local makefile="$dir/Makefile"

  abk_require_file "$makefile"

  if ! grep -Eq '^[[:space:]]*obj-\$\(CONFIG_USB_SERIAL_CH343\)' "$makefile"; then
    abk_append_line_once "$makefile" 'obj-$(CONFIG_USB_SERIAL_CH343)		+= ch343.o'
  else
    abk_log "Makefile already links ch343.o"
  fi
}

abk_usb_serial_ensure_ch343_kconfig() {
  local dir="$1"
  local kconfig="$dir/Kconfig"
  local block

  abk_require_file "$kconfig"

  if abk_kconfig_has_config "$kconfig" USB_SERIAL_CH343; then
    abk_log "Kconfig already defines USB_SERIAL_CH343"
    return 0
  fi

  block="$(mktemp)"
  cat > "$block" <<'EOF'
config USB_SERIAL_CH343
	tristate "USB WCH CH342/CH343/CH344/CH910x/CH9143/CH347 serial driver"
	help
	  Say Y here if you want to use WCH CH342/CH343/CH344/CH346/CH347/
	  CH339/CH9101/CH9102/CH9103/CH9104/CH9105/CH9143/CH9111/CH9114
	  USB to UART chips through the dedicated VCP driver.

	  To compile this driver as a module, choose M here: the module
	  will be called ch343.

EOF
  if grep -Eq '^[[:space:]]*endif.*USB_SERIAL' "$kconfig"; then
    abk_kconfig_insert_before "$kconfig" '^[[:space:]]*endif.*USB_SERIAL' "$block"
  else
    cat "$block" >> "$kconfig"
  fi
  rm -f "$block"
  abk_log "injected config USB_SERIAL_CH343 into $kconfig"
}

# Fail loudly if any expected change did not land.
abk_usb_serial_verify() {
  local dir="$1"
  local enabled_file="$2"
  local deps_file="${3:-}"
  local common
  local symbol ko bzl

  common="$(cd "$dir/../../.." && pwd)"

  abk_require_env DEFCONFIG

  grep -qxF 'CONFIG_USB_SERIAL=y' "$DEFCONFIG" ||
    abk_die "DEFCONFIG is missing CONFIG_USB_SERIAL=y"

  if [ -f "$enabled_file" ]; then
    while read -r symbol ko bzl; do
      [ -n "$symbol" ] || continue
      grep -qxF "CONFIG_${symbol}=m" "$DEFCONFIG" ||
        abk_die "DEFCONFIG is missing CONFIG_${symbol}=m"
      if [ -f "$common/modules.bzl" ]; then
        grep -qF "\"$bzl\"" "$common/modules.bzl" ||
          abk_die "modules.bzl is missing $bzl"
      fi
    done < "$enabled_file"
  fi

  # Dependency modules are selected by Kconfig, so only their modules.bzl entry
  # is verified (they never appear in the defconfig file).
  if [ -n "$deps_file" ] && [ -f "$deps_file" ] && [ -f "$common/modules.bzl" ]; then
    while read -r symbol ko bzl; do
      [ -n "$symbol" ] || continue
      grep -qF "\"$bzl\"" "$common/modules.bzl" ||
        abk_die "modules.bzl is missing $bzl"
    done < "$deps_file"
  fi

  if [ -f "$common/modules.bzl" ] &&
     grep -q '"drivers/usb/serial/usbserial\.ko"' "$common/modules.bzl"; then
    abk_die "modules.bzl still lists usbserial.ko while CONFIG_USB_SERIAL=y"
  fi

  abk_log "verification passed"
}

abk_usb_serial_apply() {
  local dir usb_dir class_dir common version
  local enabled_file deps_file ko_list="" symbol kind ko src bzl d kcfg
  local dep_symbol dep_ko dep_src dep_bzl

  abk_require_env KERNEL_ROOT DEFCONFIG

  dir="$(abk_usb_serial_dir)"
  usb_dir="$(cd "$dir/.." && pwd)"
  class_dir="$usb_dir/class"
  common="$(cd "$dir/../../.." && pwd)"
  version="$(abk_usb_serial_kernel_version "$common")"

  abk_log "serial dir: $dir"
  abk_log "usb class dir: $class_dir"
  abk_log "kernel version: $version"

  abk_usb_serial_require_core "$dir"
  abk_usb_serial_ensure_core "$dir"

  # CH343 is not shipped by AOSP GKI: inject the bundled WCH driver so the
  # driver-table entry below can enable it on every supported kernel line.
  abk_usb_serial_install_ch343 "$dir"
  abk_usb_serial_ensure_ch343_makefile "$dir"
  abk_usb_serial_ensure_ch343_kconfig "$dir"

  # usbserial core stays built-in; device drivers are loadable modules.
  abk_set_config USB_SERIAL y "$DEFCONFIG"
  if abk_kconfig_has_config "$dir/Kconfig" USB_SERIAL_GENERIC; then
    abk_set_config USB_SERIAL_GENERIC y "$DEFCONFIG"
  else
    abk_warn "Kconfig does not define USB_SERIAL_GENERIC; skipping"
  fi

  enabled_file="$(mktemp)"
  deps_file="$(mktemp)"
  : > "$enabled_file"
  : > "$deps_file"

  while IFS='|' read -r kind symbol ko src bzl; do
    [ -n "$kind" ] || continue

    case "$kind" in
      serial) d="$dir" ;;
      class)  d="$class_dir" ;;
      *) abk_warn "unknown driver kind '$kind' for $symbol, skipping"; continue ;;
    esac

    if [ ! -f "$d/$src" ]; then
      abk_warn "driver source missing for $symbol ($d/$src), skipping"
      continue
    fi

    kcfg="$d/Kconfig"
    if [ -f "$kcfg" ] && ! abk_kconfig_has_config "$kcfg" "$symbol"; then
      abk_warn "Kconfig symbol $symbol missing in $kcfg, skipping"
      continue
    fi

    abk_set_config "$symbol" m "$DEFCONFIG"
    printf '%s %s %s\n' "$symbol" "$ko" "$bzl" >> "$enabled_file"
    ko_list="$ko_list $ko"
  done < <(abk_usb_serial_driver_table)

  # Collect hidden modules selected by the enabled drivers (e.g. usb_wwan.ko
  # for option/qcserial). They are not written to the defconfig, but their .ko
  # still has to be built and shipped.
  if [ -s "$enabled_file" ]; then
    while IFS='|' read -r dep_symbol dep_ko dep_src dep_bzl; do
      [ -n "$dep_symbol" ] || continue
      grep -q "^${dep_symbol} " "$enabled_file" || continue
      case " ${ko_list} " in
        *" ${dep_ko} "*) continue ;;
      esac
      if [ ! -f "$dir/$dep_src" ]; then
        abk_warn "dependency source missing for $dep_ko ($dir/$dep_src), skipping"
        continue
      fi
      printf '%s %s %s\n' "$dep_symbol" "$dep_ko" "$dep_bzl" >> "$deps_file"
      ko_list="$ko_list $dep_ko"
    done < <(abk_usb_serial_dependency_table)
  fi

  if [ ! -s "$enabled_file" ]; then
    abk_warn "no requested USB serial driver was found in this kernel tree"
    ko_list=""
  else
    # Core built-in => usbserial.ko must not be listed for bazel builds.
    abk_bzl_remove_module "$common/modules.bzl" "drivers/usb/serial/usbserial.ko"

    while read -r symbol ko bzl; do
      abk_bzl_add_module "$common/modules.bzl" "$bzl"
    done < "$enabled_file"
    while read -r symbol ko bzl; do
      abk_bzl_add_module "$common/modules.bzl" "$bzl"
    done < "$deps_file"

    ko_list="${ko_list# }"
  fi

  abk_export_env ABK_EXTERNAL_MODULE_KO_LIST "$ko_list"

  abk_usb_serial_verify "$dir" "$enabled_file" "$deps_file"
  rm -f "$enabled_file" "$deps_file"
}
