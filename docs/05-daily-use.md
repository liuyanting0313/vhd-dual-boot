# 日常使用

## 目录

1. [开关机与切换](#1-开关机与切换)
2. [重置 Work](#2-重置-work)
3. [备份](#3-备份)
4. [压缩 Work](#4-压缩-work)
5. [多分支环境](#5-多分支环境)
6. [沙盒演练（强烈建议）](#6-沙盒演练强烈建议)

---

## 1. 开关机与切换

```
开机
  ↓
启动菜单（30 秒）
  ├─ Windows 11       物理系统（主用）
  └─ Win11-Work       工作系统（可折腾）
```

### 规则

| 规则 | 原因 |
|---|---|
| 同一时刻只能进一个 | 两个系统同时挂载同一 VHD 会损坏 |
| 切换需重启 | 没有热切换机制 |
| 切换前确认已分离 | `Dismount-DiskImage` |

### 确认当前在哪

```powershell
(Get-Disk -Number (Get-Partition -DriveLetter C).DiskNumber).BusType
# 'File Backed Virtual' → Work
# 'NVMe' / 'SATA'       → 物理系统
```

### 调整菜单等待时间

```powershell
# 查看当前
bcdedit /enum '{bootmgr}' | Select-String timeout

# 改成 60 秒
bcdedit /timeout 60
```

---

## 2. 重置 Work

**这是这套系统最大的价值：随时回到干净的母盘状态。**

### 用脚本（推荐）

```powershell
# 在【物理 Windows】里
.\05-create-work.ps1 -Reset
```

它会：

1. 检查不在 VHD 里
2. 校验母盘（只读、类型、指纹）
3. 检查有没有孙盘依赖
4. 旧 Work 改名 `Work.replaced-时间戳.vhdx`（**不删**）
5. 从 Base 派生新差分盘
6. **链检查**：只读挂载读 `winload.efi`
7. 失败自动把旧盘改回来

**BCD 不用改** —— 启动项指向文件名 `Work.vhdx`。

### 手动重置（等价操作）

```powershell
# 1. 备份旧盘（不要直接删）
Rename-Item 'E:\VHD\Work.vhdx' "Work.replaced-$(Get-Date -Format yyyyMMdd-HHmmss).vhdx"

# 2. 从 Base 重新派生
$dp = Join-Path $env:TEMP 'r.txt'
@("create vdisk file=`"E:\VHD\Work.vhdx`" parent=`"E:\VHD\Base.vhdx`"") |
    Set-Content $dp -Encoding ASCII
diskpart /s $dp
Remove-Item $dp -Force

# 3. 验证（见下文）
# 4. 重启，选 Win11-Work
```

### 重置后验证

```powershell
Mount-DiskImage -ImagePath 'E:\VHD\Work.vhdx' -Access ReadOnly
Start-Sleep 3
$d = Get-DiskImage -ImagePath 'E:\VHD\Work.vhdx' | Get-Disk
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
```

### 清理旧的重置盘

确认新 Work 用着没问题后：

```powershell
Get-ChildItem 'E:\VHD\Work.replaced-*.vhdx' |
    ForEach-Object { Remove-Item $_.FullName -Force }
```

---

## 3. 备份

### 为什么必须备份 Work，而不是 Base

反直觉的地方：

| | Base.vhdx | Work.vhdx |
|---|---|---|
| 内容 | 干净的 Windows | **你的所有工作和配置** |
| 能否重建 | ✅ 重建母盘是一个流程 | 只能从备份恢复 |
| 体积 | 固定 | 持续增长 |

**Base 重建靠流程，Work 重建靠备份。**

### 备份脚本

仓库不包含备份脚本（因为每个人的路径习惯不同），但核心逻辑：

```powershell
# 必须在物理 Windows，Work 必须关机
$src = 'E:\VHD\Work.vhdx'
$dst = 'E:\VHD\Work.backup-' + (Get-Date -Format 'yyyyMMdd') + '.bak.vhdx'

# 1. 确认未被占用
try {
    $fs = [IO.File]::Open($src, 'Open', 'Read', 'None')
    $fs.Close()
} catch { throw 'Work.vhdx 正被占用，不能安全备份' }

# 2. robocopy 无缓冲复制
$tmp = 'E:\VHD\_bak_tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
robocopy 'E:\VHD' $tmp 'Work.vhdx' /J /NP /R:1 /W:5 /NFL /NDL | Out-Null

# 3. 校验大小
$srcLen = (Get-Item $src).Length
$tmpFile = Join-Path $tmp 'Work.vhdx'
if ((Get-Item $tmpFile).Length -ne $srcLen) { throw '大小不一致' }
Move-Item $tmpFile $dst -Force
Remove-Item $tmp -Recurse -Force

# 4. SHA256 双向比对
$h1 = (Get-FileHash $src -Algorithm SHA256).Hash
$h2 = (Get-FileHash $dst -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw 'SHA256 不一致，副本可能损坏' }

# 5. 写元数据
@(
    "备份时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "源文件: $src",
    "备份文件: $dst",
    "大小(字节): $srcLen",
    "SHA256: $h1"
) | Set-Content "$dst.txt" -Encoding UTF8

# 6. ★ 关键：挂载验证副本真的能用
$mounted = $false
try {
    Mount-DiskImage -ImagePath $dst -Access ReadOnly -ErrorAction Stop | Out-Null
    $mounted = $true
    Start-Sleep 3
    $d = Get-DiskImage -ImagePath $dst | Get-Disk
    $p = Get-Partition -DiskNumber $d.Number |
         Where-Object { $_.Size -gt 50MB } | Sort-Object Size -Descending |
         Select-Object -First 1
    if (-not $p.DriveLetter) {
        Add-PartitionAccessPath -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -AssignDriveLetter
        Start-Sleep 2
        $p = Get-Partition -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber
    }
    if (Test-Path "$($p.DriveLetter):\Windows\System32\ntoskrnl.exe") {
        Write-Host '[OK] 副本已验证可读' -ForegroundColor Green
    } else {
        Write-Host '[WARN] 挂载成功但读不到系统文件' -ForegroundColor Yellow
    }
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $dst -ErrorAction SilentlyContinue }
}
```

### 备份策略建议

| 类型 | 频率 | 保留 |
|---|---|---|
| Work 快照 | 大变化前 | 2-3 份 |
| Base.vhdx | 重建母盘后立即 | 永久 |

**注意：** 每个 Work 备份都是完整副本（如 86 GB）。做多次会占很多空间。

---

## 4. 压缩 Work

### 什么时候需要

```powershell
# 对比：Work 文件大小 vs 系统内实际占用
$wf = (Get-Item 'E:\VHD\Work.vhdx').Length / 1GB
Write-Host "Work.vhdx = $([math]::Round($wf,2)) GB"

# 启动进 Work 跑：
# Get-PSDrive C | Select-Object Used, Free
```

如果两者差距大（>20%），就值得压。

### 操作

```powershell
# ★ 必须在物理 Windows，Work 必须关机
Optimize-VHD -Path 'E:\VHD\Work.vhdx' -Mode Full
```

需要 Hyper-V 模块：

```powershell
# 如果没有这个模块
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All
```

### 不要在这时压

- ❌ 在 Work 里（当前系统盘）
- ❌ Work.vhdx 被挂载时
- ❌ 没有备份时（先备份再压）

---

## 5. 多分支环境

### 建多个工作盘

```powershell
.\05-create-work.ps1 -WorkName Work-Dev  -Description "Win11-Dev"
.\05-create-work.ps1 -WorkName Work-Test -Description "Win11-Test"
```

结果：

```
        Base.vhdx（只读）
       ╱             ╲
  Work-Dev.vhdx   Work-Test.vhdx
```

启动菜单会出现 `Win11-Dev` 和 `Win11-Test`。**每个初始 4 MB。**

### 什么时候有用

- 一份用于开发，一份用于测试危险改动
- 不同项目的隔离环境
- 保留一个"干净验证盘"，出问题时可对照

### 空间提醒

虽然初始只有 4 MB，但**每个都会长大**。装同样多的东西，总占用接近 N 倍。

---

## 6. 沙盒演练（强烈建议）

第一次做之前，**强烈建议先在虚拟机里完整走一遍**。

### 能测什么

| 能测 | 不能测 |
|---|---|
| ✅ 建 VHD / 分区 / 格式化 | ❌ BCD 启动（需真机） |
| ✅ 差分盘派生 | ❌ sysprep 效果 |
| ✅ 链检查 | |
| ✅ 读写隔离 | |
| ✅ 重置流程 | |
| ✅ 几乎所有脚本逻辑 | |

### 最快演练方法（不用建虚拟机）

用 100-300 MB 的小盘，10 秒就能验证核心机制：

```powershell
$root = "$env:TEMP\sbx"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$parent = Join-Path $root 'p.vhdx'
$child  = Join-Path $root 'c.vhdx'

function DP([string[]]$l) {
    $f = Join-Path $env:TEMP ('dp_' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($f, (($l -join "`r`n") + "`r`nexit`r`n"), [Text.Encoding]::ASCII)
    try { diskpart /s $f | Out-String } finally { Remove-Item $f -Force -EA SilentlyContinue }
}

# 1) 建父盘
DP @("create vdisk file=`"$parent`" maximum=300 type=expandable",
     "select vdisk file=`"$parent`"", 'attach vdisk',
     'create partition primary', 'format fs=ntfs quick label=SBX',
     'assign letter=Z', 'detach vdisk') | Out-Null

# 2) 写入模拟的 winload.efi
Mount-DiskImage -ImagePath $parent -Access ReadWrite
Start-Sleep 3
New-Item -ItemType Directory -Force -Path 'Z:\Windows\System32' | Out-Null
'K' | Set-Content 'Z:\Windows\System32\winload.efi'
Dismount-DiskImage -ImagePath $parent

# 3) 父盘只读
Set-ItemProperty -LiteralPath $parent -Name IsReadOnly -Value $true

# 4) 派生子盘
DP @("create vdisk file=`"$child`" parent=`"$parent`"") | Out-Null

# 5) 验证属性
(DP @("select vdisk file=`"$child`"", 'detail vdisk')) -match 'Is Child:\s+Yes'

# 6) ★ 链检查：只读挂载子盘，能不能读到父盘的文件？
Mount-DiskImage -ImagePath $child -Access ReadOnly
Start-Sleep 3
$d = Get-DiskImage -ImagePath $child | Get-Disk
# 注意：不要用 Type -eq 'Basic' 过滤！
$p = Get-Partition -DiskNumber $d.Number |
     Where-Object { $_.Size -gt 50MB } | Sort-Object Size -Descending |
     Select-Object -First 1
if (-not $p.DriveLetter) {
    Add-PartitionAccessPath -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -AssignDriveLetter
    Start-Sleep 2
    $p = Get-Partition -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber
}
Write-Host "
t类型: $($p.Type)"          # 可能是 IFS
Write-Host "链检查: $(Test-Path "$($p.DriveLetter):\Windows\System32\winload.efi")"   # True
Dismount-DiskImage -ImagePath $child

# 7) 清理
Remove-Item $root -Recurse -Force
```

如果第 6 步返回 `True`，说明核心机制在你的环境上工作正常。

### 用虚拟机完整演练

1. 建一台 Win11 虚拟机
2. 给虚拟机加一块空虚拟硬盘（当作"数据盘"），卷标设为 `Data`
3. 把 `scripts\` 拷进去，跑 `00-check.ps1`
4. 跳过 BCD 相关的步骤（虚拟机里没法测），其余全部走一遍

---

## 下一步

- [排错](06-troubleshooting.md)
- [FAQ](FAQ.md)
