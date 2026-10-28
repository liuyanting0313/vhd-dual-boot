# 脚本说明

> 所有脚本都必须**在物理 Windows（管理员）里运行**，唯一的例外是在母盘系统里手动跑 `sysprep`。
> 每个脚本开头都会检查 `Test-InVhd`，检测到你在 Work 里会直接退出。

## 目录

- [执行顺序](#执行顺序)
- [逐脚本说明](#逐脚本说明)
- [公共参数](#公共参数)
- [公共函数库](#公共函数库)
- [编码约定](#编码约定)
- [测试](#测试)

---

## 执行顺序

```
00-check         环境预检（只读）
   ↓
01-prepare       备份 BCD + 关快速启动
   ↓
02-create-base   建空母盘
   ↓
   ★ 手动：DISM 部署 Windows + bcdboot
   ↓
03-add-base-entry  加母盘启动项
   ↓
   ★ 手动：重启进母盘 → 配置 → sysprep /shutdown
   ↓
04-seal-base     设只读 + 移出菜单
   ↓
05-create-work   派生 Work + 链检查 + 加启动项
   ↓
   ★ 重启，选 Win11-Work
```

或者直接跑 `build.cmd`，它有交互菜单并自动提权。

---

## 逐脚本说明

### `00-check.ps1` — 环境预检

只读，不改任何东西。检查 8 项：

| 检查项 | 判据 |
|---|---|
| 管理员权限 | `WindowsPrincipal.IsInRole` |
| 不在 VHD 里 | `BusType` + `bcdedit /enum {current}` |
| UEFI 引导 | 存在 `Type=System` 且 FAT32 的分区 |
| 数据盘存在 | 卷标匹配且恰好 1 个 |
| 可用空间 | ≥ 120 GB |
| 快速启动 | `HiberbootEnabled` |
| PowerShell 版本 | ≥ 5.1 |
| diskpart 可用 | `Get-Command diskpart` |

有红项就 `exit 1`，不会往下走。

```powershell
.\00-check.ps1
.\00-check.ps1 -DataLabel MyData
```

### `01-prepare.ps1` — 环境准备

幂等，可重复跑。做五件事：

1. **备份 BCD** → `VHD\Logs\BCD_Backup_<时间戳>`，失败直接中止
2. 创建 `VHD\` 和 `VHD\Logs\`
3. `powercfg /hibernate off` + `HiberbootEnabled=0`
4. `VirtualDiskExpandOnMount=0`
5. 把改动前的值写进 `state.json`（供 `99-rollback -Env` 恢复）

```powershell
.\01-prepare.ps1
.\01-prepare.ps1 -SkipHibernateOff     # 不关休眠，但 VHD 挂载可能失败
```

### `02-create-base.ps1` — 创建母盘

**只建空盘，不部署 Windows。**

```powershell
.\02-create-base.ps1                  # 默认 384 GB
.\02-create-base.ps1 -SizeGB 300
.\02-create-base.ps1 -Force           # 已存在时重建（会清空）
```

等价的手工操作：

```
create vdisk file="E:\VHD\Base.vhdx" maximum=393216 type=expandable
select vdisk file="E:\VHD\Base.vhdx"
attach vdisk
create partition primary
format fs=ntfs quick label=Base
```

跑完会打印部署 Windows 的完整 `DISM` + `bcdboot` 命令。

> **`bcdboot` 不能漏。** 没有它，VHD 里有系统文件但没法启动。

### `03-add-base-entry.ps1` — 加母盘启动项

1. 备份 BCD
2. 找物理系统的启动项做模板（`device` 为 `partition=` 且不含 `vhd=` / `ramdisk=` / `locate=`）
3. `bcdedit /copy` 出新项，改 `device` / `osdevice` / `path`
4. **回读验证**含 `vhd=`，否则删项并报错
5. 加入菜单、设超时
6. 写 `entry-base.json`

```powershell
.\03-add-base-entry.ps1
.\03-add-base-entry.ps1 -Description "MyBase" -Timeout 30
```

### `04-seal-base.ps1` — 封箱

**前提：已经在母盘里跑过 `sysprep /generalize /oobe /shutdown`。**

1. 检查 OOBE 状态标记（`-SkipSysprepCheck` 可跳过）
2. `attrib +R Base.vhdx`（**最关键**）
3. 记录指纹到 `entry-base.json`
4. 从菜单移除 Base 项（保留项本身）

```powershell
.\04-seal-base.ps1
.\04-seal-base.ps1 -KeepInMenu        # 不移出菜单
```

### `05-create-work.ps1` — 派生 Work

做六件事：

1. 校验母盘（只读 / 非差分盘 / 指纹比对）
2. 检查孙盘依赖（有则拒绝）
3. `diskpart` 派生差分盘
4. **链检查**：只读挂载 + 实读 `winload.efi`
5. 创建/更新 Work 启动项
6. 写 `entry-work.json`

```powershell
.\05-create-work.ps1                        # 首次创建
.\05-create-work.ps1 -Reset                 # 重置（旧盘改名保留）
.\05-create-work.ps1 -WorkName Work-Dev -Description "Win11-Dev"
```

`-Reset` 的旧盘会变成 `Work.replaced-<时间戳>.vhdx`，**不删除**。
如果链检查失败，脚本会把旧盘改回来。

### `99-rollback.ps1` — 回滚

| 开关 | 作用 |
|---|---|
| `-BaseEntry` | 删除母盘启动项 |
| `-WorkEntry` | 删除 Work 启动项，母盘放回菜单 |
| `-Env` | 从 `state.json` 恢复快速启动/休眠/自动扩展 |
| `-Unseal` | 取消母盘只读 |
| `-Everything` | 以上全部（不含 `-Bcd`） |
| `-Bcd` | 从备份恢复 BCD（**核选项，需二次确认**） |

```powershell
.\99-rollback.ps1 -Env
.\99-rollback.ps1 -WorkEntry
.\99-rollback.ps1 -Bcd -BackupFile "E:\VHD\Logs\BCD_Backup_20261016-060305"
```

**所有回滚都不删 VHD 文件。**

---

## 公共参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DataLabel` | `Data` | 数据盘卷标。改过卷标的话每个脚本都要加 |
| `-WorkName` | `Work` | 差分盘名（`05`） |
| `-Description` | `Win11-Base-VHD` / `Win11-Work` | 启动菜单显示名 |
| `-Timeout` | `30` | 菜单等待秒数 |
| `-Force` | — | 覆盖已存在文件（`02`） |

---

## 公共函数库

`lib\Common.ps1`（约 21 KB，28 个函数）。所有脚本开头：

```powershell
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
```

### 输出

```powershell
Write-Step  '阶段标题'
Write-Ok    '成功'
Write-Warn2 '警告'      # 名字带 2，避开 PowerShell 内置 Verb-Warn 冲突
Write-Err2  '失败'
Write-Info  '补充说明'
```

### 安全检查

```powershell
Test-Admin                  # bool
Assert-Admin                # 失败即 throw
Test-InVhd                  # 当前系统是否从 VHD 启动
Assert-PhysicalSystem       # 在 VHD 里就退出
```

`Test-InVhd` 用双重判据（`BusType` 匹配 `Virtual`，或 `bcdedit /enum {current}` 含 `vhd=`），
单条判据失效时仍能拦住。

### 卷与 VHD

```powershell
Get-DataVolume                        # 按卷标找唯一卷，找不到/不唯一都 throw
Invoke-Diskpart -Lines @(...)         # 临时脚本 + 执行 + 清理
Get-VhdInfo -Path <p>                 # 返回 @{Ok;Type;Parent;SizeGB;Raw}
Get-VhdMainPartition -DiskNumber <n>  # 按大小找主分区（不看 Type）
Mount-VhdReadOnlyAndProbe             # 只读挂载 + 等到盘符出现 + 返回信息
Dismount-VhdSafely                    # 重试 5 次分离
New-DifferencingVhd                   # 派生（自动校验父盘只读）
Test-VhdChain                         # 链检查：实读 winload.efi
```

`Get-VhdInfo` 和 `Get-VhdMainPartition` 是本库最容易踩坑的两个函数，
对应 [pitfalls #5](../docs/04-pitfalls.md)（权限）和 [#13](../docs/04-pitfalls.md)（分区类型）。

### BCD

```powershell
Get-BcdBootLoaders          # 解析 /enum all，返回对象数组
Get-PhysicalBootEntry       # 找可做模板的物理启动项
Backup-Bcd                  # 导出到 Logs，失败 throw
New-VhdBootEntry            # 复制 + 改指向 + 回读验证 + 失败自动删项
Get-BcdTimeout / Set-BcdTimeout
Add-BootEntryToMenu / Remove-BootEntryFromMenu
Remove-BcdEntry
```

`New-VhdBootEntry` 包含三道防护（盘符预检 / 回读验证 / 失败删项），
对应 [pitfalls #14](../docs/04-pitfalls.md)。

### 记录

```powershell
Save-JsonRecord -Path <p> -Data <hashtable>
Load-JsonRecord -Path <p>       # 不存在返回 $null
```

---

## 编码约定

| 文件 | 编码 | 原因 |
|---|---|---|
| `*.ps1` | **UTF-8 with BOM** | PowerShell 5.1 无 BOM 会把中文当 ANSI，输出乱码 |
| `*.cmd` | **纯 ASCII** | `build.cmd` 用 `chcp 65001`，文件本身必须无中文无 BOM |

检查 BOM：

```powershell
Get-ChildItem *.ps1, lib\*.ps1 | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)[0..2]
    $hasBom = ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    '{0,-24} {1}' -f $_.Name, ($(if ($hasBom) { 'BOM OK' } else { '缺少 BOM' }))
}
```

检查 `build.cmd` 是纯 ASCII：

```powershell
$bytes = [IO.File]::ReadAllBytes('build.cmd')
$bad = @($bytes | Where-Object { $_ -gt 127 })
"非 ASCII 字节数: $($bad.Count)"     # 必须是 0
```

---

## 测试

本套脚本的验证分三层，全部在沙盒里做，**没碰过真实系统盘和系统 BCD**：

### 1. 语法解析

```powershell
Get-ChildItem *.ps1, lib\*.ps1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    '{0,-24} {1}' -f $_.Name, ($(if ($e.Count -eq 0) { 'PARSE-OK' } else { "ERR: $($e[0].Message)" }))
}
```

### 2. 函数单元测试

`Common.ps1` 的关键函数用 100-300 MB 的沙盒小盘验证（19 项）：

- `Get-VhdInfo` 正确区分 Base / Differencing
- `Get-VhdMainPartition` 在 `Type=IFS` 时仍能返回分区
- `Mount-VhdReadOnlyAndProbe` 能等到盘符
- `Test-VhdChain` 能透过差分盘读到父盘的文件
- `New-DifferencingVhd` 拒绝父盘非只读
- `Dismount-VhdSafely` 在锁定时重试

### 3. BCD 操作测试

**不在系统 BCD 上测。** 先导出副本，再用 `bcdedit /store`：

```powershell
bcdedit /export "$env:TEMP\bcd-test"
bcdedit /store "$env:TEMP\bcd-test" /enum all
bcdedit /store "$env:TEMP\bcd-test" /copy {default} /d "TEST"
```

这样每个命令都是真实执行的，但完全没有风险。10/10 通过。

---

## 已知设计取舍

| 取舍 | 理由 |
|---|---|
| 用 `diskpart` 不用 `Get-VHD` | `Get-VHD` 需要 Hyper-V 管理员权限，普通管理员会静默返回空 |
| 重置旧盘改名不删除 | 自动删除太危险，见 [真实故障案例](../docs/07-real-environment.md#7-一个真实的故障案例) |
| 不自动 `Optimize-VHD` | 需要 Hyper-V 模块，且容易在错误时机跑 |
| `bcdedit` 后必回读 | 退出码不可信，见 pitfalls #14 |
| 不用 `-ErrorAction SilentlyContinue` 判安全 | 权限不足会被误判为"安全"，见 pitfalls #5 |

---

## 下一步

- [构建指南](../docs/03-build-guide.md)
- [避坑指南](../docs/04-pitfalls.md)
- [排错](../docs/06-troubleshooting.md)

