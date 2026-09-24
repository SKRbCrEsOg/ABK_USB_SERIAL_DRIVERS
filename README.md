# ABK USB Serial Drivers Module

ABK（AnyBase Kernel）自定义外部模块，用于在 ABK 构建 GKI 内核时**启用常见
USB 转串口（USB-Serial）驱动**以及 **CDC-ACM 类驱动（覆盖 ST-Link V2-1/V3）**。

设计目标：

- `CONFIG_USB_SERIAL`（usbserial 核心）以**内建（`=y`）**方式编译进内核，
  避免单独打包 `usbserial.ko`，同时让设备驱动可以以模块方式链接到它。
- 其余设备驱动以**模块（`=m`）**方式构建，产出 `.ko`，由 ABK 收集并打包成
  可刷入的模块包。

## 支持的驱动

| 驱动 | Kconfig 符号 | 模块 | 说明 |
| --- | --- | --- | --- |
| FTDI | `CONFIG_USB_SERIAL_FTDI_SIO` | `ftdi_sio.ko` | FT232/FT2232 等 |
| Prolific | `CONFIG_USB_SERIAL_PL2303` | `pl2303.ko` | PL2303 |
| Silicon Labs | `CONFIG_USB_SERIAL_CP210X` | `cp210x.ko` | CP2102/CP2104 等 |
| Winchiphead | `CONFIG_USB_SERIAL_CH341` | `ch341.ko` | CH340/CH341/CH430 |
| Winchiphead | `CONFIG_USB_SERIAL_CH343` | `ch343.ko` | CH343/CH344 |
| GSM/CDMA | `CONFIG_USB_SERIAL_OPTION` | `option.ko` | 4G/5G 模块 |
| Qualcomm | `CONFIG_USB_SERIAL_QUALCOMM` | `qcserial.ko` | Qualcomm 串口 |
| TI | `CONFIG_USB_SERIAL_TI` | `ti_usb_3410_5052.ko` | TI 3410/5052 |
| CDC-ACM | `CONFIG_USB_ACM` | `cdc-acm.ko` | **ST-Link V2-1/V3** 虚拟串口 |

核心：`CONFIG_USB_SERIAL=y`，`CONFIG_USB_SERIAL_GENERIC=y`。

> **ST-Link**：Linux 主线没有一个独立的 `stlink` 串口驱动。ST-Link/V2-1 与
> ST-Link/V3 会把自身暴露成 CDC-ACM 虚拟串口，因此本模块通过启用
> `CONFIG_USB_ACM=m`（`cdc-acm.ko`）来提供支持。

> **CH343**：`ch343.c` 并不在 AOSP GKI（`kernel/common`）中。本模块会在树内
> 存在源码/Kconfig 时才启用它；如果不存在会打印警告并跳过，而不是让整个构建
> 失败。需要 CH343 时可自行向内核树回移植 `ch343.c` 后再启用本模块。

> **依赖模块**：启用 `option` 或 `qcserial` 时，Kconfig 会自动
> `select USB_SERIAL_WWAN`，产出 `usb_wwan.ko`。本模块会自动把它一并收集进
> 模块包，且 `post-fs-data.sh` 会优先加载 `usb_wwan.ko` 再加载其它驱动。

## 支持的内核线

ABK 支持 5.10 / 5.15 / 6.1 / 6.6 / 6.12。模块不注入任何驱动源码，直接使用内核
树内已有源码，因此不会跨版本混用。内核版本从 `$KERNEL_ROOT/common/Makefile`
的 `VERSION`/`PATCHLEVEL` 读取，读取失败时回退到 `ABK_BUILD_KERNEL_VERSION`。

## 目录结构

```text
ABK_USB_SERIAL_DRIVERS/
├── setup.sh                      # ABK 入口脚本（已 chmod +x）
├── module.conf                   # 模块元数据
└── scripts/
    ├── libabk.sh                 # ABK 通用工具函数
    └── usb_serial_drivers.sh     # 核心启用逻辑
```

## 工作阶段

| 阶段 | 行为 |
| --- | --- |
| `after_patch` | 定位 `drivers/usb/serial` → 校验 usbserial 核心 → 逐个启用驱动为 `=m` → 写 `$DEFCONFIG` → 更新 `modules.bzl` → 导出 `.ko` 列表 → 校验 |
| `before_build` | 空操作（配置已在 `after_patch` 完成） |

## 在 ABK 中填写

把本模块推送到你的 GitHub 仓库后，在 ABK 的“自定义外部模块”输入框中填写仓库
地址与阶段参数，多个模块用 `|` 分隔：

```text
https://github.com/SKRbCrEsOg/ABK_USB_SERIAL_DRIVERS;after_patch
```

- **阶段**：必须为 `after_patch`。
- **App**：构建设置 → 自定义外部模块 → 填入上面的字符串。
- **GitHub Actions**：触发 `build.yml` / `kernel-custom.yml` 时，把
  `custom_external_modules` 输入设为上面的字符串。

> **不要与 `ABK_USB_SERIAL_CH341` 同时启用**：CH341 模块会把 `ch341` 设为
> `=y`，与本模块的 `ch341=m` 冲突。二者择一。

## 模块（.ko）交付流程

因为 `USB_SERIAL=y` 后不再产出 `usbserial.ko`，本模块会：

1. 从 `modules.bzl` 中删除 `drivers/usb/serial/usbserial.ko`（否则 bazel 会因
   找不到该模块而失败，行为与 ABK 对 `zram.ko`/`zsmalloc.ko` 的处理一致）。
2. 把启用的驱动 `.ko` 追加进 `modules.bzl` 的 GKI 模块列表，使 bazel/kleaf
   构建并产出这些 `.ko`。
3. 通过 `$GITHUB_ENV` 导出 `ABK_EXTERNAL_MODULE_KO_LIST`，供 ABK 在编译完成后
   收集 `.ko` 并打包。

ABK 侧（`build.yml`）在编译完成、准备 Boot 镜像之后，会读取
`ABK_EXTERNAL_MODULE_KO_LIST`，在内核构建输出中查找对应 `.ko`，并生成一个
KernelSU/Magisk 模块包：

```text
<android>-<kernel>.<sub>-<patch>-USB-Serial-Modules.zip
module.prop
system/lib/modules/<driver>.ko
post-fs-data.sh          # 开机 insmod
```

该包会随其它产物一起上传，并在 App 中归类为“模块”，可直接安装。安装后
`post-fs-data.sh` 会在开机时 `insmod` 这些驱动；也可以手动从模块目录加载。

> 若没有启用任何外部模块，或没有找到对应 `.ko`，打包步骤会自动跳过，不影响
> 正常构建。

## 内部逻辑

1. 环境检查：`abk_require_env KERNEL_ROOT DEFCONFIG CUSTOM_EXTERNAL_MODULE_STAGE`。
2. 定位源码：优先 `$KERNEL_ROOT/common/drivers/usb/serial`，回退
   `$KERNEL_ROOT/drivers/usb/serial`；类驱动目录为 `../class`。
3. 识别内核版本。
4. 校验 `usb-serial.c` / `generic.c` / `bus.c` 存在（缺失直接失败）。
5. 确保 `obj-$(CONFIG_USB_SERIAL) += usbserial.o` 与
   `usbserial-y := usb-serial.o generic.o bus.o`（缺失时追加）。
6. `$DEFCONFIG` 写入（幂等）`CONFIG_USB_SERIAL=y`、`CONFIG_USB_SERIAL_GENERIC=y`。
7. 逐个驱动：源码与 Kconfig 符号都存在时写入 `CONFIG_<SYMBOL>=m`，否则警告跳过。
8. 处理隐藏依赖模块（如 `option`/`qcserial` 触发的 `usb_wwan.ko`）。
9. 更新 `$KERNEL_ROOT/common/modules.bzl`：删除 `usbserial.ko`，追加启用的驱动与依赖模块。
10. 导出 `ABK_EXTERNAL_MODULE_KO_LIST`。
11. 校验上述所有改动确实落地。

## 安全设计

1. **不注入驱动源码**：只使用内核树内已有驱动，避免跨版本混用与许可证/来源问题。
2. **不覆盖树内文件**：除 `defconfig`、`drivers/usb/serial/Makefile`（仅在缺失
   链接行时追加）与 `modules.bzl` 外不修改驱动源码。
3. **幂等**：配置先删旧行再追加；Makefile 只在缺失时插入；`modules.bzl` 只在
   缺失时添加。
4. **防错**：`set -euo pipefail`；定位、核心校验、写入后校验任一失败都会
   `exit 1`，构建立即中断，避免产出坏内核。
5. **阶段顺序**：`after_patch` 在编译内核之前，配置改动会被 `build/build.sh`
   的 `make gki_defconfig` 采用；bazel 路径会把 `gki_defconfig` 的差异提取进
   `ksu.fragment`，改动同样保留。

## 本地验证（可选）

```bash
tmp="$(mktemp -d)"
ser="$tmp/common/drivers/usb/serial"
cls="$tmp/common/drivers/usb/class"
mkdir -p "$ser" "$cls" "$tmp/common/arch/arm64/configs"
printf 'VERSION = 6\nPATCHLEVEL = 1\nSUBLEVEL = 0\n' > "$tmp/common/Makefile"
printf 'obj-$(CONFIG_USB_SERIAL)\t\t\t+= usbserial.o\nusbserial-y := usb-serial.o generic.o bus.o\n' \
  > "$ser/Makefile"
printf 'menuconfig USB_SERIAL\n\tbool "USB Serial"\nconfig USB_SERIAL_GENERIC\n\tbool "generic"\nif USB_SERIAL\nendif\n' \
  > "$ser/Kconfig"
touch "$ser/usb-serial.c" "$ser/generic.c" "$ser/bus.c" \
      "$ser/ftdi_sio.c" "$ser/pl2303.c" "$ser/cp210x.c" "$ser/ch341.c" \
      "$ser/option.c" "$ser/qcserial.c" "$ser/ti_usb_3410_5052.c"
printf 'config USB_ACM\n\ttristate "ACM"\n' > "$cls/Kconfig"
touch "$cls/cdc-acm.c"
printf 'CONFIG_TTY=y\n' > "$tmp/common/arch/arm64/configs/gki_defconfig"

export KERNEL_ROOT="$tmp" DEFCONFIG="$tmp/common/arch/arm64/configs/gki_defconfig"
export CUSTOM_EXTERNAL_MODULE_STAGE=after_patch
bash setup.sh   # 第一次
bash setup.sh   # 第二次应为幂等
grep -n 'USB_SERIAL\|USB_ACM' "$DEFCONFIG"
grep -c '\.ko' "$tmp/common/modules.bzl" 2>/dev/null || true
```

## 许可证

本模块整体以 **GPL-2.0** 发布，完整协议文本见 [`LICENSE`](LICENSE)。模块不包含
任何第三方驱动源码，仅修改内核树内已有文件的配置。
