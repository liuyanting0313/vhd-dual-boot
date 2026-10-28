<#
=====================================================================
 02-create-base.ps1 — 阶段 2/5：创建母盘 Base.vhdx
=====================================================================
 在物理 Windows 里运行。做两件事：
   1. 创建一个空 VHDX 并分区格式化（卷标 Base）
   2. 挂载它，提示你把 Windows 部署进去

 重要：本脚本只创建"空盘 + 分区"，不部署 Windows。
       部署有两种方式，详见 GUIDE.md 6.3 节：
         方式 A：DISM 从 ISO 的 install.wim 展开（推荐）
         方式 B：先用物理机装好系统，再整体捕获

 大小选择：
   - 建议 ≥ 200GB，且 ≤ 数据盘可用空间的 1/3
   - 用 expandable（动态），不占满空间
   - 默认 384GB，与原环境一致

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\02-create-base.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\02-create-base.ps1 -SizeGB 300
   powershell -NoProfile -ExecutionPolicy Bypass -File .\02-create-base.ps1 -Force
#>

param(
    [string]$DataLabel = 'Data',
    [int]$SizeGB = 384,
    [switch]$Force,
    [switch]$KeepMounted   # 部署完再手动分离时用
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║      阶段 2/5 — 创建母盘 Base.vhdx             ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$Base = Join-Path $VhdDir 'Base.vhdx'

if (-not (Test-Path -LiteralPath $VhdDir)) {
    New-Item -ItemType Directory -Force -Path $VhdDir | Out-Null
}

# ---------- 检查 ----------
Write-Step '前置检查'

if (Test-Path -LiteralPath $Base) {
    $bi = Get-VhdInfo $Base
    $sz = [math]::Round((Get-Item $Base).Length / 1GB, 2)
    Write-Warn2 ('Base.vhdx 已存在（' + $sz + ' GB，类型 ' + $bi.Type + '）')
    if (-not $Force) {
        Write-Host ''
        Write-Host '  继续会删除现有的 Base.vhdx！' -ForegroundColor Red
        Write-Host '  如果你要用现有母盘，请改用 03-add-base-entry.ps1 / 04-seal-base.ps1' -ForegroundColor Yellow
        $ans = Read-Host '  确认删除并重建？输入 DELETE-BASE'
        if ($ans -cne 'DELETE-BASE') { Write-Info '已取消，未做改动'; exit 0 }
    }
    Dismount-VhdSafely -Path $Base | Out-Null
    Remove-Item -LiteralPath $Base -Force
    Write-Ok '已删除旧 Base.vhdx'
}

# 空间检查
$need = [int64]$SizeGB * 1GB
Write-Info ('计划大小：' + $SizeGB + ' GB（动态扩展，实际占用远小于此）')
Write-Info ('数据盘可用：' + [math]::Round($dv.SizeRemaining / 1GB, 1) + ' GB')
if ($dv.SizeRemaining -lt 20GB) {
    Write-Err2 '可用空间不足 20GB，无法创建'
    exit 1
}
if ($SizeGB -lt 64) {
    Write-Err2 '母盘小于 64GB，装不下 Windows'
    exit 1
}

Write-Info ('父盘将位于：' + $Base)
if (-not $Force) {
    Write-Host ''
    $ans = Read-Host '  确认创建？输入 YES'
    if ($ans -cne 'YES') { Write-Info '已取消'; exit 0 }
}

# ---------- 创建空盘 + 分区 ----------
Write-Step '创建空 VHDX 并分区格式化'
Write-Info '这一步可能要 1-3 分钟'

$maxMB = $SizeGB * 1024
$r = Invoke-Diskpart @(
    "create vdisk file=`"$Base`" maximum=$maxMB type=expandable"
    "select vdisk file=`"$Base`""
    'attach vdisk'
    'create partition primary'
    'format fs=ntfs quick label=Base'
    'assign letter=B'
    'detach vdisk'
)
Write-Info ''
$r -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-Info ('  ' + $_.Trim()) }

if (-not (Test-Path -LiteralPath $Base)) {
    Write-Err2 '创建失败'
    exit 1
}
Write-Ok ('Base.vhdx 已创建：' + [math]::Round((Get-Item $Base).Length / 1MB, 1) + ' MB')

$bi = Get-VhdInfo $Base
Write-Ok ('虚拟大小：' + [math]::Round($bi.VirtualSizeBytes / 1GB, 1) + ' GB  类型：' + $bi.Type)
if ($bi.Attached) { Dismount-VhdSafely -Path $Base | Out-Null }

# ---------- 提示下一步 ----------
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  阶段 2 完成：空母盘已就绪' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  下一步不是跑脚本，而是【把 Windows 部署进 Base.vhdx】：' -ForegroundColor Yellow
Write-Host ''
Write-Host '    方式 A（推荐，DISM）：' -ForegroundColor Cyan
Write-Host '      1. 挂载 Windows 11 ISO，找到 sources\install.wim' -ForegroundColor Gray
Write-Host '      2. 查版本号：Get-WindowsImage -ImagePath <wim> | Select ImageIndex,ImageName' -ForegroundColor Gray
Write-Host '         （专业版通常是 6）' -ForegroundColor Gray
Write-Host '      3. 挂载 Base.vhdx 并记下盘符（本脚本用了 B:，但可能变）' -ForegroundColor Gray
Write-Host '      4. Expand-WindowsImage -ImagePath <wim> -Index 6 -ApplyPath "B:\" -Verify' -ForegroundColor Gray
Write-Host '      5. bcdboot "B:\Windows" /s B: /f UEFI      <-- 关键！不写引导无法启动' -ForegroundColor Gray
Write-Host '      6. Dismount-DiskImage -ImagePath "' + $Base + '"' -ForegroundColor Gray
Write-Host ''
Write-Host '    方式 B（用物理机装好后捕获）：见 GUIDE.md 6.3 节方式 B' -ForegroundColor Cyan
Write-Host ''
Write-Host '  部署完成后：03-add-base-entry.ps1（加启动项）' -ForegroundColor Cyan
Write-Host ''
