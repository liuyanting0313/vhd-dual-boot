# 前置条件

> 跑 `scripts\00-check.ps1` 会自动检查 8 项。本文解释每项为什么重要。

## 目录

1. [硬件要求](#1-硬件要求)
2. [系统要求](#2-系统要求)
3. [目录约定](#3-目录约定)
4. [开始前必须做的备份](#4-开始前必须做的备份)
5. [空间规划](#5-空间规划)
6. [手动检查清单](#6-手动检查清单)

---

## 1. 硬件要求

| 项 | 最低 | 推荐 | 实测环境 |
|---|---|---|---|
| 磁盘 | 1 块，有空余分区 | 2 块（系统盘 + 数据盘分离） | 2 × SK Hynix 1TB NVMe |
| 引导 | UEFI + GPT | UEFI + GPT | UEFI，ESP 450MB FAT32 |
| 内存 | 4 GB | 8 GB+ | — |

### 为什么建议数据盘和系统盘分开

如果 VHD 放在系统盘（`C:`）：

- 系统盘空间紧张时容易被 VHD 塔满
- 两个系统里 `C:` 都是系统盘，容易混淆（Work 里的 `C:` 是 VHD 内部的分区）

放在数据盘就清晰多了：

| | 物理 Windows | Work |
|---|---|---|
| 系统盘 | `C:` | `C:`（VHD 内） |
| 数据盘 | `D:` | `E:` |

**脚本一律用卷标 `Data` 定位，不写死盘符。**

### UEFI 检查

```powershell
# ESP 分区存在且为 FAT32 就是 UEFI
Get-Partition | Where-Object { $_.Type -eq 'System' } |
    ForEach-Object { Get-Volume -Partition $_ -ErrorAction SilentlyContinue } |
    Select-Object DriveLetter, FileSystem
```

期望看到 `FileSystem = FAT32`。

---

## 2. 系统要求

| 项 | 要求 |
|---|---|
| 版本 | Windows 11（Windows 10 理论上也行，未充分测试） |
| 权限 | 管理员 |
| PowerShell | 5.1 或更高 |
| 执行策略 | 需能跑脚本（脚本自带 `-ExecutionPolicy Bypass`） |

### 关闭快速启动（关键）

快速启动 = 混合关机，VHD 文件句柄不会释放，导致挂载失败：

```
Mount-DiskImage : 无法装载，文件被占用
```

`01-prepare.ps1` 会自动处理，但你也可以手动：

```powershell
powercfg /hibernate off
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -Value 0 -Type DWord
```

---

## 3. 目录约定

```
数据盘（卷标 Data）
└─ VHD\                  ← 所有 VHD 和脚本
    ├─ Base.vhdx
    ├─ Work.vhdx
    ├─ Logs\             ← BCD 备份与快照
    ├─ state.json
    ├─ entry-base.json
    └─ entry-work.json
```

### 卷标怎么定

工具默认找卷标为 `Data` 的卷。如果不是：

```powershell
# 查看现有卷标
Get-Volume | Where-Object DriveLetter |
    Select-Object DriveLetter, FileSystemLabel, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}

# 改卷标（例：改成 Data）
Set-Volume -DriveLetter E -NewFileSystemLabel Data
```

改完卷标后，所有脚本都无需额外参数。

**如果不想改卷标**，每条命令都加参数：

```powershell
.\00-check.ps1 -DataLabel "MyData"
.\01-prepare.ps1 -DataLabel "MyData"
.\02-create-base.ps1 -DataLabel "MyData"
# ... 以此类推
```

---

## 4. 开始前必须做的备份

### BCD 备份（最重要）

```powershell
# 管理员
$VhdDir = 'E:\VHD'    # 改成你的实际路径
New-Item -ItemType Directory -Force -Path "$VhdDir\Logs" | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
bcdedit /export "$VhdDir\Logs\BCD_Backup_$stamp"
if ($LASTEXITCODE -ne 0) { throw 'BCD 导出失败，停止' }

# 文本快照（便于人工比对）
bcdedit /enum all      > "$VhdDir\Logs\bcd_enum_all_$stamp.txt"
bcdedit /enum firmware > "$VhdDir\Logs\bcd_enum_firmware_$stamp.txt"
```

### 为什么 BCD 备份这么重要

BCD（Boot Configuration Data）是启动配置数据库。改坏了：

- 轻：看不到启动菜单
- 重：两个系统都启动不了

**但有备份就能恢复**：

```powershell
bcdedit /import "E:\VHD\Logs\BCD_Backup_20261016-060305" /clean
```

`01-prepare.ps1` 会自动做这个备份，备份失败会中止整个流程。

### 系统盘备份（强烈建议）

虽然不是必需，但强烈建议先用系统自带的映像备份把 `C:` 备份一份：

```
控制面板 → 系统和安全 → 备份和还原(Windows 7) → 创建系统映像
```

---

## 5. 空间规划

### 计算方式

```
需求 = Base.vhdx 实际大小 × 3

例：
    Base.vhdx 约 48 GB
    需求 = 144 GB

实际分配：
    Base.vhdx        48 GB
    Work.vhdx        86 GB（会持续增长）
    备份空间          80 GB
    ─────────────────────
    合计            214 GB
```

### 母盘大小怎么选

| 虚拟大小 | 适合场景 |
|---|---|
| 128 GB | 轻量测试 |
| 256 GB | 一般使用 |
| **384 GB** | 装 Office + 开发工具链（实测值） |
| 512 GB + | 重度使用 |

**用 `expandable`（动态扩展），不用 `fixed`。**
动态盘按实际占用增长，`fixed` 会立刻占满全部空间。

### 实测体积参考

```
Base.vhdx     47.65 GB   （384GB 虚拟大小，装了 Office + TeX Live + 开发工具）
Work.vhdx     86.17 GB   （用了约 2 周）
```

---

## 6. 手动检查清单

开跑前逐项确认：

- [ ] 备份了 BCD（`vhd\Logs\` 里有 `BCD_Backup_*`）
- [ ] 不是以 Legacy BIOS 启动（`00-check.ps1` 第 3 项）
- [ ] 数据盘卷标是 `Data`，或已决定用 `-DataLabel` 参数
- [ ] 数据盘可用空间 ≥ 150 GB
- [ ] 已关闭快速启动（或打算让 `01` 关）
- [ ] 手边有 Windows 11 ISO（阶段 2 要用）
- [ ] 能重启电脑（中途要进母盘系统）
- [ ] 沙盘演练过一遍（**强烈建议**，见 [沙盒演练](05-daily-use.md#沙盒演练)）

全勾上了就可以开始了 → [构建指南](03-build-guide.md)
