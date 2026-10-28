<#
=====================================================================
 04-seal-base.ps1 — 阶段 3/5（下）：封箱母盘
=====================================================================
 在物理 Windows 里运行。前提：你已经在母盘系统里跑过 sysprep。

 做四件事：
   1. 验证母盘已完成 sysprep（检查 OOBE 状态标记）
   2. 把 Base.vhdx 设为只读  ← 最关键，不设只读会毁掉所有子盘
   3. 记录母盘指纹（大小 + 时间戳）到 entry-base.json
   4. 从启动菜单移除 Base 启动项（保留启动项本身，随时可恢复）

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\04-seal-base.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\04-seal-base.ps1 -KeepInMenu
#>

param(
    [string]$DataLabel = 'Data',
    [switch]$KeepInMenu,      # 不从菜单移除
    [switch]$SkipSysprepCheck # 跳过 sysprep 状态检查（不推荐）
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║   阶段 3/5（下）— 封箱母盘（设为只读）         ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$Base = Join-Path $VhdDir 'Base.vhdx'
$Record = Join-Path $VhdDir 'entry-base.json'

if (-not (Test-Path -LiteralPath $Base)) {
    Write-Err2 ('找不到 ' + $Base)
    exit 1
}

# ---------- 1. 检查 sysprep 状态 ----------
Write-Step '1. 检查母盘是否已 sysprep'

if ($SkipSysprepCheck) {
    Write-Warn2 '已按参数跳过检查'
} else {
    # sysprep 后系统处于 OOBE，注册表里会有 OOBEInProgress / SystemSetupInProgress
    $probe = Mount-VhdReadOnlyAndProbe -Path $Base `
             -Expect @('Windows\System32\config\SYSTEM', 'Windows\System32\winload.efi')
    if (-not $probe.Ok) {
        Write-Err2 ('无法读取母盘：' + $probe.Detail)
        exit 1
    }
    Write-Ok $probe.Detail

    # 读母盘里的 SYSTEM hive 检查 OOBE 标记
    $L = $probe.Letter
    $already = $true
    Write-Host ''
    Write-Host '  无法在离线状态下可靠判断 sysprep 是否执行过（需要加载注册表配置单元）。' -ForegroundColor Yellow
    Write-Host '  请自行确认：你在母盘系统里跑过下面这条命令，并且系统已自动关机：' -ForegroundColor Yellow
    Write-Host '    C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown' -ForegroundColor White
    Write-Host ''
    $ans = Read-Host '  确认已执行过 sysprep？输入 YES'
    if ($ans -cne 'YES') {
        Write-Err2 '未确认，停止。'
        Write-Info '如果还没封箱就设只读，派生出的 Work 会带着母盘的用户配置和 SID。'
        exit 1
    }
}

# ---------- 2. 确保已分离 ----------
Write-Step '2. 确母盘已分离'
$st = Dismount-VhdSafely -Path $Base
switch ($st) {
    'Detached'    { Write-Ok '已分离' }
    'InUseBySelf' { Write-Err2 'Base.vhdx 是当前系统盘 —— 你还在母盘系统里，请回到物理 Windows'; exit 1 }
    default       { Write-Err2 '分离失败，请手动检查'; exit 1 }
}

# ---------- 3. 设只读 ----------
Write-Step '3. 设为只读（关键步骤）'
$bf = Get-Item -LiteralPath $Base -Force
if ($bf.IsReadOnly) {
    Write-Info '已经是只读，无需改动'
} else {
    Set-ItemProperty -LiteralPath $Base -Name IsReadOnly -Value $true -ErrorAction Stop
    $chk = (Get-Item -LiteralPath $Base).IsReadOnly
    if ($chk) { Write-Ok 'Base.vhdx 已设为只读' }
    else { Write-Err2 '设置只读失败！不要继续'; exit 1 }
}

# 用 attrib 双保险（有些环境 FileStream 会绕过属性）
& attrib.exe +R $Base 2>&1 | Out-Null
$chk2 = (Get-Item -LiteralPath $Base).IsReadOnly
Write-Ok ('只读属性确认：' + $chk2)

# ---------- 4. 记录指纹 ----------
Write-Step '4. 记录母盘指纹'
$bf = Get-Item -LiteralPath $Base -Force
$fingerprint = @{
    BaseLength     = $bf.Length
    BaseWriteTicks = $bf.LastWriteTimeUtc.Ticks
    BaseWriteTime  = $bf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    BaseReadOnly   = $bf.IsReadOnly
    SealedAt       = (Get-Date).ToString('s')
}

$rec = Load-JsonRecord $Record
if ($rec) {
    # 合并到已有记录
    $merged = @{}
    $rec.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
    $fingerprint.Keys | ForEach-Object { $merged['Sealed_' + $_] = $fingerprint[$_] }
    Save-JsonRecord -Data $merged -Path $Record
} else {
    Write-Warn2 '没有找到 entry-base.json（03 脚本应该生成过）'
    Save-JsonRecord -Data $fingerprint -Path $Record
}

Write-Info ('母盘大小：' + $bf.Length + ' 字节（' + [math]::Round($bf.Length / 1GB, 2) + ' GB）')
Write-Info ('母盘时间：' + $bf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))

# ---------- 5. 从菜单移除 ----------
Write-Step '5. 从启动菜单移除母盘项'
if ($KeepInMenu) {
    Write-Warn2 '已按参数保留在菜单中。注意：误启动并改动会让母盘不干净。'
} else {
    $rec2 = Load-JsonRecord $Record
    $baseGuid = if ($rec2 -and $rec2.Guid) { [string]$rec2.Guid } else { $null }

    if (-not $baseGuid) {
        # 从 BCD 里找
        $found = @(Get-BcdBootLoaders | Where-Object { $_.IsVhd -and $_.Device -match 'Base\.vhdx' })
        if ($found.Count -gt 0) { $baseGuid = $found[0].Id }
    }

    if ($baseGuid) {
        Remove-BootEntryFromMenu -Guid $baseGuid
        Write-Info ('启动项 ' + $baseGuid + ' 仍在 BCD 中，随时可恢复：')
        Write-Info ('  bcdedit /displayorder ' + $baseGuid + ' /addlast')
    } else {
        Write-Warn2 '找不到母盘启动项的 GUID，跳过'
    }
}

# ---------- 完成 ----------
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  阶段 3 完成：母盘已封箱' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  母盘状态：' -ForegroundColor Cyan
Write-Host ('    只读      : ' + (Get-Item $Base).IsReadOnly) -ForegroundColor Gray
Write-Host ('    大小      : ' + [math]::Round((Get-Item $Base).Length / 1GB, 2) + ' GB') -ForegroundColor Gray
Write-Host ('    时间戳    : ' + (Get-Item $Base).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
Write-Host ''
Write-Host '  下一步：05-create-work.ps1（派生差分盘 + 加启动项）' -ForegroundColor Cyan
Write-Host ''
Write-Host '  重要：从现在起不要再启动母盘并修改它。' -ForegroundColor Red
Write-Host '        需要改母盘内容时，必须先取消只读 → 启动 → 改 → 重新 sysprep → 重新只读。' -ForegroundColor Red
Write-Host ''
