<#
=====================================================================
 01-prepare.ps1 — 阶段 1/5：环境准备
=====================================================================
 在物理 Windows 里运行。做完这些事：
   1. 备份 BCD（不备份不许继续）
   2. 创建 VHD 目录与 Logs 子目录
   3. 关闭快速启动（否则 VHD 挂载会报文件被占用）
   4. 关闭 VHD 挂载时自动扩展
   5. 把所有「改动前」的状态写进 state.json，供 99-rollback 恢复

 这一步不改 BCD，不动任何 VHD，可安全重复运行。

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\01-prepare.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\01-prepare.ps1 -DataLabel MyData -SkipHibernateOff
#>

param(
    [string]$DataLabel = 'Data',
    [switch]$SkipHibernateOff   # 不想关休眠时加这个（但 VHD 挂载可能失败）
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║      阶段 1/5 — 环境准备                       ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

# ---------- 定位数据盘 ----------
Write-Step '定位数据盘'
$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$LogDir = Join-Path $VhdDir 'Logs'
Write-Ok ('数据盘：' + $DataDrive + ':  （卷标 ' + $dv.FileSystemLabel + '）')
Write-Info ('VHD 目录：' + $VhdDir)
Write-Info ('可用空间：' + [math]::Round($dv.SizeRemaining / 1GB, 1) + ' GB')

# ---------- 创建目录 ----------
Write-Step '创建目录'
foreach ($d in @($VhdDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Ok ('已创建 ' + $d)
    } else {
        Write-Info ('已存在 ' + $d)
    }
}

# ---------- 备份 BCD（最重要）----------
Write-Step '备份 BCD'
$stateFile = Join-Path $VhdDir 'state.json'
$prevState = Load-JsonRecord $stateFile
if ($prevState) {
    Write-Warn2 '发现已有的 state.json —— 说明之前跑过这一步'
    Write-Info ('首次运行时间：' + $prevState.FirstRun)
    Write-Info '将保留原始记录，只更新目录信息'
}

$bcdBackup = Backup-Bcd -LogDir $LogDir

# ---------- 记录改动前的状态 ----------
Write-Step '记录改动前的系统状态'

$hbBefore = $null
try {
    $hbBefore = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                 -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
} catch { }

$vdBefore = $null
try {
    $vdBefore = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' `
                 -Name VirtualDiskExpandOnMount -ErrorAction SilentlyContinue).VirtualDiskExpandOnMount
} catch { }

$hibPoweredOn = $false
try {
    $hibFile = Join-Path $env:SystemDrive 'hiberfil.sys'
    $hibPoweredOn = Test-Path -LiteralPath $hibFile
} catch { }

Write-Info ('HiberbootEnabled（快速启动）改动前 = ' + $(if ($null -eq $hbBefore) { '未设置' } else { $hbBefore }))
Write-Info ('VirtualDiskExpandOnMount 改动前    = ' + $(if ($null -eq $vdBefore) { '未设置' } else { $vdBefore }))
Write-Info ('hiberfil.sys 存在（休眠已启用）    = ' + $hibPoweredOn)

$state = @{
    FirstRun                       = if ($prevState) { $prevState.FirstRun } else { (Get-Date).ToString('s') }
    LastRun                        = (Get-Date).ToString('s')
    DataLabel                      = $DataLabel
    DataDrive                      = $DataDrive
    VhdDir                         = $VhdDir
    LogDir                         = $LogDir
    HiberbootEnabledBefore         = $hbBefore
    VirtualDiskExpandOnMountBefore = $vdBefore
    HiberFileExistedBefore         = $hibPoweredOn
    BcdBackup                      = $bcdBackup
    TimeoutBefore                  = Get-BcdTimeout
}
Save-JsonRecord -Data $state -Path $stateFile

# ---------- 关闭快速启动 ----------
Write-Step '关闭快速启动'
if ($SkipHibernateOff) {
    Write-Warn2 '已按参数跳过。注意：快速启动开着时 VHD 挂载可能失败'
} else {
    $needChange = ($hbBefore -ne 0)
    if ($needChange) {
        try {
            Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
            Write-Ok 'HiberbootEnabled 已设为 0'
        } catch {
            Write-Err2 ('设置失败：' + $_.Exception.Message)
        }
    } else {
        Write-Info '已经是 0，无需改动'
    }

    # 关闭休眠（会删除 hiberfil.sys，释放与内存等量的空间）
    try {
        $r = & powercfg /hibernate off 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok '休眠已关闭（hiberfil.sys 已释放）' }
        else { Write-Warn2 ('powercfg 返回：' + ($r | Out-String).Trim()) }
    } catch {
        Write-Warn2 ('关闭休眠失败：' + $_.Exception.Message)
    }

    # 复核
    $after = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
              -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($after -eq 0) { Write-Ok '复核通过：HiberbootEnabled = 0' }
    else { Write-Warn2 ('复核失败：当前值 = ' + $after) }
}

# ---------- 关闭挂载自动扩展 ----------
Write-Step '关闭 VHD 挂载自动扩展'
try {
    if ($vdBefore -ne 0) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\vds'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty $key -Name VirtualDiskExpandOnMount -Value 0 -Type DWord -ErrorAction Stop
        Write-Ok 'VirtualDiskExpandOnMount 已设为 0'
    } else {
        Write-Info '已经是 0，无需改动'
    }
} catch {
    Write-Warn2 ('设置失败（通常不影响使用）：' + $_.Exception.Message)
}

# ---------- 检查现有 VHD ----------
Write-Step '检查数据盘上已有的 VHD'
$existing = @(Get-ChildItem -LiteralPath $VhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue)
if ($existing.Count -eq 0) {
    Write-Info '没有 .vhdx 文件，可以从头开始'
} else {
    Write-Warn2 ('已存在 ' + $existing.Count + ' 个 .vhdx 文件')
    foreach ($f in $existing) {
        $i = Get-VhdInfo $f.FullName
        $t = switch ($i.Type) {
            'Differencing'    { '差分盘' }
            'NonDifferencing' { '独立盘' }
            default           { '无法识别' }
        }
        Write-Info ('  ' + $f.Name.PadRight(40) + [math]::Round($f.Length / 1GB, 2).ToString().PadLeft(7) + ' GB  ' + $t)
    }
    Write-Host ''
    Write-Warn2 '如果这些是你要保留的系统盘，后面的脚本会问到是否覆盖'
}

# ---------- 完成 ----------
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  阶段 1 完成' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host ('  BCD 备份      : ' + (Split-Path $bcdBackup -Leaf)) -ForegroundColor Gray
Write-Host ('  状态记录      : ' + $stateFile) -ForegroundColor Gray
Write-Host ('  VHD 目录      : ' + $VhdDir) -ForegroundColor Gray
Write-Host ''
Write-Host '下一步：02-create-base.ps1（创建母盘 Base.vhdx）' -ForegroundColor Cyan
Write-Host '  注意：此时不能直接进系统，需要先部署 Windows 到 VHD，' -ForegroundColor Yellow
Write-Host '       详见 GUIDE.md 第 6.3 节。' -ForegroundColor Yellow
Write-Host ''
