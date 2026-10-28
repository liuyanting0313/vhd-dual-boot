<#
=====================================================================
 03-add-base-entry.ps1 — 阶段 3/5（上）：给母盘加启动项
=====================================================================
 在物理 Windows 里运行。

 目的：让启动菜单出现 "Win11-Base-VHD"，重启进去做首次配置和封箱。

 做四件事：
   1. 备份 BCD
   2. 复制物理系统启动项作为模板，改成指向 Base.vhdx
   3. 加入启动菜单，设置超时
   4. 写 entry-base.json（含 GUID、超时等，供 05-rollback 用）

 不做的事：不改 Base.vhdx 的任何属性。

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\03-add-base-entry.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\03-add-base-entry.ps1 -Description "MyBase" -Timeout 30
#>

param(
    [string]$DataLabel = 'Data',
    [string]$Description = 'Win11-Base-VHD',
    [int]$Timeout = 30,
    [switch]$NoMenu,        # 只建启动项，不加菜单
    [switch]$Force          # 母盘里还没部署 Windows 也强行继续
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║   阶段 3/5（上）— 给母盘加启动项               ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$LogDir = Join-Path $VhdDir 'Logs'
$Base = Join-Path $VhdDir 'Base.vhdx'
$Record = Join-Path $VhdDir 'entry-base.json'

# ---------- 前置检查 ----------
Write-Step '前置检查'

if (-not (Test-Path -LiteralPath $Base)) {
    Write-Err2 ('找不到 ' + $Base)
    Write-Info '请先跑 02-create-base.ps1 并把 Windows 部署进去'
    exit 1
}

$bi = Get-VhdInfo $Base
if (-not $bi.Ok) {
    Write-Err2 ('读不出 Base.vhdx 信息：' + $bi.Detail)
    exit 1
}
if ($bi.Type -eq 'Differencing') {
    Write-Err2 'Base.vhdx 是差分盘 —— 它应该是独立盘（母盘）'
    exit 1
}
if ($bi.Attached) {
    Write-Warn2 'Base.vhdx 当前处于挂载状态，先分离'
    Dismount-VhdSafely -Path $Base | Out-Null
}

Write-Ok ('Base.vhdx 正常（' + [math]::Round($bi.VirtualSizeBytes / 1GB, 1) + ' GB，' + $bi.Type + '）')

# 确认里面真的有 Windows（只读挂载看 winload.efi）
Write-Step '确认母盘里已部署 Windows'
$probe = Mount-VhdReadOnlyAndProbe -Path $Base -Expect @('Windows\System32\winload.efi')
if ($probe.Ok) {
    Write-Ok $probe.Detail
} else {
    Write-Err2 ('母盘里读不到 Windows 引导文件：' + $probe.Detail)
    Write-Info '看起来 Windows 还没部署进去，或 bcdboot 没执行'
    Write-Info '此时加启动项也启动不了。请先完成 02 的部署步骤。'
    if (-not $Force) {
        Write-Host ''
        $ans = Read-Host '  仍然继续？输入 CONTINUE 强制继续'
        if ($ans -cne 'CONTINUE') { Write-Info '已取消'; exit 1 }
    }
}

# 检查是否已有 Base 启动项
$existing = @(Get-BcdBootLoaders | Where-Object {
    $_.IsVhd -and $_.Device -match 'Base\.vhdx'
})
if ($existing.Count -gt 0) {
    Write-Warn2 ('BCD 里已有 ' + $existing.Count + ' 个指向 Base.vhdx 的启动项：')
    $existing | ForEach-Object { Write-Info ('  ' + $_.Id + '  ' + $_.Description) }
    Write-Host ''
    $ans = Read-Host '  继续会再创建一个新的。输入 YES 继续'
    if ($ans -cne 'YES') { Write-Info '已取消'; exit 0 }
}

# ---------- 备份 BCD ----------
Write-Step '备份 BCD'
$bcdBackup = Backup-Bcd -LogDir $LogDir

$prevTimeout = Get-BcdTimeout
Write-Info ('当前菜单超时：' + $prevTimeout + ' 秒')

# ---------- 创建启动项 ----------
Write-Step '创建启动项'
# BCD 里盘符是物理系统视角，直接拼
$bcdPath = '[' + $DataDrive + ':]\VHD\Base.vhdx'
Write-Info ('BCD 里将写入：vhd=' + $bcdPath)

$guid = New-VhdBootEntry -VhdPath $bcdPath -Description $Description

# ---------- 加菜单 ----------
Write-Step '加入启动菜单'
if ($NoMenu) {
    Write-Warn2 '已按参数跳过加入菜单（启动项仍已创建，可用 /displayorder 手动加）'
} else {
    Add-BootEntryToMenu -Guid $guid
    if ($Timeout -gt 0) { Set-BcdTimeout -Seconds $Timeout }
}

# ---------- 记录 ----------
Write-Step '记录'
$rec = @{
    Stage           = 'base-entry'
    CreatedAt       = (Get-Date).ToString('s')
    Guid            = $guid
    Description     = $Description
    VhdPath         = $Base
    BcdVhdPath      = ('vhd=' + $bcdPath)
    BaseLength      = (Get-Item $Base).Length
    BaseWriteTicks  = (Get-Item $Base).LastWriteTimeUtc.Ticks
    PreviousTimeout = $prevTimeout
    TimeoutSet      = $Timeout
    BcdBackup       = $bcdBackup
}
Save-JsonRecord -Data $rec -Path $Record

# ---------- 验证 ----------
Write-Step '验证'
$chk = (& bcdedit /enum $guid 2>&1) | Out-String
$chk -split "`n" | Where-Object { $_ -match 'identifier|device|osdevice|path|description' } |
    ForEach-Object { Write-Info ('  ' + $_.Trim()) }

$bm = (& bcdedit /enum '{bootmgr}' 2>&1) | Out-String
if ($bm -match [regex]::Escape($guid)) { Write-Ok '已出现在启动菜单' }
else { Write-Warn2 '未在菜单中找到（如果用了 -NoMenu 这是预期的）' }

Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  阶段 3（上）完成' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host ('  启动项 GUID : ' + $guid) -ForegroundColor Gray
Write-Host ('  BCD 备份    : ' + (Split-Path $bcdBackup -Leaf)) -ForegroundColor Gray
Write-Host ('  记录文件    : ' + (Split-Path $Record -Leaf)) -ForegroundColor Gray
Write-Host ''
Write-Host '  下一步：' -ForegroundColor Yellow
Write-Host '   1. 重启，在启动菜单选 "' + $Description + '"' -ForegroundColor Gray
Write-Host '   2. 走完 OOBE，装好预装软件、配好环境' -ForegroundColor Gray
Write-Host '   3. 在【那个系统内部】执行封箱：' -ForegroundColor Gray
Write-Host '        C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown' -ForegroundColor White
Write-Host '   4. 回到物理 Windows，跑 04-seal-base.ps1' -ForegroundColor Gray
Write-Host ''
Write-Host '  警告：封箱后不要再启动这个母盘并改动它，否则母盘就不干净了。' -ForegroundColor Red
Write-Host ''
