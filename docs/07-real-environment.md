# 真实环境数据

> 本文档记录 2026-10-16 ~ 10-17 在一台真实机器上构建这套系统的全部实测数据。
> 提供给用于对照参考。

## 目录

1. [硬件与系统](#1-硬件与系统)
2. [磁盘与分区](#2-磁盘与分区)
3. [构建时间线](#3-构建时间线)
4. [文件与体积](#4-文件与体积)
5. [GUID 对照表](#5-guid-对照表)
6. [配置记录文件](#6-配置记录文件)
7. [一个真实的故障案例](#7-一个真实的故障案例)

> 第 5 节末尾附有 `bcdedit /enum {current}` 的完整实测输出，是排查启动问题的第一手参考。

---

## 1. 硬件与系统

| 项 | 值 |
|---|---|
| 机器 | Lenovo Legion |
| 计算机名 | `LEGION-VHD` |
| 系统 | Windows 11 Pro 10.0.26300 |
| 磁盘 | 2 × SK Hynix HFS001TEJ9X115N（NVMe 1TB） |
| 引导 | UEFI + GPT |
| ESP | 450 MB，FAT32，位于磁盘 0 分区 1 |

---

## 2. 磁盘与分区

### 物理布局

```
磁盘 0 (NVMe 954GB)                  磁盘 1 (NVMe 954GB)
├─ part1  System     450MB  FAT32    ← ESP
├─ part2  Reserved    16MB
├─ part3  Basic     951GB  NTFS  D:   ← 物理 Windows（卷标 Windows-SSD）
└─ part4  Recovery  0.87GB
                                     └─ part2  Basic 953GB NTFS E:  ← 数据盘（卷标 Data）
```

### 实测输出

```
=== NVMe 磁盘 ===
disk0 SKHynix_HFS001TEJ9X115N 954GB
disk1 SKHynix_HFS001TEJ9X115N 954GB

=== 分区 ===
disk0 part1 System   letter=(none)
disk0 part2 Reserved letter=(none)
disk0 part3 Basic    letter=D
disk0 part4 Recovery letter=(none)
disk1 part1 Reserved letter=(none)
disk1 part2 Basic    letter=E
```

### VHD 挂载后的虚拟磁盘

```
disk2 Msft Virtual Disk  File Backed Virtual  384GB   ← Work.vhdx 挂载后的样子
```

**关键：分区类型是 `IFS`，不是 `Basic`。** 详见 [pitfalls #13](04-pitfalls.md)。

---

## 3. 构建时间线

```
2026-10-16 06:03:05   阶段 0  备份 BCD
                      → BCD_Backup_20261016-060305（36,864 字节）
                      → bcd_enum_all_before_20261016-060305.txt
                      → bcd_enum_firmware_before_20261016-060305.txt

2026-10-16 06:55      阶段 1  环境调整
                      → state.json（HiberbootEnabledBefore=1）

2026-10-16 07:48:33   阶段 3  创建 Base 启动项
                      → BCD_Backup_stage3_20261016-074833
                      → entry.json（GUID: ced6181c-...）

2026-10-16 11:52:08   母盘封箱完成
                      → Base.vhdx 最后一次修改
                      → 之后只读，11 天未变

2026-10-17 00:10:39   阶段 5  创建 Work 启动项
                      → BCD_Backup_stage5_20261017-001039

2026-10-17 00:10:43   Work.vhdx 创建

2026-10-17 00:10:46   entry-work.json 写入（GUID: ced6181f-...）

2026-10-17 00:30:43   首次备份 Work.initial.bak（6.22 GB，初始状态）
```

**从开始到完成：约 18 小时（跨两次重启进入母盘系统配置）。**

---

## 4. 文件与体积

### 最终状态

```
E:\VHD\
    Base.vhdx                       47.65 GB   只读，384GB 虚拟
    Work.vhdx                       86.17 GB   差分盘（用了约 10 天）
    BCD_Backup_original             36 KB
    entry.json                      322 B
    entry-work.json                498 B
    state.json                     124 B
    Reset-Work.ps1               9,476 B
    Rollback-Stage3.ps1          2,465 B
    Rollback-Stage5.ps1          7,283 B
    Logs\                                  四个 BCD 备份 + 三个文本快照
    Drivers\                       148 MB  网卡驱动（装机用）
    Installers\                     60 MB
```

### 体积变化观察

| 时间 | Work.vhdx | 说明 |
|---|---|---|
| 创建时 | 4 MB | 纯元数据 |
| 首次开机后 | ~6 GB | 基础系统写入 |
| +2 周 | 86 GB | 装完 Office + TeX Live + 开发工具 |

### 空洞比例

```
Work 系统内 C: 实际已用        91.4 GB（384GB 中）
Work.vhdx 文件大小             86.17 GB
Base.vhdx 文件大小             47.65 GB
合计                            133.82 GB

多出  42.4 GB
```

这 42 GB 是差分盘的"写后又删"块残留。属于正常现象，可用 `Optimize-VHD` 回收。

里还包含了大量软件与文件。

---

## 5. GUID 对照表

### BCD 启动项

```
{default}                                 Windows 11（物理系统）
{current}                                 Win11-Work（当前启动项）
{ced6181c-bae1-11f1-94bc-a085277a74a6}    Win11-Base-VHD
{ced6181f-bae1-11f1-94bc-a085277a74a6}    Win11-Work（真实 ID）
```

### 辅助对象

```
{ced6181a-bae1-11f1-94bc-a085277a74a6}    Resume Application
{ced6181d-bae1-11f1-94bc-a085277a74a6}    Recovery（Base）
{ced6181e-bae1-11f1-94bc-a085277a74a6}    Device options（Base Recovery）
{da42d6b7-249e-11f1-94a6-b33b1aa7a71c}    Recovery（物理）
{da42d6b8-249e-11f1-94a6-b33b1aa7a71c}    Device options（物理 Recovery）
{6efb52bf-1766-41db-a6b3-0ee5eff72bd7}    inherit（Work 继承项）
```

### 卷 GUID

```
\\?\Volume{01093b1e-3321-4fe2-b9aa-02da0aaf7d2b}\    C: Base（VHD 内）
\\?\Volume{79e9bac7-a3ad-4262-a557-d4134770d729}\    E: Data（数据盘）
\\?\Volume{8fbaba62-9036-447e-92f8-e0c585d05253}\    D: Windows-SSD（物理系统）
\\?\Volume{ae5da271-9d63-4417-bf12-91f9ccf01688}\    WINRE_DRV
\\?\Volume{f909aeda-e866-4166-a684-0e5270241763}\    SYSTEM_DRV（ESP）
```

> **卷 GUID 在本项目里很重要：** VHDX 内部用 `volume_path` 引用父盘，换盘符不影响。

### `{current}` 的完整内容（进 Work 后实测）

在 Work 系统里跑 `bcdedit /enum {current}`，拿到的就是这个。
这是全项目最有参考价值的一段输出：

```
Windows Boot Loader
-------------------
identifier              {ced6181f-bae1-11f1-94bc-a085277a74a6}
device                  vhd=[E:]\VHD\Work.vhdx,locate=custom:12000002
path                    \Windows\system32\winload.efi
description             Win11-Work
locale                  en-US
inherit                 {6efb52bf-1766-41db-a6b3-0ee5eff72bd7}
recoverysequence        {da42d6b7-249e-11f1-94a6-b33b1aa7a71c}
recoveryenabled         No
isolatedcontext         Yes
allowedinmemorysettings 0x15000075
osdevice                vhd=[E:]\VHD\Work.vhdx,locate=custom:22000002
systemroot              \Windows
resumeobject            {ced6181a-bae1-11f1-94bc-a085277a74a6}
nx                      OptIn
bootmenupolicy          Standard
hypervisorlaunchtype    Auto
detecthal               Yes
```

各处值得注意的地方：

| 字段 | 说明 |
|---|---|
| `vhd=[E:]` | **这就是盘符陷阱的铁证**——物理系统里数据盘是 `D:`，Work 里变成 `E:` |
| `locate=custom:12000002` | Windows 自动加的定位参数，**不要手动改**（见 [pitfalls #10](04-pitfalls.md)） |
| `device` 与 `osdevice` | 后缀不同（`12000002` vs `22000002`），两个都要设，只改 `device` 启动不了 |
| `recoveryenabled No` | VHD 启动项的恢复环境被禁用，所以 VHD 系统蓝屏时进不了自动修复 |
| `isolatedcontext Yes` | VHD 系统与宿主隔离的标志位 |
| `path \Windows\system32\winload.efi` | UEFI 是 `winload.efi`；Legacy 是 `winload.exe` |

> **验证方法：** 设完启动项后 `bcdedit /enum {guid}` 看到 `vhd=` 出现在
> `device` **和** `osdevice` 两行里，才算成功。只看一行会漏判（[pitfalls #14](04-pitfalls.md)）。

---

## 6. 配置记录文件

### `state.json`（阶段 1 生成）

```json
{
    "HiberbootEnabledBefore":  1,
    "FirstRun":  "2026-10-16T06:03:05",
    "VirtualDiskExpandOnMountBefore":  1
}
```

### `entry.json`（阶段 3 生成）

```json
{
    "Guid":  "{ced6181c-bae1-11f1-94bc-a085277a74a6}",
    "Description":  "Win11-Base-VHD",
    "Vhd":  "vhd=[D:]\\VHD\\Base.vhdx",
    "CreatedAt":  "2026-10-16T07:48:35",
    "PreviousTimeout":  "10",
    "DefaultBefore":  "{current}",
    "BackupFile":  "D:\\VHD\\Logs\\BCD_Backup_stage3_20261016-074833"
}
```

### `entry5.json`（阶段 5 生成）

```json
{
    "WorkGuid":  "{ced6181f-bae1-11f1-94bc-a085277a74a6}",
    "BaseGuid":  "{ced6181c-bae1-11f1-94bc-a085277a74a6}",
    "Description":  "Win11-Work",
    "BasePath":  "D:\\VHD\\Base.vhdx",
    "WorkPath":  "D:\\VHD\\Work.vhdx",
    "BaseLength":  51167363072,
    "BaseWriteTicks":  639277735280219577,
    "PreviousTimeout":  "30",
    "DefaultBefore":  "{current}",
    "BackupFile":  "D:\\VHD\\Logs\\BCD_Backup_stage5_20261017-001039",
    "CreatedAt":  "2026-10-17T00:10:46"
}
```

> **注意 `BaseLength` + `BaseWriteTicks`：** 这是母盘指纹。
> `51167363072` 字节 = 47.65 GB，与现在一致，说明母盘真的一直没变过。

---

## 7. 一个真实的故障案例

### 背景

构建完成后，作者在 Work 里工作了一个月。某天发现启动菜单里选 `Win11-Work` 报错。

### 现象

机器意外重启后，`Win11-Work` 无法启动。

### 排查过程

作者曾在 Work 里写过一个辅助脚本，用来临时创建一个目录联接：

```
D:\Hyper-V  ->  E:\Hyper-V
```

原因：虚拟机配置里写死了 `D:\Hyper-V\...`，但 Work 里数据盘是 `E:`。

脚本设计成"用完就删联接"：启动 Watch 进程监控，当所有虚拟机 Off 且管理器关闭时删除联接。

### 真正的坑

脚本判断"虚拟机是否在跑"用的代码：

```powershell
$b = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Off' })
if ($b.Count -eq 0 -and -not (Test-MmcOpen)) { Remove-Link }
```

**`-ErrorAction SilentlyContinue` 在无 Hyper-V 管理员权限时，会让 `Get-VM` 静默返回空数组。**

于是：

```
17:03:55  创建联接
17:03:55  启动 Watch 进程
17:03:56  Watch 第一轮：Get-VM 返回空，管理器窗口还没起来 → 判定“空闲”
17:03:56  删除联接
```

**联接存活了 1 秒。**

### 后果

联接没了，虚拟机配置里的 `D:\Hyper-V` 路径失效，虚拟机无法启动。
但**数据没有丢**，因为脚本用的是 `cmd /c rmdir`（只删重解析点，不递归）。

### 学到什么

1. **权限不足 = 未知。未知必须按"占用/危险"处理。**
   见 [pitfalls #5](04-pitfalls.md)
2. **系统命令不能只看退出码或静默返回，必须验证实际状态。**
3. **任何"自动删除"的逻辑都很危险。** "留着"比"及时清理"安全得多。

### 这个教训如何影响本项目

- 本工具包**没有任何自动删除逻辑**
- 所有 `Get-*` 检查都会明确区分"不存在"和"读不到"
- 所有回滚只删 BCD 项，VHD 文件一律保留

---

## 附：如何对照使用本文档

| 你想知道 | 看哪节 |
|---|---|
| 我的机器能行吗 | [1. 硬件与系统](#1-硬件与系统) |
| 需要多大空间 | [4. 文件与体积](#4-文件与体积) |
| 正常要多久 | [3. 构建时间线](#3-构建时间线) |
| 记录文件长什么样 | [6. 配置记录文件](#6-配置记录文件) |
| 可能遇到什么坑 | [7. 故障案例](#7-一个真实的故障案例) + [避坑指南](04-pitfalls.md) |
