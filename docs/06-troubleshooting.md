# 排错

> 症状 → 原因 → 处理。带错误码的直接查。

## 目录

1. [启动阶段错误码](#1-启动阶段错误码)
2. [脚本报错](#2-脚本报错)
3. [挂载与识别问题](#3-挂载与识别问题)
4. [容量与性能](#4-容量与性能)
5. [紧急恢复](#5-紧急恢复)

---

## 1. 启动阶段错误码

### `0xc000000f` — 找不到启动文件

```
File: \Windows\system32\winload.efi
Status: 0xc000000f
The Boot Configuration Data for your PC is misssing or contains errors.
```

| 原因 | 判断 | 处理 |
|---|---|---|
| 母盘被改名/移动 | `Test-Path E:\VHD\Base.vhdx` 为 false | 改回原名 |
| 母盘被删除 | 同上 | 从备份恢复 |
| VHD 内未写引导 | 只读挂载后 `winload.efi` 不存在 | 重新 `bcdboot` |

**排查：**

```powershell
# 1) 母盘在不在
Test-Path 'E:\VHD\Base.vhdx'

# 2) 子盘链是否完好
$dp = Join-Path $env:TEMP 'c.txt'
@("select vdisk file=`"E:\VHD\Work.vhdx`"", 'detail vdisk') | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force
# 看 Is Child: Yes 和 Parent Filename
```

### `0xc0000225` — BCD 指向错误

| 原因 | 处理 |
|---|---|
| `device` 里的盘符不存在 | 确认数据盘已挂载 |
| BCD 被误改 | `bcdedit /import <备份>` |

```powershell
# 看当前启动项指向
bcdedit /enum '{current}' /v
# 关注 device / osdevice
```

### `0xc0000001` — 设备无法访问

通常是 VHD 挂载失败或文件系统损坏。

```powershell
# 只读挂载看能不能读
Mount-DiskImage -ImagePath 'E:\VHD\Work.vhdx' -Access ReadOnly
# 能挂上 → 文件没坏，是启动配置问题
# 挂不上 → 文件可能真坏了，从备份恢复
```

### 蓝屏 `UNMOUNTABLE_BOOT_VOLUME`

**最严重的情况。** 通常意味着：

- 父盘被修改过（只读被取消）
- 文件系统损坏

**处理：**

```
1. 回物理系统
2. 检查母盘指纹是否变了
3. 如果母盘完好 → 重置 Work（数据可能丢）
4. 如果母盘也坏了 → 从备份恢复母盘
```

### 无限循环"正在准备自动修复"

差分盘损坏。

```powershell
# 物理系统里重置
.\05-create-work.ps1 -Reset
```

---

## 2. 脚本报错

### 「当前系统是从 VHD 启动的（你在 Work 里）」

```
[FAIL] 当前系统是从 VHD 启动的（你在 Work 里）。
       必须在【物理 Windows】里运行本脚本。
```

**这是防护，不是 bug。**

```
重启 → 启动菜单选 "Windows 11"（无 VHD 后缀的那个）
```

**怎么确认：**

```powershell
(Get-Disk -Number (Get-Partition -DriveLetter C).DiskNumber).BusType
```

### 「找不到卷标为 'Data' 的卷」

```
[FAIL] 找不到卷标为 'Data' 的卷。请确认数据盘已挂载且有盘符。
```

**排查：**

```powershell
# 看现有卷
Get-Volume | Where-Object DriveLetter |
    Select-Object DriveLetter, FileSystemLabel, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}

# 没盘符的话在磁盘管理里分配
```

**解决（二选一）：**

```powershell
# A) 改卷标
Set-Volume -DriveLetter E -NewFileSystemLabel Data

# B) 所有命令都加参数
.\00-check.ps1 -DataLabel "你的卷标"
```

### 「盘符 X: 不存在」

脚本的主动防护（对应 [pitfalls #14](04-pitfalls.md)）。

**原因：** 数据盘没挂载，或盘符变了。

**处理：** 确认 `Get-Volume` 里能看到数据盘，且有盘符。

### 「设置 VHD 指向失败（bcdedit 静默忽略）」

脚本已自动回滚（删了无效项）。

**原因：** 同上，盘符问题。

### 「链检查失败：分区里缺少 Windows\System32\winload.efi」

| 原因 | 验证 | 处理 |
|---|---|---|
| 母盘里没部署 Windows | 只读挂载 Base，看 `winload.efi` | 重新部署 + `bcdboot` |
| `bcdboot` 没执行 | 同上 | 在 VHD 内执行 `bcdboot` |
| 母盘损坏 | 挂不上 | 从备份恢复 |

**验证母盘：**

```powershell
Mount-DiskImage -ImagePath 'E:\VHD\Base.vhdx' -Access ReadOnly
Start-Sleep 3
$d = Get-DiskImage -ImagePath 'E:\VHD\Base.vhdx' | Get-Disk
$p = Get-Partition -DiskNumber $d.Number |
     Where-Object { $_.Size -gt 50MB } | Sort-Object Size -Descending |
     Select-Object -First 1
if (-not $p.DriveLetter) {
    Add-PartitionAccessPath -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -AssignDriveLetter
    Start-Sleep 2
    $p = Get-Partition -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber
}
Get-ChildItem "$($p.DriveLetter):\Windows\System32\winload.efi"
Dismount-DiskImage -ImagePath 'E:\VHD\Base.vhdx'
```

### 「父盘不是只读」

```powershell
attrib +R "E:\VHD\Base.vhdx"
(Get-Item 'E:\VHD\Base.vhdx').IsReadOnly   # True
```

### 「禁止创建孙盘」

父盘本身是差分盘。

**正确结构：**

```
Base.vhdx（独立盘）→ Work.vhdx（差分盘）
```

**不是：**

```
Base.vhdx → Work.vhdx → Work2.vhdx   ❌
```

---

## 3. 挂载与识别问题

### 「无法装载，文件被占用」

```
Mount-DiskImage : 无法装载，因为文件已被另一进程使用
```

| 原因 | 处理 |
|---|---|
| 快速启动未关 | `powercfg /hibernate off` + 注册表置 0 |
| 该 VHD 是当前系统盘 | 正常，无法分离 |
| 另一进程持有 | `Get-Process` 查，或重启 |

### 「A virtual disk support provider for the specified file was not found」

**扩展名不是 `.vhdx` / `.vhd`。**

见 [pitfalls #6](04-pitfalls.md)。

```powershell
# 错误
Work.backup-20261026.bak

# 正确
Work.backup-20261026.bak.vhdx
```

### 「DiskPart has encountered an error: The file or directory is corrupted and unreadable」

**先别急，很可能只是扩展名问题。**

```powershell
# 测试：复制一份改成 .vhdx 再试
Copy-Item 'E:\VHD\Work.initial.bak' 'E:\VHD\_test.vhdx'
# 能 select 就说明原文件没坏
```

如果改名后仍然报错，才是真的损坏。

### 挂载后没出现盘符

| 原因 | 处理 |
|---|---|
| 等的时间不够 | 盘符分配不是瞬时的，等 5-30 秒 |
| 分区表异常 | 看 `Get-Partition -DiskNumber N` |
| 按 `Type -eq 'Basic'` 过滤了 | **去掉这个过滤**，见 pitfalls #13 |

```powershell
# 手动分配盘符
$d = Get-DiskImage -ImagePath 'E:\VHD\Work.vhdx' | Get-Disk
Get-Partition -DiskNumber $d.Number | Select-Object PartitionNumber, Type, Size, DriveLetter
# 看到 Type = IFS 是正常的
Add-PartitionAccessPath -DiskNumber $d.Number -PartitionNumber 1 -AssignDriveLetter
```

### `Get-VHD` 报权限错误

```
You do not have the required permission to complete this task.
```

**改用 `diskpart`。** 见 [pitfalls #5](04-pitfalls.md)。

```powershell
$dp = Join-Path $env:TEMP 'v.txt'
@("select vdisk file=`"E:\VHD\Work.vhdx`"", 'detail vdisk') | Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force
```

---

## 4. 容量与性能

### Work.vhdx 越来越大

正常现象。见 [pitfalls #9](04-pitfalls.md)。

```powershell
# 必须在物理系统，Work 关机
Optimize-VHD -Path 'E:\VHD\Work.vhdx' -Mode Full
```

### `Optimize-VHD` 报“磁盘正在使用”

```
Cannot optimize a virtual disk that is in use
```

| 原因 | 处理 |
|---|---|
| 当前系统盘 | 回物理系统 |
| VHD 已挂载 | `Dismount-DiskImage` |

### 启动变慢

| 原因 | 处理 |
|---|---|
| 差分链太深（虽然只允许一层） | 确认没有孙盘 |
| 母盘碎片化 | 难以解决，建议重建母盘 |
| 磁盘本身慢 | 硬件问题 |

---

## 5. 紧急恢复

### 场景 A：启动菜单消失

```powershell
# 物理系统 → UEFI 固件或 PE 里
bcdedit /enum all

# 如果 BCD 完全读不到：
bcdedit /import "E:\VHD\Logs\BCD_Backup_xxx" /clean
```

### 场景 B：BCD 彻底坏了

```powershell
# ⚠️ 核选项：清空现有 BCD 再导入
bcdedit /import "E:\VHD\Logs\BCD_Backup_20261016-060305" /clean

# 或者用启动修复
bootrec /rebuildbcd
```

### 场景 C：Work 启动不了但母盘完好

```powershell
# 物理系统里重置
.\05-create-work.ps1 -Reset
```

**数据会丢，但系统能回来。**

### 场景 D：母盘也坏了

```powershell
# 从备份恢复
Copy-Item 'E:\VHD\Base.backup-xxx.bak.vhdx' 'E:\VHD\Base.vhdx'
attrib +R 'E:\VHD\Base.vhdx'

# 重建 Work
.\05-create-work.ps1 -Reset
```

### 场景 E：一切都没了

```
从头开始：01 → 02 → 03 → 04 → 05
```

**这正是这套方案的好处：重建只是跑一遍脚本。**

---

## 排查通用步骤

```
1. 我在哪个系统？
   (Get-Disk -Number (Get-Partition -DriveLetter C).DiskNumber).BusType

2. 母盘在不在、是不是只读？
   Get-Item 'E:\VHD\Base.vhdx' | Select Length, IsReadOnly

3. 子盘属性对不对？
   diskpart: select vdisk + detail vdisk

4. 链能不能读到文件？
   Mount-DiskImage -Access ReadOnly + Test-Path winload.efi

5. BCD 指向对不对？
   bcdedit /enum '{current}' /v

6. 有备份吗？
   Get-ChildItem 'E:\VHD\Logs' -Filter 'BCD_Backup_*'
```

---

## 附：快速诊断脚本

```powershell
# 一次性收集所有关键信息
$out = @()
$out += '===== 系统 ====='
$out += "SystemDrive : $env:SystemDrive"
$sp = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
$sd = Get-Disk -Number $sp.DiskNumber
$out += "BusType     : $($sd.BusType)"
$out += "InVhd       : $($sd.BusType -match 'Virtual')"

$out += ''
$out += '===== 卷 ====='
Get-Volume | Where-Object DriveLetter | ForEach-Object {
    $out += ("{0}: {1}  {2} GB free" -f $_.DriveLetter, $_.FileSystemLabel, [math]::Round($_.SizeRemaining/1GB,1))
}

$out += ''
$out += '===== VHD ====='
$dv = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'Data' -and $_.DriveLetter })
if ($dv.Count -eq 1) {
    $vd = "$($dv[0].DriveLetter):\VHD"
    Get-ChildItem $vd -Filter '*.vhdx' -File -EA SilentlyContinue | ForEach-Object {
        $f = Join-Path $env:TEMP ('p_' + [guid]::NewGuid().ToString('N') + '.txt')
        @("select vdisk file=`"$($_.FullName)`"", 'detail vdisk') | Set-Content $f -Encoding ASCII
        $r = diskpart /s $f | Out-String
        Remove-Item $f -Force -EA SilentlyContinue
        $t = if ($r -match 'Is Child:\s+Yes') { 'DIFF' } else { 'BASE' }
        $p = [regex]::Match($r, '(?m)^Parent Filename:\s*(.+)$').Groups[1].Value.Trim()
        $out += ("{0,-40} {1,8:N2} GB  {2}  RO={3}" -f $_.Name, ($_.Length/1GB), $t, $_.IsReadOnly)
        if ($p) { $out += "     parent: $p" }
    }
}

$out += ''
$out += '===== BCD ====='
$raw = (& bcdedit /enum all 2>&1) | Out-String
[regex]::Split($raw, '(?:\r?\n){2,}') | Where-Object { $_ -match 'Windows Boot Loader' } | ForEach-Object {
    $id = [regex]::Match($_, 'identifier\s+(\{[^}]+\})').Groups[1].Value
    $dev = [regex]::Match($_, '(?m)^device\s+(.+)$').Groups[1].Value.Trim()
    $desc = [regex]::Match($_, '(?m)^description\s+(.+)$').Groups[1].Value.Trim()
    $out += ("{0,-42} {1}" -f $id, $desc)
    $out += "     $dev"
}

$out | Tee-Object -FilePath "$env:TEMP\vhd-diag.txt"
Write-Host "`n已保存到 $env:TEMP\vhd-diag.txt" -ForegroundColor Cyan
```

**提 Issue 时附上这个输出。**
