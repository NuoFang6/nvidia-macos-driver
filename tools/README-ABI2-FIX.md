# NVAccel VRAM ABI 2 修复包（macOS 26 黑屏，issue #51）

这个包是用 `nullmoth/nvidia-macos-driver` 的 1.1 版源码重新编译的 NVAccel 加速器
kext，专门解决 macOS 26（Tahoe）上"能开机、桌面全黑"的问题：

> issue #51：`kexts/26/NVAccel.kext` 还在用 VRAM ABI 1，而 NVRMFB 已经改成 ABI 2。
> 每次 `nvAllocVram` 都被拒绝（`ABI mismatch — caller says 1, we speak 2`），
> WindowServer 拿不到显存，桌面就一直是黑的。

## 包内容

| 文件 | 说明 |
|---|---|
| `NVAccel-abi2-macos26/NVAccel.kext` | 重编译的 macOS 26 加速器（VRAM ABI **2**，修复版） |
| `NVAccel-abi2-macos15/NVAccel.kext` | 重编译的 macOS 15 加速器（用于核对，通常不用装） |
| `install-nvaccel26.sh` | 安装脚本：替换 NVAccel 并重建 AuxKC（含备份与回滚） |
| `verify-report.txt` | 云编译时的自动校验报告（符号表 + ABI 判定） |
| `rmdefs-used.txt` | 编译时使用的 Darwin RM 宏集合（可复核） |
| `SHA256SUMS` | 所有文件的校验和 |

## 安装（在 macOS 26 上）

前提：官方 `nullmoth-nvidia-1.1.0` 包已经装过（`/Library/Extensions/NVAccel.kext` 存在）。
如果没有，先用官方包安装（`install.sh` 在 macOS 26 上需要把 `case $MAJ in 15)` 改成 `15|26)`）。

```bash
unzip NVAccel-abi2-kexts.zip && cd dist
sudo ./install-nvaccel26.sh            # 默认用 NVAccel-abi2-macos26/NVAccel.kext
sudo shutdown -r now
```

脚本会：校验 SHA256SUMS → 备份现有 NVAccel（两处）和 AuxKC →
把修复版 NVAccel 装到 `/Library/Extensions/NVAccel.kext` 和
`/Library/NullMoth/kexts/26/NVAccel.kext` → 用与官方 `install.sh` 相同的
`kmutil create` 命令重建 AuxKC 并确认四个 `com.nullmoth.*` kext 都在里面。
任何一步失败都会自动回滚。

> 注意：装完后要把 EFI 配置切回"驱动模式"，也就是恢复
> `config.plist.nullmoth-driver-20261010`（或手动恢复 `nvfb=1 nvaccel=1 nvfbheads=4
> -nvkmsnosmooth` + amfi 参数 + IONDRVSupport 的 Kernel→Block 项 + `ResizeGpuBars 13`
> / `ResizeAppleGpuBars -1`）。在这之前机器是用 `-nvoff` 禁用驱动的状态。

## 重启后验证

```bash
kmutil showloaded --list-only | grep nullmoth      # 应有 4 行
system_profiler SPDisplaysDataType | head -20      # 显示器 online、Metal 3
log show --last boot | grep -c 'ABI mismatch'      # 应为 0
```

如果桌面正常点亮，说明修复生效。

## 回滚

安装脚本结束时会把备份路径打印出来（`/Library/NullMoth/backup-nvaccel-abi2-<时间戳>/`），
按打印的三条命令恢复即可；或者直接重装官方 1.1.0 包。

## 云编译与校验说明

产物由本仓库的 GitHub Actions 工作流 `.github/workflows/build-accel.yml` 在
`macos-26` runner 上从本仓库源码构建（`build/accel_build_all.sh`，PR #60）：

* 头文件：`NVIDIA/open-gpu-kernel-modules` 610.57.04 tag，编译宏集合取自
  在其 `src/nvidia` 下运行的 `make -n TARGET_OS=Darwin TARGET_ARCH=x86_64`
  （与 NullMoth 在 Mac 上生成 `_out/Darwin_x86_64/compile_cmds.sh` 的方式一致；
  另有静态宏表兜底）。
* 校验（`tools/verify_accel.py`，不依赖反汇编器）：
  1. **符号表等价**：重编译产物的 import/export 符号集合必须与官方 shipped 二进制
     完全一致（macOS 15：868/333；macOS 26：843/401，与 PR #60 的参考数字一致；
     参考符号表在 `tools/reference/`）。
  2. **ABI 判定**：在 `NVVidMemory::allocPhysical` 的机器码里必须能读到
     "写入 version 2" 的存储（参考编码 `c7 45 88 02 00 00 00` =
     `mov dword ptr [rbp-0x78], 2`，正是官方 shipped 的 macOS 15 修复版的做法），
     且不得出现旧的 version 1 存储（`c7 45 90 01 00 00 00`，官方 shipped 的
     macOS 26 坏版本的特征）。校验脚本在官方两个 shipped 二进制上自测通过：
     15 版 PASS、26 版（坏）FAIL。
  3. 附注：如果重编译的 macOS 15 与官方二进制 **字节级一致**，说明工具链和宏集合
     被完整复现，报告里会单独标注。

英文摘要：This package rebuilds NVAccel from the 1.1 sources for macOS 26 with
VRAM ABI 2 (issue #51 fix).  `install-nvaccel26.sh` swaps the kext in both
locations, rebuilds the Auxiliary Kernel Collection the same way the vendor
installer does, and rolls back on any failure.  The CI build is gated on
import/export symbol-table equality with the shipped binaries and on the
version-2 store inside `NVVidMemory::allocPhysical`.