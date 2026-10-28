# 构建指南

> 五阶段完整流程。每一步的真实代码都来自实际运行过的脚本。

## 目录

1. [五阶段总览](#1-五阶段总览)
2. [阶段0 · 准备](#2-阶段-0--准备)
3. [阶段1 · 环境调整](#3-阶段-1--环境调整)
4. [阶段2 · 创建并部署母盘](#4-阶段-2--创建并部署母盘)
5. [阶段3 · 固化母盘](#5-阶段-3--固化母盘)
6. [阶段4 · 派生 Work](#6-阶段-4--派生-work)
7. [阶段5 · 挂进启动菜单](#7-阶段-5--挂进启动菜单)
8. [完整验证](#8-完整验证)

---

## 1. 五阶段总览

```
阶段 0  准备          备份 BCD、建目录、备 ISO
   ↓
阶段 1  环境调整      关快速启动、关 VHD 自动扩展          → state.json
   ↓
阶段 2  创建母盘      建 VHD → 分区 → 部署 Windows → bcdboot
   ↓
阶段 3  固化母盘      进 Base 配置 → sysprep → 设只读 → 加启动项  → entry-base.json
   ↓
阶段 4  派生 Work     从 Base 创建差分盘
   ↓
阶段 5  挂 Work       建 Work 启动项、加菜单              → entry-work.json
```

**为什么分这么细**：阶段之间要反复重启进不同系统，中途失败很常见。
分清阶段才能精准回滚。

---

## 2. 阶段 0 · 准备

```powershell
# 管理员 PowerShell
$VhdDir = 'E:\VHD'
New-Item -ItemType Directory -Force -Path $VhdDir | Out-Null
New-Item -ItemType Directory -Force -Path "$VhdDir\Logs" | Out-Null

# 备份 BCD
bcdedit /export "$VhdDir\Logs\BCD_Backup_$(Get-Date -Format yyyyMMdd-HHmmss)"
if ($LASTEXITCODE -ne 0) { throw 'BCD 导出失败，停止' }

# 记录当前设置（供以后回滚）
@{
    HiberbootEnabledBefore         = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    VirtualDiskExpandOnMountBefore = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' -Name VirtualDiskExpandOnMount -ErrorAction SilentlyContinue).VirtualDiskExpandOnMount
    FirstRun                       = (Get-Date).ToString('s')
} | ConvertTo-Json | Set-Content "$VhdDir\state.json" -Encoding UTF8
```

**对应脚本**：`scripts\01-prepare.ps1`

**实测结果**（真实 `state.json`）：

```json
{
    "HiberbootEnabledBefore":  1,
    "FirstRun":  "2026-10-16T06:03:05",
    "VirtualDiskExpandOnMount":  1
}
```

> **为什么要记这两个：**
> - `HiberbootEnabled=1` 是快速启动，会让 VHD 挂载报"文件被占用"
> - `VirtualDiskExpandOnMount=1` 会在挂载时自动扩展 VHD

---

## 3. 阶段 1 · 环境调整

```powershell
# 关快速启动
powercfg /hibernate off
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -Value 0 -Type DWord

# 关挂载自动扩展
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' `
    -Name VirtualDiskExpandOnMount -Value 0 -Type DWord
```

**验证：**

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled   # 0
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds').VirtualDiskExpandOnMount           # 0
```

**对应脚本**：`scripts\01-prepare.ps1`（同一个脚本完成阶段 0 和 1）

---

## 4. 阶段 2 · 创建并部署母盘

### 4a. 创建空 VHDX

```powershell
$Base = 'E:\VHD\Base.vhdx'

$dp = Join-Path $env:TEMP 'mkbase.txt'
@(
    "create vdisk file=`"$Base`" maximum=393216 type=expandable"   # 384GB
    "select vdisk file=`"$Base`""
    'attach vdisk'
    'create partition primary'
    'format fs=ntfs quick label=Base'
    'assign letter=B'
    'detach vdisk'
) | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force
```

> `maximum` 单位是 **MB**。`393216` MB = 384 GB。
> **用 `expandable`，不用 `fixed`。**

**对应脚本**：`scripts\02-create-base.ps1`

### 4b. 部署 Windows — 方式 A：DISM（推荐）

```powershell
$Base = 'E:\VHD\Base.vhdx'
$Wim  = 'D:\ISO\sources\install.wim'    # 从 Windows 11 ISO 提取

# 1) 查版本号
Get-WindowsImage -ImagePath $Wim | Select-Object ImageIndex, ImageName
# Windows 11 专业版通常是 Index = 6

# 2) 挂载 VHD
$dp = Join-Path $env:TEMP 'mnt.txt'
@("select vdisk file=`"$Base`"", 'attach vdisk') | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force

# 3) 找分区盘符
$disk = Get-DiskImage -ImagePath $Base | Get-Disk
$part = Get-Partition -DiskNumber $disk.Number |
        Where-Object { $_.Size -gt 50MB } |
        Sort-Object Size -Descending | Select-Object -First 1
if (-not $part.DriveLetter) {
    Add-PartitionAccessPath -DiskNumber $disk.Number `
        -PartitionNumber $part.PartitionNumber -AssignDriveLetter
    Start-Sleep 2
    $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
}
$L = "$($part.DriveLetter):"
Write-Host "目标分区：$L"

# 4) 展开系统
Expand-WindowsImage -ImagePath $Wim -Index 6 -ApplyPath "$L\" -Verify

# 5) ★ 写引导文件（最关键，漏了就不能启动）
bcdboot "$L\Windows" /s $L /f UEFI

# 6) 分离
Dismount-DiskImage -ImagePath $Base
```

> **`bcdboot` 这一行是必须的。**
> 它把 `bootmgr`、`BCD`、`winload.efi` 等引导文件写进 VHD 内部。
> 没有它，VHD 里只有系统文件，启动不了。

### 4c. 部署 Windows — 方式 B：物理机装好后捕获

如果手头有现成装好的系统，可以用 `disk2vhd` 工具捕获成 VHDX，
但捕获后**仍需在 VHD 内执行 `bcdboot`**。

### 4d. 驱动准备

```
E:\VHD\Drivers\   148MB，31 个文件
    netwfw18.dat  19.6MB
    netwfw14.dat  16MB
    Netwtw08.sys   8.5MB
```

> 母盘首次启动可能没网卡驱动，提前把 `.inf/.sys` 放到能访问的位置。

---

## 5. 阶段 3 · 固化母盘

### 5a. 在物理系统里加启动项

```powershell
$Base = 'E:\VHD\Base.vhdx'

# 记录原超时
$prevTimeout = (bcdedit /enum '{bootmgr}' |
                Select-String 'timeout' |
                ForEach-Object { ($_ -split '\s+')[-1] })

# 找物理系统启动项做模板（device 为 partition= 且不含 vhd=/ramdisk=/locate=）
$all = (& bcdedit /enum all 2>&1) | Out-String
$chunks = [regex]::Split($all, "(?:\r?\n){2,}")
$templateId = $null
foreach ($c in $chunks) {
    if ($c -match 'Windows Boot Loader') {
        $id  = [regex]::Match($c, 'identifier\s+(\{[^}]+\})').Groups[1].Value
        $dev = [regex]::Match($c, '(?m)^device\s+(.+)$').Groups[1].Value.Trim()
        if ($dev -match '^partition=' -and $dev -notmatch 'vhd=|ramdisk=|locate=') {
            $templateId = $id; break
        }
    }
}

# 复制作模板 —— 输出语言随系统变，用正则抓 GUID
$out  = bcdedit /copy $templateId /d 'Win11-Base-VHD'
$guid = [regex]::Match(($out -join ' '), '\{[0-9a-fA-F-]{36}\}').Value

# 指向 Base.vhdx
bcdedit /set $guid device    "vhd=[E:]\VHD\Base.vhdx"
bcdedit /set $guid osdevice  "vhd=[E:]\VHD\Base.vhdx"
bcdedit /set $guid path      '\Windows\system32\winload.efi'

# ★ 必须回读验证！设不存在的盘符会静默失败
$chk = bcdedit /enum $guid | Out-String
if ($chk -notmatch 'vhd=') { throw 'VHD 指向设置失败' }

# 加菜单
bcdedit /displayorder $guid /addlast
bcdedit /timeout 30

# 记录
@{
    Guid            = $guid
    Description     = 'Win11-Base-VHD'
    Vhd             = 'vhd=[E:]\VHD\Base.vhdx'
    CreatedAt       = (Get-Date).ToString('s')
    PreviousTimeout = $prevTimeout
} | ConvertTo-Json | Set-Content 'E:\VHD\entry-base.json' -Encoding UTF8
```

**对应脚本**：`scripts\03-add-base-entry.ps1`

**实测结果**（真实 `entry-base.json`）：

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

### 5b. 重启进入母盘，配置

选 `Win11-Base-VHD`，走 OOBE，装好预装软件。

**建议只装系统级的东西：** 运行时、驱动、开发工具链。
依赖特定用户配置的软件会在 sysprep 后失效。

### 5c. 封箱

```powershell
# 在母盘系统内部，管理员
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

> 用 `/shutdown`（关机），不是 `/reboot`。
> 会删除所有用户配置文件。

### 5d. 回到物理系统，设只读

```powershell
attrib +r "E:\VHD\Base.vhdx"
(Get-Item 'E:\VHD\Base.vhdx').IsReadOnly    # 必须 True
```

**对应脚本**：`scripts\04-seal-base.ps1`

> **硬性要求。** 父盘可写 = 所有子盘失效。

---

## 6. 阶段 4 · 派生 Work

```powershell
$Base = 'E:\VHD\Base.vhdx'
$Work = 'E:\VHD\Work.vhdx'

if (Test-Path $Work) { throw 'Work.vhdx 已存在' }
if (-not (Get-Item $Base).IsReadOnly) { throw 'Base.vhdx 不是只读' }

$dp = Join-Path $env:TEMP 'mkwork.txt'
@("create vdisk file=`"$Work`" parent=`"$Base`"") | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force
```

**验证（不用 Hyper-V 模块）：**

```powershell
$dp = Join-Path $env:TEMP 'chk.txt'
@("select vdisk file=`"$Work`"", 'detail vdisk') | Set-Content $dp -Encoding ASCII
$r = diskpart /s $dp | Out-String
Remove-Item $dp -Force

$r -match 'Is Child:\s+Yes'                                    # True
[regex]::Match($r, 'Parent Filename:\s*(.+)').Groups[1].Value  # Base.vhdx 路径
$r -match 'Virtual size:\s+384 GB'                             # 与父盘一致
```

**对应脚本**：`scripts\05-create-work.ps1`

---

## 7. 阶段 5 · 挂进启动菜单

```powershell
$Work = 'E:\VHD\Work.vhdx'

$prevTimeout = (bcdedit /enum '{bootmgr}' | Select-String 'timeout' |
                ForEach-Object { ($_ -split '\s+')[-1] })

$out  = bcdedit /copy $templateId /d 'Win11-Work'
$guid = [regex]::Match(($out -join ' '), '\{[0-9a-fA-F-]{36}\}').Value

bcdedit /set $guid device    "vhd=[E:]\VHD\Work.vhdx"
bcdedit /set $guid osdevice  "vhd=[E:]\VHD\Work.vhdx"
bcdedit /set $guid path      '\Windows\system32\winload.efi'
bcdedit /displayorder $guid /addlast
bcdedit /timeout 30

# 回读验证
$chk = bcdedit /enum $guid | Out-String
if ($chk -notmatch 'vhd=') { throw 'VHD 指向设置失败' }

# 记录（含母盘指纹）
$bf = Get-Item 'E:\VHD\Base.vhdx'
@{
    WorkGuid        = $guid
    Description     = 'Win11-Work'
    BasePath        = 'E:\VHD\Base.vhdx'
    WorkPath        = 'E:\VHD\Work.vhdx'
    BaseLength      = $bf.Length
    BaseWriteTicks  = $bf.LastWriteTimeUtc.Ticks
    PreviousTimeout = $prevTimeout
    CreatedAt       = (Get-Date).ToString('s')
} | ConvertTo-Json | Set-Content 'E:\VHD\entry-work.json' -Encoding UTF8
```

**对应脚本**：`scripts\05-create-work.ps1`

**实测结果**（真实 `entry-work.json`）：

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
    "CreatedAt":  "2026-10-17T00:10:46"
}
```

> **`BaseLength` + `BaseWriteTicks` 是母盘指纹。**
> 每次重置前比对，变了就警告"已有子盘可能打不开"。

**可选：把母盘移出菜单**

```powershell
bcdedit /displayorder $BaseGuid /remove    # 只移出菜单，启动项保留
```

---

## 8. 完整验证

构建完成后逐项核对：

```powershell
# 1. 差分盘属性
$dp = Join-Path $env:TEMP 'v.txt'
@("select vdisk file=`"E:\VHD\Work.vhdx`"", 'detail vdisk') | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force
# 必须：Is Child: Yes / Parent = Base.vhdx / Virtual size 与父盘一致

# 2. 父盘只读
(Get-Item 'E:\VHD\Base.vhdx').IsReadOnly      # True

# 3. 启动项
bcdedit /enum all | Select-String 'Work.vhdx|Base.vhdx'

# 4. ★ 链完整性（最关键）
Mount-DiskImage -ImagePath 'E:\VHD\Work.vhdx' -Access ReadOnly
Start-Sleep 3
$d = Get-DiskImage -ImagePath 'E:\VHD\Work.vhdx' | Get-Disk
# ★ 不要用 Type -eq 'Basic' 过滤！VHD 内分区类型可能是 IFS
$p = Get-Partition -DiskNumber $d.Number |
     Where-Object { $_.Size -gt 50MB } |
     Sort-Object Size -Descending | Select-Object -First 1
if (-not $p.DriveLetter) {
    Add-PartitionAccessPath -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -AssignDriveLetter
    Start-Sleep 2
    $p = Get-Partition -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber
}
"winload.efi 可读 = " + (Test-Path "$($p.DriveLetter):\Windows\System32\winload.efi")
Dismount-DiskImage -ImagePath 'E:\VHD\Work.vhdx'
# 最后一项必须 True
```

**全部通过 → 重启，选 `Win11-Work`。**

---

## 下一步

- [避坑指南（强烈建议先读）](04-pitfalls.md)
- [日常使用](05-daily-use.md)
- [排错](06-troubleshooting.md)
