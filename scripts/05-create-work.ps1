<#
=====================================================================
 05-create-work.ps1 — 阶段 4+5/5：派生 Work 并加入启动菜单
=====================================================================
 在物理 Windows 里运行。

 做六件事：
   1. 全面校验母盘（只读、类型、指纹）
   2. 检查有没有"孙盘"依赖
   3. 从 Base 派生 Work.vhdx
   4. 完整链检查（只读挂载，实读 winload.efi）
   5. 创建 Work 启动项并加入菜单
   6. 写 entry-work.json

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\05-create-work.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File .\05-create-work.ps1 -WorkName Work
   powershell -NoProfile -ExecutionPolicy Bypass -File .\05-create-work.ps1 -Reset   # 重置已有 Work
#>

param(
    [string]$DataLabel = 'Data',
    [string]$WorkName  = 'Work',
    [string]$Description = 'Win11-Work',
    [int]$Timeout = 30,
    [switch]$Reset,          # 重置模式：旧 Work 改名保留
    [switch]$NoMenu          # 只建盘不建启动项
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║   阶段 4+5/5 — 派生 Work 差分盘                ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$LogDir = Join-Path $VhdDir 'Logs'
$Base = Join-Path $VhdDir 'Base.vhdx'
$Work = Join-Path $VhdDir ($WorkName + '.vhdx')
$RecBase = Join-Path $VhdDir 'entry-base.json'
$RecWork = Join-Path $VhdDir 'entry-work.json'

# ============================================================
# 1. 校验母盘
# ============================================================
Write-Step '1. 校验母盘'

if (-not (Test-Path -LiteralPath $Base)) {
    Write-Err2 ('找不到母盘 ' + $Base)
    Write-Info '请先完成 02 / 03 / 04'
    exit 1
}

$bi = Get-VhdInfo $Base
if (-not $bi.Ok) { Write-Err2 ('读不出母盘：' + $bi.Detail); exit 1 }

Write-Info ('类型        : ' + $bi.Type)
Write-Info ('虚拟大小    : ' + [math]::Round($bi.VirtualSizeBytes / 1GB, 1) + ' GB')
Write-Info ('实际大小    : ' + [math]::Round((Get-Item $Base).Length / 1GB, 2) + ' GB')

if ($bi.Type -eq 'Differencing') {
    Write-Err2 '母盘本身是差分盘，不能作为父盘（会产生孙盘）'
    exit 1
}
if ($bi.Attached) {
    Write-Warn2 '母盘处于挂载状态，自动分离'
    $r = Dismount-VhdSafely -Path $Base
    if ($r -ne 'Detached') { Write-Err2 ('分离失败：' + $r); exit 1 }
}

$bf = Get-Item -LiteralPath $Base -Force
if (-not $bf.IsReadOnly) {
    Write-Warn2 '母盘不是只读！自动设为只读'
    Set-ItemProperty -LiteralPath $Base -Name IsReadOnly -Value $true
    Write-Ok '已设为只读'
} else {
    Write-Ok '母盘只读状态正确'
}

# 指纹比对
$recBase = Load-JsonRecord $RecBase
if ($recBase -and $recBase.Sealed_BaseLength) {
    if ([int64]$recBase.Sealed_BaseLength -ne $bf.Length) {
        Write-Warn2 '母盘大小与封箱时记录不一致！'
        Write-Info ('  记录：' + $recBase.Sealed_BaseLength + ' 字节')
        Write-Info ('  现在：' + $bf.Length + ' 字节')
        Write-Info '  母盘可能被改动过，已有的子盘可能失效。'
    } elseif ([int64]$recBase.Sealed_BaseWriteTicks -ne $bf.LastWriteTimeUtc.Ticks) {
        Write-Warn2 '母盘时间戳与封箱时不一致（可能只是属性变动，通常无害）'
    } else {
        Write-Ok '母盘指纹与封箱记录一致'
    }
} else {
    Write-Info '没有封箱指纹记录（entry-base.json），跳过比对'
}

# ============================================================
# 2. 检查孙盘
# ============================================================
Write-Step '2. 检查是否有以母盘为父盘的其他差分盘'

$siblings = @()
Get-ChildItem -LiteralPath $VhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $Base } |
    ForEach-Object {
        $ci = Get-VhdInfo $_.FullName
        if ($ci.Ok -and $ci.Type -eq 'Differencing' -and
            $ci.Parent -and $ci.Parent -match [regex]::Escape((Split-Path $Base -Leaf))) {
            $siblings += $_
        }
    }

if ($siblings.Count -gt 0) {
    Write-Info ('已有 ' + $siblings.Count + ' 个差分盘基于此母盘（这是正常的，可共存）：')
    $siblings | ForEach-Object { Write-Info ('  ' + $_.Name) }
} else {
    Write-Info '没有其他差分盘'
}

# ============================================================
# 3. 处理已有 Work
# ============================================================
Write-Step '3. 处理目标差分盘'

$needCreate = $true
if (Test-Path -LiteralPath $Work) {
    $wi = Get-VhdInfo $Work
    $wsz = [math]::Round((Get-Item $Work).Length / 1GB, 2)
    Write-Warn2 ('已存在 ' + (Split-Path $Work -Leaf) + '（' + $wsz + ' GB，' + $wi.Type + '）')

    if ($wi.Attached) {
        Write-Warn2 '它当前处于挂载状态'
        $r = Dismount-VhdSafely -Path $Work
        if ($r -eq 'InUseBySelf') {
            Write-Err2 '它就是当前运行的系统的盘 —— 你还在 Work 里'
            exit 1
        }
    }

    # 检查有没有孙盘（以 Work 为父盘）
    $grand = @(Get-ChildItem -LiteralPath $VhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $Work -and $_.FullName -ne $Base } |
        ForEach-Object {
            $g = Get-VhdInfo $_.FullName
            if ($g.Ok -and $g.Type -eq 'Differencing' -and
                $g.Parent -and $g.Parent -match [regex]::Escape((Split-Path $Work -Leaf))) { $_ }
        })
    if ($grand.Count -gt 0) {
        Write-Err2 ('下面这些盘以 Work 为父盘，重置会让它们失效：')
        $grand | ForEach-Object { Write-Info ('  ' + $_.Name) }
        exit 1
    }

    if ($Reset) {
        Write-Info '重置模式：旧 Work 将改名保留，不删除'
    } else {
        Write-Host ''
        Write-Host '  目标已存在。可选操作：' -ForegroundColor Yellow
        Write-Host '    R  重置（旧盘改名保留，新建一个干净的）' -ForegroundColor Gray
        Write-Host '    O  覆盖（直接删除旧盘，不可恢复）' -ForegroundColor Gray
        Write-Host '    其他  取消' -ForegroundColor Gray
        $ans = Read-Host '  选择'
        switch ($ans.ToUpper()) {
            'R' { $Reset = $true }
            'O' { $needCreate = $true; Remove-Item -LiteralPath $Work -Force; Write-Ok '旧盘已删除' }
            default { Write-Info '已取消'; exit 0 }
        }
    }

    if ($Reset) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $old = Join-Path $VhdDir ($WorkName + '.replaced-' + $stamp + '.vhdx')
        Rename-Item -LiteralPath $Work -NewName (Split-Path $old -Leaf) -ErrorAction Stop
        Write-Ok ('旧盘已改名为 ' + (Split-Path $old -Leaf))
        Write-Info ('它仍占用 ' + [math]::Round((Get-Item $old).Length / 1GB, 2) + ' GB，确认不需要后可手动删除')
    }
}

# ============================================================
# 4. 派生
# ============================================================
if ($needCreate) {
    Write-Step '4. 从母盘派生差分盘'
    try {
        $ci = New-DifferencingVhd -ParentPath $Base -ChildPath $Work
    } catch {
        Write-Err2 $_.Exception.Message
        exit 1
    }
}

# ============================================================
# 5. 链检查
# ============================================================
Write-Step '5. 链完整性检查（关键）'
Write-Info '只读挂载新盘，实际读取系统引导文件'

$chain = Test-VhdChain -ChildPath $Work -ParentPath $Base
if ($chain.Ok) {
    Write-Ok '链检查通过 —— 新盘可以从母盘读到系统文件'
} else {
    Write-Err2 '链检查失败：'
    $chain.Problems | ForEach-Object { Write-Info ('  - ' + $_) }
    Write-Host ''
    Write-Host '  新盘无法启动。可能原因：' -ForegroundColor Yellow
    Write-Host '    - 母盘里没有部署 Windows（winload.efi 不存在）' -ForegroundColor Gray
    Write-Host '    - 母盘路径/文件名被改动' -ForegroundColor Gray
    Write-Host '    - 母盘损坏' -ForegroundColor Gray
    Write-Host ''
    $ans = Read-Host '  是否删除这个坏盘？(Y/N)'
    if ($ans -eq 'Y') { Remove-Item -LiteralPath $Work -Force; Write-Ok '已删除' }
    exit 1
}

# ============================================================
# 6. 启动项
# ============================================================
$workGuid = $null
if ($NoMenu) {
    Write-Step '6. 跳过启动项（-NoMenu）'
} else {
    Write-Step '6. 创建 Work 启动项'

    $recW = Load-JsonRecord $RecWork
    if ($recW -and $recW.Guid) {
        $chk = (& bcdedit /enum ([string]$recW.Guid) 2>&1) | Out-String
        if ($chk -notmatch 'error|找不到|not found|指定的') {
            Write-Info ('已有启动项 ' + $recW.Guid + '，沿用')
            $workGuid = [string]$recW.Guid
            # 确认指向正确
            if ($chk -notmatch [regex]::Escape($WorkName + '.vhdx')) {
                Write-Warn2 '启动项指向的文件名与当前不一致，重新设置'
                $bcdPath = '[' + $DataDrive + ':]\VHD\' + $WorkName + '.vhdx'
                & bcdedit /set $workGuid device   ("vhd=$bcdPath") 2>&1 | Out-Null
                & bcdedit /set $workGuid osdevice ("vhd=$bcdPath") 2>&1 | Out-Null
                Write-Ok '已修正指向'
            }
        }
    }

    if (-not $workGuid) {
        $bcdBackup = Backup-Bcd -LogDir $LogDir
        $bcdPath = '[' + $DataDrive + ':]\VHD\' + $WorkName + '.vhdx'
        $workGuid = New-VhdBootEntry -VhdPath $bcdPath -Description $Description
    }

    Add-BootEntryToMenu -Guid $workGuid
    if ($Timeout -gt 0) { Set-BcdTimeout -Seconds $Timeout }
}

# ============================================================
# 7. 记录
# ============================================================
Write-Step '7. 记录'

$wInfo = Get-VhdInfo $Work
$rec = @{
    Stage          = 'work'
    CreatedAt      = (Get-Date).ToString('s')
    WorkGuid       = $workGuid
    Description    = $Description
    BasePath       = $Base
    WorkPath       = $Work
    BaseLength     = (Get-Item $Base).Length
    BaseWriteTicks = (Get-Item $Base).LastWriteTimeUtc.Ticks
    WorkLength     = (Get-Item $Work).Length
    WorkType       = $wInfo.Type
}
$old = Load-JsonRecord $RecWork
if ($old) {
    $merged = @{}
    $old.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
    $rec.Keys | ForEach-Object { $merged[$_] = $rec[$_] }
    Save-JsonRecord -Data $merged -Path $RecWork
} else {
    Save-JsonRecord -Data $rec -Path $RecWork
}

# ============================================================
# 完成
# ============================================================
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  全部完成！差分双系统已就绪' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  母盘（只读）：' -ForegroundColor Cyan
Write-Host ('    ' + $Base) -ForegroundColor Gray
Write-Host ('    ' + [math]::Round((Get-Item $Base).Length / 1GB, 2) + ' GB  只读=' + (Get-Item $Base).IsReadOnly) -ForegroundColor Gray
Write-Host ''
Write-Host '  工作盘（差分）：' -ForegroundColor Cyan
Write-Host ('    ' + $Work) -ForegroundColor Gray
Write-Host ('    ' + [math]::Round((Get-Item $Work).Length / 1MB, 1) + ' MB  类型=' + $wInfo.Type) -ForegroundColor Gray
Write-Host ''
if ($workGuid) {
    Write-Host ('  Work 启动项：' + $workGuid) -ForegroundColor Cyan
}
Write-Host ''
Write-Host '  下一步：重启，在启动菜单选择 "' + $Description + '"' -ForegroundColor Yellow
Write-Host '        首次启动会走 OOBE（因为母盘 sysprep 过）' -ForegroundColor Gray
Write-Host ''
Write-Host '  以后想重置：' -ForegroundColor Cyan
Write-Host '    powershell -File .\05-create-work.ps1 -Reset' -ForegroundColor Gray
Write-Host ''
