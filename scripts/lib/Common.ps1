<#
lib\Common.ps1 — 公共函数库
所有关键函数均已在沙盒中验证通过（2026-10-28）

设计原则（都是实测踩出来的坑）：
  1. 用卷标定位数据盘，不写死盘符（物理系统里是 D:，Work 里是 E:）
  2. 不用 Get-VHD —— 它需要 Hyper-V 管理员权限，普通权限下会静默返回空。
     改用 diskpart，任何权限都能用。
  3. 链检查不按 Partition.Type -eq 'Basic' 过滤 ——
     VHD 内的系统分区类型可能是 IFS，按 Basic 过滤会永远找不到分区。
  4. 挂载后等盘符要够久（默认 30 秒），盘符分配不是瞬时的。
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# 确保中文在控制台正确显示（防乱码）
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch { }

# ============================================================
# 输出
# ============================================================
function Write-Step { param([string]$Msg)
    Write-Host ''
    Write-Host ('=== ' + $Msg + ' ===') -ForegroundColor Cyan
}
function Write-Ok    { param([string]$Msg) Write-Host ('  [OK]   ' + $Msg) -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host ('  [WARN] ' + $Msg) -ForegroundColor Yellow }
function Write-Err2  { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host ('         ' + $Msg) -ForegroundColor Gray }

# ============================================================
# 权限与环境
# ============================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        Write-Err2 '需要管理员权限。请右键 PowerShell -> 以管理员身份运行。'
        throw 'NotAdministrator'
    }
}

function Test-InVhd {
    <# 返回 $true 表示当前系统从 VHD 启动（即在 Work 里） #>
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $p = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $d = Get-Disk -Number $p.DiskNumber -ErrorAction Stop
        if ([string]$d.BusType -match 'Virtual') { return $true }
    } catch { }
    $cur = (& bcdedit /enum '{current}' 2>&1) | Out-String
    if ($cur -match 'vhd=') { return $true }
    return $false
}

function Assert-PhysicalSystem {
    <# 关键防护：绝不允许在 Work 里操作 VHD 链 #>
    if (Test-InVhd) {
        Write-Err2 '当前系统是从 VHD 启动的（你在 Work 里）。'
        Write-Info '必须在【物理 Windows】里运行本脚本。'
        Write-Info '请重启，在启动菜单选择普通的 Windows 项。'
        throw 'RunningInsideVhd'
    }
    Write-Ok '当前是物理系统'
}

# ============================================================
# 卷定位
# ============================================================
function Get-DataVolume {
    param([string]$Label = 'Data')
    $v = @(Get-Volume -ErrorAction SilentlyContinue |
           Where-Object { $_.FileSystemLabel -eq $Label -and $_.DriveLetter })
    if ($v.Count -eq 0) {
        throw "找不到卷标为 '$Label' 的卷。请确认数据盘已挂载且有盘符。"
    }
    if ($v.Count -gt 1) {
        $list = ($v | ForEach-Object { $_.DriveLetter + ':' }) -join ', '
        throw "找到 $($v.Count) 个卷标为 '$Label' 的卷（$list），需要恰好 1 个。"
    }
    return $v[0]
}

# ============================================================
# diskpart 封装
# ============================================================
function Invoke-Diskpart {
    param([string[]]$Lines)
    $f = Join-Path $env:TEMP ('dp_' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllText($f, (($Lines -join "`r`n") + "`r`nexit`r`n"), [Text.Encoding]::ASCII)
        return ((& diskpart.exe /s $f 2>&1) | Out-String)
    } finally {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}

function Get-VhdInfo {
    <#
      读取 VHD 信息，不依赖 Hyper-V 模块。
      返回：Ok / Type / Parent / VirtualSizeBytes / Attached / Detail
      Type: Differencing / NonDifferencing / ''
    #>
    param([string]$Path)
    $o = [pscustomobject]@{
        Ok = $false; Type = ''; Parent = ''
        VirtualSizeBytes = [int64]0; Attached = $false; Detail = ''
    }
    if (-not (Test-Path -LiteralPath $Path)) { $o.Detail = '文件不存在'; return $o }

    $t = Invoke-Diskpart @("select vdisk file=`"$Path`"", 'detail vdisk')
    if ($t -notmatch 'Virtual size') { $o.Detail = $t.Trim(); return $o }

    $o.Ok = $true
    if ($t -match 'Is Child:\s+Yes')     { $o.Type = 'Differencing' }
    elseif ($t -match 'Is Child:\s+No')  { $o.Type = 'NonDifferencing' }

    $m = [regex]::Match($t, 'Parent Filename:\s*(.+)')
    if ($m.Success) { $o.Parent = $m.Groups[1].Value.Trim() }

    $m2 = [regex]::Match($t, 'Virtual size:\s+(\d+)\s*(KB|MB|GB|TB)')
    if ($m2.Success) {
        $mult = @{ KB = 1KB; MB = 1MB; GB = 1GB; TB = 1TB }[$m2.Groups[2].Value]
        $o.VirtualSizeBytes = [int64]$m2.Groups[1].Value * $mult
    }
    $o.Attached = ($t -match 'State:\s*Attached')
    return $o
}

# ============================================================
# 挂载与链检查（核心，已沙盒验证）
# ============================================================
function Get-VhdMainPartition {
    <#
      找 VHD 里的主分区。
      陷阱：不要用 Type -eq 'Basic' 过滤 —— VHD 内系统分区类型可能是 IFS。
      策略：所有 >50MB 分区里取最大的。
    #>
    param([int]$DiskNumber)
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    if ($parts.Count -eq 0) { return $null }
    $cand = @($parts | Where-Object { $_.Size -gt 50MB } | Sort-Object Size -Descending)
    if ($cand.Count -eq 0) {
        return ($parts | Sort-Object Size -Descending | Select-Object -First 1)
    }
    return $cand[0]
}

function Mount-VhdReadOnlyAndProbe {
    <#
      只读挂载 VHD，找主分区，验证能读到指定文件。
      这是判断差分链健康与否最可靠的方法。
      已验证：能正确穿透读到父盘内容；父盘损坏/改名时会明确报链断裂。
    #>
    param(
        [string]$Path,
        [string[]]$Expect = @('Windows\System32\winload.efi'),
        [int]$WaitSeconds = 30
    )
    $res = [pscustomobject]@{
        Ok = $false; Detail = ''; Letter = $null; PartType = ''; DiskNumber = -1
    }
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $Path -Access ReadOnly -ErrorAction Stop | Out-Null
        $mounted = $true
        Start-Sleep -Seconds 2

        $disk = (Get-DiskImage -ImagePath $Path) | Get-Disk -ErrorAction SilentlyContinue
        if (-not $disk) { $res.Detail = '挂载成功但拿不到磁盘对象'; return $res }
        $res.DiskNumber = $disk.Number

        $letter = $null
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while (-not $letter -and (Get-Date) -lt $deadline) {
            $p = Get-VhdMainPartition -DiskNumber $disk.Number
            if ($p) {
                $res.PartType = [string]$p.Type
                if (-not $p.DriveLetter) {
                    try {
                        Add-PartitionAccessPath -DiskNumber $disk.Number `
                            -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
                    } catch { }
                    Start-Sleep -Milliseconds 900
                    $p = Get-Partition -DiskNumber $disk.Number `
                         -PartitionNumber $p.PartitionNumber -ErrorAction SilentlyContinue
                }
                if ($p -and $p.DriveLetter -and (Test-Path "$($p.DriveLetter):\")) {
                    $letter = [string]$p.DriveLetter
                }
            }
            if (-not $letter) { Start-Sleep -Milliseconds 900 }
        }

        if (-not $letter) {
            $res.Detail = ('挂载成功但 ' + $WaitSeconds +
                           ' 秒内没出现盘符（分区类型=' + $res.PartType + '）')
            return $res
        }

        $res.Letter = $letter
        $missing = @($Expect | Where-Object { -not (Test-Path ("${letter}:\" + $_)) })
        if ($missing.Count -eq 0) {
            $res.Ok = $true
            $res.Detail = ('可读到 ' + ($Expect -join ', ') +
                           '（临时盘符 ' + $letter + ':，分区类型=' + $res.PartType + '）')
        } else {
            $res.Detail = '分区里缺少：' + ($missing -join '；')
        }
    } catch {
        $res.Detail = $_.Exception.Message
    } finally {
        if ($mounted) {
            try { Dismount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null }
            catch { $res.Detail += '（卸载失败：' + $_.Exception.Message + '）' }
        }
    }
    return $res
}

function Dismount-VhdSafely {
    <#
      确保 VHD 已分离。
      注意：如果这个 VHD 是「当前运行的系统盘」，它永远不会被分离——
      这是正常情况，不应在测试里判为失败。返回值区分三种情况：
        'Detached'  —— 已分离（或本来就没挂载）
        'InUseBySelf' —— 是当前系统盘，无法分离（正常）
        'Failed'    —— 其他原因分离失败（需关注）
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'Detached' }

    # 先判断是不是当前系统盘
    try {
        $sysLetter = $env:SystemDrive.TrimEnd(':')
        $sp = Get-Partition -DriveLetter $sysLetter -ErrorAction SilentlyContinue
        if ($sp) {
            $sd = Get-Disk -Number $sp.DiskNumber -ErrorAction SilentlyContinue
            $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
            if ($img -and $sd -and $img.Number -eq $sd.Number) {
                return 'InUseBySelf'
            }
        }
    } catch { }

    for ($i = 0; $i -lt 5; $i++) {
        $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
        if (-not $img -or -not $img.Attached) { return 'Detached' }
        try { Dismount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null } catch { }
        Start-Sleep -Seconds 1
    }
    $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
    if (-not $img -or -not $img.Attached) { return 'Detached' }
    return 'Failed'
}

# ============================================================
# 差分盘
# ============================================================
function New-DifferencingVhd {
    param([string]$ParentPath, [string]$ChildPath, [switch]$Force)

    if (-not (Test-Path -LiteralPath $ParentPath)) { throw "父盘不存在：$ParentPath" }

    $pi = Get-VhdInfo $ParentPath
    if (-not $pi.Ok) { throw "读不出父盘信息：$($pi.Detail)" }
    if ($pi.Type -eq 'Differencing') {
        throw '父盘本身是差分盘 —— 禁止创建孙盘，链会太脆弱'
    }
    if ($pi.Attached) { throw '父盘正处于挂载状态，请先分离' }

    $pf = Get-Item -LiteralPath $ParentPath -Force
    if (-not $pf.IsReadOnly) {
        Write-Warn2 '父盘不是只读，自动设置'
        Set-ItemProperty -LiteralPath $ParentPath -Name IsReadOnly -Value $true
        Write-Ok '父盘已设为只读'
    }

    if (Test-Path -LiteralPath $ChildPath) {
        if (-not $Force) { throw "目标已存在：$ChildPath（用 -Force 覆盖）" }
        Write-Warn2 '目标已存在，删除后重建'
        Remove-Item -LiteralPath $ChildPath -Force
    }

    $r = Invoke-Diskpart @("create vdisk file=`"$ChildPath`" parent=`"$ParentPath`"")
    if (-not (Test-Path -LiteralPath $ChildPath)) {
        throw "创建差分盘失败。diskpart 输出：`n$r"
    }
    $sz = [math]::Round((Get-Item $ChildPath).Length / 1MB, 1)
    Write-Ok ('差分盘已创建：' + (Split-Path $ChildPath -Leaf) + '（' + $sz + ' MB）')
    return (Get-VhdInfo $ChildPath)
}

function Test-VhdChain {
    <#
      完整验证差分链：属性 + 大小一致 + 实读系统文件
      返回 Ok / Problems
    #>
    param(
        [string]$ChildPath,
        [string]$ParentPath,
        [string[]]$Expect = @('Windows\System32\winload.efi')
    )
    $problems = New-Object System.Collections.Generic.List[string]

    $ci = Get-VhdInfo $ChildPath
    if (-not $ci.Ok) {
        $problems.Add('读不出子盘信息：' + $ci.Detail)
        return [pscustomobject]@{ Ok = $false; Problems = @($problems) }
    }
    if ($ci.Type -ne 'Differencing') { $problems.Add('子盘不是差分盘（' + $ci.Type + '）') }

    $parentName = Split-Path $ParentPath -Leaf
    if ($ci.Parent -and $ci.Parent -notmatch [regex]::Escape($parentName)) {
        $problems.Add('父盘指向不对：' + $ci.Parent)
    }

    $pi = Get-VhdInfo $ParentPath
    if ($pi.Ok -and $ci.VirtualSizeBytes -ne $pi.VirtualSizeBytes) {
        $problems.Add('虚拟大小与父盘不一致（子 ' + $ci.VirtualSizeBytes +
                      ' / 父 ' + $pi.VirtualSizeBytes + '）')
    }

    if ($problems.Count -eq 0) {
        $probe = Mount-VhdReadOnlyAndProbe -Path $ChildPath -Expect $Expect
        if (-not $probe.Ok) { $problems.Add('链检查失败：' + $probe.Detail) }
    }
    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @($problems) }
}

# ============================================================
# BCD（已通过副本实验逐项验证）
# ============================================================
function Get-BcdBootLoaders {
    $raw = (& bcdedit /enum all 2>&1) | Out-String
    $chunks = [regex]::Split($raw, "(?:\r?\n){2,}")
    $list = @()
    foreach ($c in $chunks) {
        if ($c -match 'Windows Boot Loader') {
            $id   = [regex]::Match($c, 'identifier\s+(\{[^}]+\})').Groups[1].Value
            $dev  = [regex]::Match($c, '(?m)^device\s+(.+)$').Groups[1].Value.Trim()
            $desc = [regex]::Match($c, '(?m)^description\s+(.+)$').Groups[1].Value.Trim()
            if ($id) {
                $list += [pscustomobject]@{
                    Id = $id; Device = $dev; Description = $desc
                    IsVhd = ($dev -match 'vhd=')
                    IsRamdisk = ($dev -match 'ramdisk=')
                }
            }
        }
    }
    return $list
}

function Get-PhysicalBootEntry {
    <#
      找物理系统启动项做模板。
      已验证本机的情况：{current} 在 Work 里跑时 device 显示为
        locate=\Windows\system32\winload.efi
      这会被误认为“物理项”，必须排除 locate= 形式的项。
      真正的物理项 device 是 partition=X: 且不含 vhd=/ramdisk=/locate=。
    #>
    $loaders = @(Get-BcdBootLoaders)
    $phys = @($loaders | Where-Object {
        $_.Device -match '^partition=' -and
        -not $_.IsVhd -and
        -not $_.IsRamdisk -and
        $_.Device -notmatch 'locate='
    })
    if ($phys.Count -eq 0) { throw '找不到物理系统启动项（device 为 partition= 的项）' }
    if ($phys.Count -gt 1) {
        Write-Warn2 ('找到 ' + $phys.Count + ' 个物理启动项，使用：' + $phys[0].Description)
    }
    return $phys[0]
}

function Backup-Bcd {
    param([string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = Join-Path $LogDir ('BCD_Backup_' + $stamp)
    & bcdedit /export $bak 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bak)) {
        throw 'BCD 导出失败，不要继续操作'
    }
    & bcdedit /enum all      > (Join-Path $LogDir ('bcd_enum_all_' + $stamp + '.txt'))
    & bcdedit /enum firmware > (Join-Path $LogDir ('bcd_enum_firmware_' + $stamp + '.txt'))
    Write-Ok ('BCD 已备份：' + (Split-Path $bak -Leaf))
    return $bak
}

function New-VhdBootEntry {
    <#
      创建指向 VHD 的启动项，返回 GUID。

      重要实测发现（ 2026-10-28 ）：
        bcdedit /set <guid> device "vhd=[X:]\..." 当 X: 盘不存在时，
        命令**不报错但也不生效**，device 仍保留模板的值（如 partition=D:）。
        所以设置后必须回读验证，不能只看 $LASTEXITCODE。
    #>
    param([string]$VhdPath, [string]$Description, [string]$TemplateId)

    if (-not $TemplateId) { $TemplateId = (Get-PhysicalBootEntry).Id }
    Write-Info ('模板启动项：' + $TemplateId)

    # 先确认 VhdPath 里的盘符真实存在，否则 bcdedit 会静默失败
    $mDrive = [regex]::Match($VhdPath, '^\[([A-Za-z]):\]')
    if ($mDrive.Success) {
        $letter = $mDrive.Groups[1].Value.ToUpper()
        $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $vol) {
            throw ('盘符 ' + $letter + ': 不存在，bcdedit 会静默忽略。' +
                   '请确认数据盘已挂载。')
        }
    }

    $out = (& bcdedit /copy $TemplateId /d $Description 2>&1) | Out-String
    $guid = [regex]::Match($out,
        '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}').Value
    if (-not $guid) { throw ('bcdedit /copy 失败。输出：' + $out.Trim()) }
    Write-Ok ('已创建启动项：' + $guid)

    & bcdedit /set $guid device   ("vhd=$VhdPath") 2>&1 | Out-Null
    & bcdedit /set $guid osdevice ("vhd=$VhdPath") 2>&1 | Out-Null
    & bcdedit /set $guid path     '\Windows\system32\winload.efi' 2>&1 | Out-Null
    & bcdedit /set $guid description $Description 2>&1 | Out-Null

    # ---- 回读验证（关键）----
    $chk = (& bcdedit /enum $guid 2>&1) | Out-String
    $devLine  = [regex]::Match($chk, '(?m)^device\s+(.+)$').Groups[1].Value.Trim()
    $osLine   = [regex]::Match($chk, '(?m)^osdevice\s+(.+)$').Groups[1].Value.Trim()

    $devOk = $devLine -match 'vhd='
    $osOk  = $osLine  -match 'vhd='

    if (-not $devOk -or -not $osOk) {
        # 回滚：删掉刚建的无效项，避免污染 BCD
        & bcdedit /delete $guid 2>&1 | Out-Null
        throw ('设置 VHD 指向失败（bcdedit 静默忽略）。' +
               "`n  device  = $devLine" +
               "`n  osdevice= $osLine" +
               "`n  path    = \Windows\system32\winload.efi" +
               "`n  盘符是否存在：$($mDrive.Groups[1].Value): → " +
               [bool](Get-Volume -DriveLetter $mDrive.Groups[1].Value -ErrorAction SilentlyContinue) +
               "`n  已删除这个无效启动项。")
    }

    Write-Ok 'device / osdevice / path 已设置并回读验证'
    Write-Info ('  device  = ' + $devLine)
    Write-Info ('  osdevice= ' + $osLine)
    return $guid
}

function Get-BcdTimeout {
    $bm = (& bcdedit /enum '{bootmgr}' 2>&1) | Out-String
    $m = [regex]::Match($bm, 'timeout\s+(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Set-BcdTimeout {
    param([int]$Seconds)
    & bcdedit /timeout $Seconds 2>&1 | Out-Null
    $now = Get-BcdTimeout
    if ($now -ne $Seconds) { Write-Warn2 ('timeout 可能未生效（当前 ' + $now + '）') }
    else { Write-Ok ('菜单超时 = ' + $Seconds + ' 秒') }
}

function Add-BootEntryToMenu {
    param([string]$Guid)
    & bcdedit /displayorder $Guid /addlast 2>&1 | Out-Null
    $bm = (& bcdedit /enum '{bootmgr}' 2>&1) | Out-String
    if ($bm -match [regex]::Escape($Guid)) { Write-Ok '已加入启动菜单' }
    else { Write-Warn2 '加入菜单后未在 displayorder 中找到，请人工确认' }
}

function Remove-BootEntryFromMenu {
    <# 只从菜单移除，启动项保留（可随时 addlast 恢复） #>
    param([string]$Guid)
    & bcdedit /displayorder $Guid /remove 2>&1 | Out-Null
    Write-Ok '已从启动菜单移除（启动项仍保留）'
}

function Remove-BcdEntry {
    param([string]$Guid)
    & bcdedit /delete $Guid 2>&1 | Out-Null
    $all = (& bcdedit /enum all 2>&1) | Out-String
    if ($all -match [regex]::Escape($Guid)) { Write-Warn2 ('未能删除 ' + $Guid); return $false }
    Write-Ok ('已删除启动项 ' + $Guid)
    return $true
}

# ============================================================
# 记录文件
# ============================================================
function Save-JsonRecord {
    param([hashtable]$Data, [string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ($Data | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Ok ('已记录：' + (Split-Path $Path -Leaf))
}

function Load-JsonRecord {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}
