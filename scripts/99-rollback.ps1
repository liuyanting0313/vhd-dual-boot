<#
=====================================================================
 99-rollback.ps1 — 回滚工具
=====================================================================
 在物理 Windows 里运行。安全撤销各阶段做的改动。

 覆盖六种回滚：
    -Bcd         从备份恢复 BCD（核选项）
    -BaseEntry   删除母盘启动项
    -WorkEntry   删除 Work 启动项，并把母盘放回菜单
    -Env         恢复快速启动、休眠、VHD 自动扩展等设置
    -Unseal      取消母盘只读（要改母盘内容时才用）
    -Everything  以上全部（不含 Bcd，那个要单独确认）

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\99-rollback.ps1 -BaseEntry
   powershell -NoProfile -ExecutionPolicy Bypass -File .\99-rollback.ps1 -WorkEntry
   powershell -NoProfile -ExecutionPolicy Bypass -File .\99-rollback.ps1 -Env
   powershell -NoProfile -ExecutionPolicy Bypass -File .\99-rollback.ps1 -Everything
   powershell -NoProfile -ExecutionPolicy Bypass -File .\99-rollback.ps1 -Bcd
#>

param(
    [string]$DataLabel = 'Data',
    [switch]$Bcd,
    [switch]$BaseEntry,
    [switch]$WorkEntry,
    [switch]$Env,
    [switch]$Unseal,
    [switch]$Everything
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '╔═══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║              回滚工具                          ║' -ForegroundColor Cyan
Write-Host '╚═══════════════════════════════════════════════╝' -ForegroundColor Cyan

Assert-Admin
Assert-PhysicalSystem

$dv = Get-DataVolume -Label $DataLabel
$DataDrive = [string]$dv.DriveLetter
$VhdDir = Join-Path ($DataDrive + ':') 'VHD'
$LogDir = Join-Path $VhdDir 'Logs'
$Base   = Join-Path $VhdDir 'Base.vhdx'

$stateFile = Join-Path $VhdDir 'state.json'
$recBase   = Join-Path $VhdDir 'entry-base.json'
$recWork   = Join-Path $VhdDir 'entry-work.json'

if (-not ($Bcd -or $BaseEntry -or $WorkEntry -or $Env -or $Unseal -or $Everything)) {
    Write-Warn2 '没有指定要回滚什么。可用参数：'
    Write-Info '  -BaseEntry   删除母盘启动项'
    Write-Info '  -WorkEntry   删除 Work 启动项并把母盘放回菜单'
    Write-Info '  -Env         恢复快速启动/休眠/VHD自动扩展'
    Write-Info '  -Unseal      取消母盘只读'
    Write-Info '  -Bcd         从备份恢复 BCD（核选项）'
    Write-Info '  -Everything  以上除 -Bcd 外全部'
    exit 0
}

$confirmAll = $Everything
if ($confirmAll) {
    $Bcd = $false; $BaseEntry = $true; $WorkEntry = $true; $Env = $true; $Unseal = $false
    Write-Warn2 '-Everything 会执行：BaseEntry + WorkEntry + Env'
    Write-Info '（不会动 BCD 备份恢复，也不会取消母盘只读）'
}

# ============================================================
# 1. 删除启动项
# ============================================================
function Remove-VhdEntriesByFile {
    param([string]$VhdFileName)
    $found = @(Get-BcdBootLoaders | Where-Object { $_.IsVhd -and $_.Device -match [regex]::Escape($VhdFileName) })
    if ($found.Count -eq 0) {
        Write-Info ('BCD 里没有指向 ' + $VhdFileName + ' 的启动项')
        return @()
    }
    Write-Ok ('找到 ' + $found.Count + ' 个指向 ' + $VhdFileName + ' 的启动项：')
    $removed = @()
    foreach ($f in $found) {
        Write-Info ('  ' + $f.Id + '  ' + $f.Description)
        # 先移出菜单
        & bcdedit /displayorder $f.Id /remove 2>&1 | Out-Null
        # 再删除
        if (Remove-BcdEntry -Guid $f.Id) { $removed += $f.Id }
    }
    return $removed
}

if ($BaseEntry) {
    Write-Step '回滚：删除母盘启动项'
    $removed = Remove-VhdEntriesByFile 'Base.vhdx'
    if ($removed.Count -gt 0) {
        # 记录改名
        if (Test-Path -LiteralPath $recBase) {
            $new = $recBase -replace '\.json$', ('.rolledback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            Rename-Item -LiteralPath $recBase -NewName (Split-Path $new -Leaf)
            Write-Info ('记录已改名：' + (Split-Path $new -Leaf))
        }
    }
    Write-Ok 'Base.vhdx 本身未删除'
}

if ($WorkEntry) {
    Write-Step '回滚：删除 Work 启动项'

    # 先记住母盘 GUID，删完要把母盘放回菜单
    $baseGuid = $null
    $rb = Load-JsonRecord $recBase
    if ($rb -and $rb.Guid) { $baseGuid = [string]$rb.Guid }
    if (-not $baseGuid) {
        $bd = @(Get-BcdBootLoaders | Where-Object { $_.IsVhd -and $_.Device -match 'Base\.vhdx' })
        if ($bd.Count -gt 0) { $baseGuid = $bd[0].Id }
    }

    $removed = Remove-VhdEntriesByFile 'Work.vhdx'

    if ($removed.Count -gt 0 -and $baseGuid) {
        $all = (& bcdedit /enum all 2>&1) | Out-String
        if ($all -match [regex]::Escape($baseGuid)) {
            Add-BootEntryToMenu -Guid $baseGuid
            Write-Info '母盘启动项已放回菜单'
        }
    }

    if (Test-Path -LiteralPath $recWork) {
        $new = $recWork -replace '\.json$', ('.rolledback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Rename-Item -LiteralPath $recWork -NewName (Split-Path $new -Leaf)
        Write-Info ('记录已改名：' + (Split-Path $new -Leaf))
    }
    Write-Ok 'Work.vhdx 本身未删除，母盘未改动'
}

# ============================================================
# 2. 恢复环境设置
# ============================================================
if ($Env) {
    Write-Step '回滚：恢复系统设置'

    $state = Load-JsonRecord $stateFile
    if (-not $state) {
        Write-Warn2 '找不到 state.json，无法知道原始值，跳过'
    } else {
        # 快速启动
        $hbBefore = $state.HiberbootEnabledBefore
        if ($null -ne $hbBefore) {
            try {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                    -Name HiberbootEnabled -Value ([int]$hbBefore) -Type DWord -ErrorAction Stop
                Write-Ok ('HiberbootEnabled 恢复为 ' + $hbBefore)
            } catch { Write-Warn2 ('恢复快速启动失败：' + $_.Exception.Message) }
        } else {
            Write-Info '原始 HiberbootEnabled 未记录（原本是未设置）'
        }

        # 休眠
        if ($state.HiberFileExistedBefore -eq $true) {
            try {
                $r = & powercfg /hibernate on 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok '休眠已重新启用（hiberfil.sys 会重建）' }
                else { Write-Warn2 ('powercfg 返回：' + ($r | Out-String).Trim()) }
            } catch { Write-Warn2 ('启用休眠失败：' + $_.Exception.Message) }
        } else {
            Write-Info '原本休眠就是关的，不需要恢复'
        }

        # VHD 自动扩展
        $vdBefore = $state.VirtualDiskExpandOnMountBefore
        if ($null -ne $vdBefore) {
            try {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' `
                    -Name VirtualDiskExpandOnMount -Value ([int]$vdBefore) -Type DWord -ErrorAction Stop
                Write-Ok ('VirtualDiskExpandOnMount 恢复为 ' + $vdBefore)
            } catch { Write-Warn2 ('恢复失败：' + $_.Exception.Message) }
        } else {
            Write-Info '原始 VirtualDiskExpandOnMount 未记录（原本是未设置）'
            # 删掉我们加的键值
            try {
                Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\vds' `
                    -Name VirtualDiskExpandOnMount -ErrorAction Stop
                Write-Ok '已移除 VirtualDiskExpandOnMount（恢复到原本未设置的状态）'
            } catch { Write-Info '该值不存在，无需移除' }
        }

        # 菜单超时
        if ($null -ne $state.TimeoutBefore) {
            Set-BcdTimeout -Seconds ([int]$state.TimeoutBefore)
        }
    }
}

# ============================================================
# 3. 取消母盘只读
# ============================================================
if ($Unseal) {
    Write-Step '回滚：取消母盘只读'

    if (-not (Test-Path -LiteralPath $Base)) {
        Write-Err2 ('找不到 ' + $Base)
    } else {
        Write-Warn2 '取消只读后，所有基于它的差分盘都会失效（父盘可写 = 链不可靠）'
        Write-Info '只在需要修改母盘内容时这么做，改完必须重新 sysprep 并重新设只读'
        Write-Host ''
        $ans = Read-Host '  确认取消只读？输入 UNSEAL'
        if ($ans -cne 'UNSEAL') {
            Write-Info '已取消'
        } else {
            $st = Dismount-VhdSafely -Path $Base
            if ($st -ne 'Detached') { Write-Err2 ('无法分离母盘：' + $st); exit 1 }
            Set-ItemProperty -LiteralPath $Base -Name IsReadOnly -Value $false
            & attrib.exe -R $Base 2>&1 | Out-Null
            $chk = (Get-Item -LiteralPath $Base).IsReadOnly
            if ($chk) { Write-Err2 '取消只读失败' }
            else { Write-Ok '母盘已可写' }
        }
    }
}

# ============================================================
# 4. 从备份恢复 BCD（核选项）
# ============================================================
if ($Bcd) {
    Write-Step '回滚：从备份恢复 BCD'

    if (-not (Test-Path -LiteralPath $LogDir)) {
        Write-Err2 ('找不到备份目录 ' + $LogDir)
    } else {
        $backups = @(Get-ChildItem -LiteralPath $LogDir -Filter 'BCD_Backup_*' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notmatch '\.LOG' } | Sort-Object LastWriteTime -Descending)

        if ($backups.Count -eq 0) {
            Write-Err2 '没有找到任何 BCD 备份'
        } else {
            Write-Warn2 '即将用备份覆盖当前 BCD'
            Write-Info '现有 BCD 会先被导出一份新的备份'
            Write-Host ''
            Write-Info '可用备份（新 -> 旧）：'
            for ($i = 0; $i -lt $backups.Count; $i++) {
                Write-Info ('  [' + $i + '] ' + $backups[$i].Name +
                            '  ' + $backups[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') +
                            '  ' + $backups[$i].Length + ' 字节')
            }
            Write-Host ''
            Write-Host '  恢复 BCD 是核选项：会丢失之后所有的启动项改动。' -ForegroundColor Red
            Write-Host '  如果只是想让菜单干净，用 -BaseEntry / -WorkEntry 更安全。' -ForegroundColor Yellow
            Write-Host ''
            $idx = Read-Host ('  选择备份序号 [0-' + ($backups.Count - 1) + ']，直接回车取消')
            if ($idx -match '^\d+$' -and [int]$idx -lt $backups.Count) {
                $chosen = $backups[[int]$idx]

                $ans = Read-Host '  再确认一次：输入 RESTORE-BCD'
                if ($ans -cne 'RESTORE-BCD') {
                    Write-Info '已取消'
                } else {
                    $safety = Backup-Bcd -LogDir $LogDir
                    Write-Info ('当前 BCD 已另存：' + (Split-Path $safety -Leaf))
                    & bcdedit /import $chosen.FullName 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok ('已从 ' + $chosen.Name + ' 恢复')
                    } else {
                        Write-Err2 '恢复失败，请用备份手动 import'
                    }
                }
            } else {
                Write-Info '已取消'
            }
        }
    }
}

# ============================================================
# 汇总
# ============================================================
Write-Host ''
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  回滚执行完毕' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host '  当前 BCD 启动项：' -ForegroundColor Gray
Get-BcdBootLoaders | ForEach-Object {
    $tag = if ($_.IsVhd) { '[VHD]' } elseif ($_.IsRamdisk) { '[WIM]' } else { '[物理]' }
    Write-Host ('    ' + $tag.PadRight(6) + ' ' + $_.Id.PadRight(42) + ' ' + $_.Description) -ForegroundColor Gray
}
Write-Host ''
Write-Host '  当前 VHD：' -ForegroundColor Gray
Get-ChildItem -LiteralPath $VhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        $i = Get-VhdInfo $_.FullName
        $t = if ($i.Type -eq 'Differencing') { '差分' } elseif ($i.Ok) { '独立' } else { '?' }
        $ro = if ($_.IsReadOnly) { '只读' } else { '可写' }
        Write-Host ('    ' + $_.Name.PadRight(40) + ' ' +
                    [math]::Round($_.Length / 1GB, 2).ToString().PadLeft(7) + ' GB  ' +
                    $t + '  ' + $ro) -ForegroundColor Gray
    }
Write-Host ''
