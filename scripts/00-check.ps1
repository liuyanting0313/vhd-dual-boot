<#
=====================================================================
 00-check.ps1 — 环境预检
=====================================================================
 在任何操作之前先跑这个，确认环境满足要求。只读，不改任何东西。

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\00-check.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\00-check.ps1 -DataLabel MyData
#>

param(
    [string]$DataLabel = 'Data'   # 数据盘卷标
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║         差分双系统 — 环境预检                  ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

$fail = 0
$warn = 0

function Check($name, $ok, $detail, $isWarn = $false) {
    if ($ok) { Write-Ok $name }
    elseif ($isWarn) { Write-Warn2 $name; $script:warn++ }
    else { Write-Err2 $name; $script:fail++ }
    if ($detail) { Write-Info $detail }
}

# ---------- 1. 权限 ----------
Write-Step '1. 权限'
Check '管理员权限' (Test-Admin) $(if (Test-Admin) { '已提权' } else { '请右键 -> 以管理员身份运行' })

# ---------- 2. 系统身份 ----------
Write-Step '2. 系统身份（不能在 Work 里操作）'
$inVhd = Test-InVhd
Check '当前是物理系统（不在 VHD 里）' (-not $inVhd) `
    $(if ($inVhd) { '你在 Work 里，请重启到物理 Windows' } else { '符合要求' })

$sysLetter = $env:SystemDrive.TrimEnd(':')
$sysPart = Get-Partition -DriveLetter $sysLetter -ErrorAction SilentlyContinue
if ($sysPart) {
    $sysDisk = Get-Disk -Number $sysPart.DiskNumber -ErrorAction SilentlyContinue
    Write-Info ('系统盘 ' + $sysLetter + ': 总线类型 = ' + $(if ($sysDisk) { $sysDisk.BusType } else { '未知' }))
}

# ---------- 3. 固件与分区 ----------
Write-Step '3. 固件 / 引导方式'
try {
    $esp = Get-Partition -ErrorAction SilentlyContinue |
           Where-Object { $_.Type -eq 'System' } | Select-Object -First 1
    if ($esp) {
        $espVol = Get-Volume -Partition $esp -ErrorAction SilentlyContinue
        Write-Ok ('找到 ESP 分区（' + $esp.DiskNumber + ' 号盘，' +
                  [math]::Round($esp.Size / 1MB) + ' MB）')
        Write-Info ('文件系统 = ' + $(if ($espVol) { $espVol.FileSystem } else { '?' }) +
                    '（应为 FAT32，即 UEFI 引导）')
        if ($espVol -and $espVol.FileSystem -ne 'FAT32') {
            Write-Warn2 'ESP 不是 FAT32，可能不是 UEFI 引导'; $warn++
        }
    } else {
        Write-Err2 '找不到 ESP 分区 —— 可能不是 UEFI 引导，VHD 启动可能不支持'
        $fail++
    }
} catch {
    Write-Warn2 ('检查 ESP 失败：' + $_.Exception.Message); $warn++
}

# ---------- 4. 数据盘 ----------
Write-Step '4. 数据盘定位'
try {
    $dv = Get-DataVolume -Label $DataLabel
    $free = $dv.SizeRemaining
    Write-Ok ('卷标 ' + $DataLabel + ' 定位成功：' + $dv.DriveLetter + ':')
    Write-Info ('总容量 ' + [math]::Round($dv.Size / 1GB, 1) + ' GB，' +
                '可用 ' + [math]::Round($free / 1GB, 1) + ' GB')
    if ($free -lt 100GB) {
        Write-Warn2 ('可用空间不足 100GB，创建母盘可能失败'); $warn++
    }
    $script:DataDrive = $dv.DriveLetter
} catch {
    Write-Err2 $_.Exception.Message
    Write-Info '可用磁盘的卷标：'
    Get-Volume | Where-Object DriveLetter | ForEach-Object {
        Write-Info ('  ' + $_.DriveLetter + ':  "' + $_.FileSystemLabel + '"  ' +
                    [math]::Round($_.SizeRemaining / 1GB, 1) + ' GB 可用')
    }
    $fail++
}

# ---------- 5. 快速启动 / 休眠 ----------
Write-Step '5. 快速启动与休眠（影响 VHD 挂载）'
try {
    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
           -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    Check '快速启动已关闭（HiberbootEnabled = 0）' ($hb -eq 0) `
        ('当前值 = ' + $(if ($null -eq $hb) { '未设置' } else { $hb }))
} catch {
    Write-Warn2 ('读取失败：' + $_.Exception.Message); $warn++
}

try {
    $vdom = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' `
             -Name VirtualDiskExpandOnMount -ErrorAction SilentlyContinue).VirtualDiskExpandOnMount
    if ($null -eq $vdom) {
        Write-Warn2 '未设置 VirtualDiskExpandOnMount（默认行为，通常无需改）'
        Write-Info '若挂载后虚拟盘变大，可在 01-prepare.ps1 里设为 0'
        $script:warn++
    }
    elseif ($vdom -eq 0) { Write-Ok 'VHD 挂载不自动扩展（VirtualDiskExpandOnMount = 0）' }
    else { Write-Warn2 ('VirtualDiskExpandOnMount = ' + $vdom + '（建议设为 0）'); $script:warn++ }
} catch {
    Write-Warn2 ('读取失败：' + $_.Exception.Message); $script:warn++
}

# ---------- 6. BCD 现状 ----------
Write-Step '6. BCD 启动项现状'
try {
    $loaders = @(Get-BcdBootLoaders)
    Write-Ok ('共 ' + $loaders.Count + ' 个 Boot Loader')
    foreach ($l in $loaders) {
        $tag = if ($l.IsVhd) { '[VHD]' } elseif ($l.IsRamdisk) { '[WIM]' } else { '[物理]' }
        Write-Info ('  ' + $tag.PadRight(6) + ' ' + $l.Id.PadRight(42) + ' ' + $l.Description)
    }
    $phys = @($loaders | Where-Object {
        $_.Device -match '^partition=' -and -not $_.IsVhd -and -not $_.IsRamdisk -and $_.Device -notmatch 'locate='
    })
    Check '能定位物理系统启动项（作为复制模板）' ($phys.Count -ge 1) `
        $(if ($phys.Count -ge 1) { '模板 = ' + $phys[0].Id } else { '找不到 device 为 partition= 的启动项' })

    $to = Get-BcdTimeout
    Write-Info ('启动菜单超时 = ' + $to + ' 秒')
} catch {
    Write-Err2 ('解析 BCD 失败：' + $_.Exception.Message); $fail++
}

# ---------- 7. 已有 VHD ----------
if ($script:DataDrive) {
    Write-Step '7. 数据盘上已有的 VHD'
    $vhdDir = Join-Path ($script:DataDrive + ':') 'VHD'
    if (Test-Path -LiteralPath $vhdDir) {
        $found = @(Get-ChildItem -LiteralPath $vhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Write-Info '（VHD 目录存在，但没有 .vhdx 文件）'
        }
        foreach ($f in $found) {
            $info = Get-VhdInfo $f.FullName
            $t = if ($info.Type -eq 'Differencing') { '差分盘' } elseif ($info.Ok) { '独立盘' } else { '无法识别' }
            Write-Info ('  ' + $f.Name.PadRight(38) + ' ' +
                        ([math]::Round($f.Length / 1GB, 2)).ToString().PadLeft(7) + ' GB  ' + $t)
        }
    } else {
        Write-Info ('VHD 目录尚不存在：' + $vhdDir + '（阶段 1 会创建）')
    }
}

# ---------- 8. 磁盘总览 ----------
Write-Step '8. 磁盘与卷总览'
Get-Disk | ForEach-Object {
    Write-Info ('盘' + $_.Number + '  ' + $_.FriendlyName.PadRight(30) + ' ' +
                $_.BusType.PadRight(20) + ' ' + [math]::Round($_.Size / 1GB) + ' GB')
}
Write-Host ''
Get-Volume | Where-Object { $_.DriveLetter -or $_.FileSystemLabel } | ForEach-Object {
    Write-Info ('  ' + ($(if ($_.DriveLetter) { $_.DriveLetter + ':' } else { '  ' })).PadRight(4) +
                ' ' + ([string]$_.FileSystemLabel).PadRight(16) +
                ' ' + ([string]$_.FileSystem).PadRight(6) +
                ' 可用 ' + [math]::Round($_.SizeRemaining / 1GB, 1) + ' GB')
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Cyan
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host '  全部通过，可以开始构建。' -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host ('  通过，但有 ' + $warn + ' 项警告。建议先处理再继续。') -ForegroundColor Yellow
} else {
    Write-Host ('  有 ' + $fail + ' 项未通过、' + $warn + ' 项警告。请先解决。') -ForegroundColor Red
}
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host '下一步：01-prepare.ps1（环境调整 + 备份 BCD）' -ForegroundColor Gray

if ($fail -gt 0) { exit 1 } else { exit 0 }
