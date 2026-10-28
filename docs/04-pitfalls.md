# 避坑指南

> **建前必读。** 这 14 条每一条都对应一次真实踩坑，
> 其中 #13 和 #14 是整理这套工具时用沙盒实测新发现的。

## 速查表

| # | 坑 | 严重度 | 后果 |
|---|---|---|---|
| 1 | 在 Work 里重置 Work | 🔴 致命 | 试图删除运行中的系统盘 |
| 2 | 取消父盘只读 | 🔴 致命 | **所有子盘全部失效，不可修复** |
| 3 | 快速启动未关 | 🟠 阻塞 | VHD 挂载报"文件被占用" |
| 4 | 盘符写死 | 🟠 高 | 在 Work 里指向错盘 |
| 5 | 用 `Get-VHD` 检测 | 🟠 高 | 权限不足时静默返回空 |
| 6 | 备份文件叫 `.bak` | 🟡 中 | 无法挂载、无法验证 |
| 7 | sysprep 后启动母盘改东西 | 🟠 高 | 母盘不干净 |
| 8 | 创建孙盘 | 🟡 中 | 链脆弱、性能差 |
| 9 | 忽略 Work 增长 | 🟡 中 | 磁盘耗尽 |
| 10 | 手改 `locate=custom` | 🟠 高 | 启动失败 |
| 11 | 两系统同时挂载同一 VHD | 🔴 致命 | **数据损坏** |
| 12 | Windows 更新改了母盘 | 🟡 中 | 链不匹配 |
| 13 | 按 `Type -eq 'Basic'` 过滤分区 | 🟠 高 | **链检查必定失败** |
| 14 | 不验证 `bcdedit` 返回值 | 🟠 高 | **静默失败，启动不了** |

---

## 1. 🔴 绝不在 Work 里重置 Work

### 现象

在 Work 系统里跑重置脚本，试图删除或重建正在运行的自己的系统盘。

### 后果

- 轻：命令失败，无事发生
- 重：**Work 系统直接崩溃**，因为系统盘文件被删除/替换

### 防护

所有脚本开头都有：

```powershell
function Test-InVhd {
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $p = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $d = Get-Disk -Number $p.DiskNumber -ErrorAction Stop
        if ([string]$d.BusType -match 'Virtual') { return $true }
    } catch { }
    # 双保险：看 BCD
    $cur = (& bcdedit /enum '{current}' 2>&1) | Out-String
    if ($cur -match 'vhd=') { return $true }
    return $false
}

# 每个脚本开头
if (Test-InVhd) {
    Write-Host '当前系统从 VHD 启动（你在 Work 里），必须回到物理 Windows。'
    exit 1
}
```

**但如果你绕过脚本手动跑 `diskpart`，就没有任何保护。**

### 怎么判断自己在哪

```powershell
(Get-Disk -Number (Get-Partition -DriveLetter C).DiskNumber).BusType
# 'File Backed Virtual' → 你在 Work 里
# 'NVMe' / 'SATA'       → 你在物理系统
```

---

## 2. 🔴 父盘只读不能取消

### 现象

```powershell
# 想改母盘内容，取消了只读
attrib -r "E:\VHD\Base.vhdx"
```

### 后果

**所有基于它的差分盘全部失效，且不可修复。**

原因：差分盘的 copy-on-write 依赖"父盘永远不变"这个前提。
父盘一变，所有子盘记录的"差异"就失去了基准。

典型报错：

```
The chain of virtual hard disks is broken. The system cannot locate
or open the parent virtual hard disk for the differencing disk.
```

或者启动时蓝屏 `UNMOUNTABLE_BOOT_VOLUME`。

### 防护

```powershell
# 任何时候都应该 True
(Get-Item 'E:\VHD\Base.vhdx').IsReadOnly

# 创建差分盘前强制检查
if (-not (Get-Item $Base).IsReadOnly) {
    throw '父盘不是只读，未提供'
}
```

`lib\Common.ps1` 里的 `New-DifferencingVhd` 会自动设只读。

### 真需要改母盘内容

唯一安全做法：

1. 取消只读
2. 启动母盘，改东西
3. **重新 sysprep**
4. 重新设只读
5. **重新派生所有子盘**（旧子盘已失效）

这就是为什么建议母盘一次性做好。

---

## 3. 🟠 快速启动必须关

### 现象

```powershell
Mount-DiskImage : 无法装载，文件被占用
```

### 原因

`HiberbootEnabled = 1` 时，关机是"混合关机"（hiberboot），
系统会把内核状态写入 `hiberfil.sys`，**VHD 文件句柄不释放**。

### 解决

```powershell
powercfg /hibernate off
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -Value 0 -Type DWord
```

### 回滚

```powershell
powercfg /hibernate on
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name HiberbootEnabled -Value 1 -Type DWord
```

`99-rollback.ps1 -Env` 会从 `state.json` 读原值恢复。

---

## 4. 🟠 盘符陷阱（最容易搞错）

### 现象

同一块数据盘，在两个系统里盘符不同：

| | 物理 Windows | Work |
|---|---|---|
| 数据盘（卷标 `Data`） | **`D:`** | **`E:`** |
| 系统盘 | `C:` | `C:`（VHD 内部分区） |

### 后果

脚本写死 `D:\VHD` 在 Work 里会指向**物理 C 盘**，
在那里创建目录，产生垃圾数据（本项目就是踩了这个坑）。

### 正确写法

```powershell
# ✅ 用卷标定位
$v = @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'Data' -and $_.DriveLetter })
if ($v.Count -ne 1) { throw "需要恰好 1 个卷标为 Data 的卷" }
$dir = "$($v[0].DriveLetter):\VHD"

# ❌ 写死盘符
$dir = 'D:\VHD'
```

### 为什么换盘符也不影响启动

因为 VHDX 内部用**卷 GUID** 引用父盘，不是盘符：

```
volume_path : \\?\Volume{79e9bac7-a3ad-4262-a557-d4134770d729}\VHD\Base.vhdx
```

**但文件名和相对位置不能变。**

---

## 5. 🟠 `Get-VHD` 需要 Hyper-V 管理员权限

### 现象

```powershell
# 看起来“没有 VHD”
@(Get-VHD -ErrorAction SilentlyContinue ...)
# 返回空数组

# 直接调用就报错
Get-VHD -Path 'E:\VHD\Work.vhdx'
# You do not have the required permission to complete this task.
```

### 后果

把"没权限"误判为"没有这个东西"。

**本项目早期就踩过这个坑**：一个脚本用 `Get-VM -ErrorAction SilentlyContinue` 判断
"有没有虚拟机在跑"，权限不足时永远返回空，于是每次都判定"没人用"，
把自己建的目录联接秒删了。

### 正确做法

```powershell
# ✅ 用 diskpart，任何权限都能用
$dp = Join-Path $env:TEMP ('dp_' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($dp,
        ("select vdisk file=`"$Path`"`r`ndetail vdisk`r`nexit`r`n"),
        [Text.Encoding]::ASCII)
    $r = diskpart /s $dp | Out-String
} finally { Remove-Item $dp -Force -ErrorAction SilentlyContinue }

# 解析
$isChild = $r -match 'Is Child:\s+Yes'
$parent  = [regex]::Match($r, 'Parent Filename:\s*(.+)').Groups[1].Value.Trim()
$vsize   = [regex]::Match($r, 'Virtual size:\s+(\d+)\s*(\w+)')
```

### 原则

> **权限不足 = 未知，未知要按"占用/危险"处理，绝不能当成"安全/空闲"。**

---

## 6. 🟡 备份文件不能叫 `.bak`

### 实测数据

| 扩展名 | `Mount-DiskImage` | `diskpart` |
|---|---|---|
| `.bak` | ❌ A virtual disk support provider ... not found | ❌ |
| `.bck` | ❌ 同上 | ❌ |
| `.vhdx2` | ❌ 同上 | ❌ |
| `.bak.vhdx` | ✅ 成功 | ✅ 成功 |

### 后果

备份完成后无法验证（挂不上），将来恢复时也无法直接挂载。
等于这个备份"能不能用"是个未知数。

### 正确命名

```
✅ Work.backup-20261026.bak.vhdx
✅ Work.VS-tools.20261026.bak.vhdx
❌ Work.VS-tools.20261026.bak
```

**必须以 `.vhdx` 结尾。** 中间叫什么随便。

### 一个真实教训

备份一个 6.22 GB 的初始盘，命名为 `Work.initial.bak`。
后来用 `diskpart` 探测时报：

```
DiskPart has encountered an error: The file or directory is corrupted and unreadable.
```

差点以为文件坏了。实际只是**扩展名不被识别**。
改成 `.vhdx` 后完全正常，能正常挂载、正常读文件。

---

## 7. 🟠 sysprep 后不要再启动母盘改东西

### 现象

`sysprep /generalize /oobe` 后母盘进入 OOBE。你又启动它，配了点东西，关机。
然后从这个母盘派生 Work。

### 后果

**那次配置会被带入所有派生的 Work。** 母盘不再"干净"。

更麻烦的是：如果那次启动让系统完成了 OOBE（建了用户、生成了新 SID），
sysprep 的效果就没了。

### 正确做法

```
sysprep /generalize /oobe /shutdown
     ↓
立刻在物理系统里设只读（04-seal-base.ps1）
     ↓
立刻派生 Work（05-create-work.ps1）
     ↓
再也不启动母盘
```

### 怎么知道母盘有没有被动过

`04-seal-base.ps1` 会记录指纹：

```json
{
    "Sealed_BaseLength": 51167363072,
    "Sealed_BaseWriteTicks": 639277735280219577,
    "Sealed_BaseWriteTime": "2026-10-16 11:52:08"
}
```

`05-create-work.ps1` 每次都会比对，不一致会警告。

---

## 8. 🟡 不要创建孙盘

### 什么是孙盘

```
Base.vhdx → Work.vhdx → Work-deep.vhdx
  父盘         子盘           孙盘
```

### 后果

- 每读一个块要多查一层索引，链越深越慢
- 任何一层损坏，后面全部失效
- 重置 Work 会让所有孙盘失效

### 防护

```powershell
# 拒绝把差分盘当父盘
$pi = Get-VhdInfo $ParentPath
if ($pi.Type -eq 'Differencing') {
    throw '父盘本身是差分盘 —— 禁止创建孙盘'
}

# 重置前检查有没有孙盘
Get-ChildItem (Split-Path $Work) -Filter '*.vhdx' | ForEach-Object {
    $ci = Get-VhdInfo $_.FullName
    if ($ci.Ok -and (Test-SamePath $ci.Parent $Work)) { $deps.Add($_.Name) }
}
if ($deps.Count -gt 0) { throw "这些子盘以 Work 为母盘，重置会让它们失效" }
```

### 正确多分支方式

```
        Base.vhdx
       ╱    │    ╲
   Work1  Work2  Work3     ← 平行关系，不是子子孙孙
```

---

## 9. 🟡 Work 只增不减

### 现象

```
C: 实际已用 91 GB
Base.vhdx   47.65 GB
Work.vhdx   86.17 GB
合计       133.82 GB   ← 多出 42 GB
```

### 原因

差分盘记录"写过的块"。删文件时，块已分配但不会回收。

### 解决

```powershell
# ★ 必须在物理系统里，Work 必须关机
Optimize-VHD -Path 'E:\VHD\Work.vhdx' -Mode Full
```

`Optimize-VHD` 要求虚拟磁盘**未挂载或以只读方式挂载**。
你想压缩 Work，就得先把它关机。

### 压缩模式选择

| 模式 | 说明 | 前提 |
|---|---|---|
| `Quick` | 回收未用块 + 不扫零块 | 只读挂载 |
| `Retrim` | 只发送 retrim | 只读挂载 |
| `Full` | 扫描零块 + 回收，最彻底 | 未挂载或只读挂载 |
| `Prezeroed` | 不扫 NTFS 空闲空间 | 无需只读 |

**推荐 `Full`。**

---

## 10. 🟠 不要手动编辑 `locate=custom`

### BCD 里的真实内容

```
device    vhd=[E:]\VHD\Work.vhdx,locate=custom:12000002
osdevice  vhd=[E:]\VHD\Work.vhdx,locate=custom:22000002
```

### 为什么不能改

`locate=custom:...` 是 Windows 自动维护的定位参数。
手动改它会导致 bootmgr 找不到 VHD。

### 正确做法

```powershell
# ✅ 整体覆盖，让 Windows 自己重建 locate 参数
bcdedit /set {guid} device "vhd=[E:]\VHD\Work.vhdx"

# ❌ 试图只改后缀
bcdedit /set {guid} device "vhd=[E:]\VHD\Work.vhdx,locate=custom:99999999"
```

---

## 11. 🔴 两个系统不能同时挂载同一 VHD

### 场景

在物理系统里挂载了 `Work.vhdx` 看文件，没分离，直接重启进 Work。

### 后果

- 轻：Work 启动失败
- 重：**文件系统损坏**，两边都可能丢数据

### 防护

```powershell
# 切换系统前必须分离
Dismount-DiskImage -ImagePath 'E:\VHD\Work.vhdx'

# 确认
(Get-DiskImage -ImagePath 'E:\VHD\Work.vhdx').Attached   # False
```

`lib\Common.ps1` 里 `Dismount-VhdSafely` 会重试 5 次。

---

## 12. 🟡 Windows 更新可能破坏母盘

### 原因

母盘是"某个时间点"的快照。如果 Windows 更新改动了引导文件
（`winload.efi`、`bootmgr`、`BCD`），可能导致子盘的引导链不匹配。

### 建议

**母盘封箱后就不再更新它。**

Work 里正常接收更新没问题（更新只写进 Work 的差分层）。

---

## 13. 🟠 【实测新发现】分区类型陷阱

> 这个问题是整理本工具时用沙盒实测发现的，
> 原环境的 `Reset-Work.ps1` 里就有这个隐患。

### 现象

链检查永远失败，报：

```
挂载成功但 20 秒内没有出现盘符
```

### 根因

VHD 内的系统分区类型是 **`IFS`**，不是 `Basic`。

实测数据：

```
磁盘 3  BusType = File Backed Virtual
  part1 type=IFS    size=298.9 MB   letter=[Z]
```

### 错误写法

```powershell
# ❌ 永远返回 $null
$p = Get-Partition -DiskNumber $d.Number |
     Where-Object { $_.Type -eq 'Basic' } |
     Sort-Object Size -Descending | Select-Object -First 1

if ($p) { ... }   # 永远不会进入
```

### 正确写法

```powershell
# ✅ 按大小找，不按类型过滤
$parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
$cand = @($parts | Where-Object { $_.Size -gt 50MB } | Sort-Object Size -Descending)
$mainPartition = if ($cand.Count -gt 0) { $cand[0] } else { $parts | Sort-Object Size -Descending | Select-Object -First 1 }
```

### 已修复

`lib\Common.ps1` 的 `Get-VhdMainPartition` 已按正确方式实现。

### 怎么验证自己的写法对不对

```powershell
# 挂载任意 VHD，看分区类型
Mount-DiskImage -ImagePath 'E:\VHD\Work.vhdx' -Access ReadOnly
$d = Get-DiskImage -ImagePath 'E:\VHD\Work.vhdx' | Get-Disk
Get-Partition -DiskNumber $d.Number | Select-Object PartitionNumber, Type, Size, DriveLetter
Dismount-DiskImage -ImagePath 'E:\VHD\Work.vhdx'
```

如果看到 `Type = IFS`，就明白为什么不能用 `Basic` 过滤了。

---

## 14. 🟠 【实测新发现】`bcdedit` 静默失败

> 同样是用 BCD 副本实验实测发现的。

### 现象

```powershell
# X: 盘不存在
bcdedit /set {guid} device 'vhd=[X:]\VHD\Base.vhdx'

# 退出码 0，无任何报错
$LASTEXITCODE    # 0

# 但回读发现根本没生效：
bcdedit /enum {guid}
#   device    partition=D:        ← 还是模板的原值！
#   osdevice  partition=D:
```

### 后果

脚本以为设好了，实际启动项仍指向物理系统。**重启后进入的是物理 Windows，不是 Work。**

### 实测对比

| 用法 | 结果 |
|---|---|
| `vhd=[X:]\...`（X 不存在） | ❌ 静默失败 |
| `vhd=X:\...`（无方括号） | ❌ 静默失败 |
| `vhd=[E:]\...`（E 存在） | ✅ 成功 |

### 正确做法

**三道防护：**

```powershell
# 1) 设置前检查盘符真实存在
$m = [regex]::Match($VhdPath, '^\[([A-Za-z]):\]')
if ($m.Success) {
    $letter = $m.Groups[1].Value.ToUpper()
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $vol) {
        throw "盘符 $letter`: 不存在，bcdedit 会静默忽略。"
    }
}

# 2) 设置后回读验证
bcdedit /set $guid device "vhd=$VhdPath"
bcdedit /set $guid osdevice "vhd=$VhdPath"

$chk = (& bcdedit /enum $guid 2>&1) | Out-String
$devLine = [regex]::Match($chk, '(?m)^device\s+(.+)$').Groups[1].Value.Trim()
$osLine  = [regex]::Match($chk, '(?m)^osdevice\s+(.+)$').Groups[1].Value.Trim()

if ($devLine -notmatch 'vhd=' -or $osLine -notmatch 'vhd=') {
    # 3) 失败就删掉这个无效项，不污染 BCD
    bcdedit /delete $guid | Out-Null
    throw "设置失败（已回滚）：device=$devLine  osdevice=$osLine"
}
```

`lib\Common.ps1` 的 `New-VhdBootEntry` 已包含全部三道防护。

### 已修复

### 通用教训

> **凡是系统命令，不能只看退出码，必须回读验证。**

---

## 附：一句话总结

```
父盘只读  ·  不改父盘名  ·  不同时挂载
  ↓            ↓              ↓
三个铁律，违反任何一个 Work 都启动不了
但——只要 Base.vhdx 在，Work 随时能重建
```

---

## 下一步

- [日常使用](05-daily-use.md)
- [排错](06-troubleshooting.md)
