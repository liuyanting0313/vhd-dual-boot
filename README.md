<div align="center">

# VHD Dual Boot

**Windows 11 差分双系统 —— 母盘只读，工作盘随便折腾，一键回到出厂状态**

[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D6?logo=windows&logoColor=white)](#前置条件)
[![Boot](https://img.shields.io/badge/boot-UEFI%20%2B%20GPT-4B8BBE)](#前置条件)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#快速开始)
[![Validated](https://img.shields.io/badge/tests-14%2F14%20passed-success)](#验证记录)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[原理](#这是什么) · [快速开始](#快速开始) · [文档索引](#文档索引) · [避坑指南](docs/04-pitfalls.md) · [排错](docs/06-troubleshooting.md)

</div>

---

## 这是什么

一套**原生 VHD 启动**的差分双系统。不是虚拟机 —— 直接跑在裸金属上，性能零损耗。

```
                 ┌──────────────────────────────┐
    物理 Windows  │  Windows 11          (D:)     │  ← 日常主用，稳定不动
     (宿主系统)   └──────────────┬───────────────┘
                                │
                 ┌──────────────▼───────────────┐
                 │  Base.vhdx   (只读母盘)       │  ← 干净的 Windows，永不改变
                 │  实测 48 GB / 384 GB 虚拟       │
                 └──────────────┬───────────────┘
                                │  copy-on-write
                 ┌──────────────▼───────────────┐
    Work 系统     │  Work.vhdx   (差分盘)         │  ← 装软件、改配置、删文件
     (工作系统)   │  初始 4 MB，用着变大           │     所有修改只写在这里
                 └──────────────────────────────┘
```

**开机是一个启动菜单，选哪个进哪个。**

---

## 为什么值得用

| 痛点 | 传统做法 | 这套方案 |
|---|---|---|
| 装软件把系统搞乱了 | 忍着，或者重装 | **删掉 `Work.vhdx`，几秒重建一个干净的** |
| 想试试危险的系统改动 | 虚拟机（性能差）/ 双系统（要分区） | 差分盘，裸金属性能，不动分区表 |
| 需要多个隔离环境 | 装 N 个虚拟机（每个几十 GB） | 同一母盘派生多个差分盘，**每个初始 4 MB** |
| 系统备份 | 整盘镜像（几百 GB） | 母盘只备份一次，子盘随时重建 |

**核心特性**

- ✅ **不占额外空间** — 差分盘只记录差异，初始 4 MB
- ✅ **零性能损耗** — 原生启动，不是虚拟化
- ✅ **秒级回滚** — 从母盘重新派生一个，几秒钟
- ✅ **可多分支** — 同一母盘派生 Work1 / Work2 / Work3，互不干扰
- ✅ **不动分区表** — 全部在文件层面操作
- ✅ **可逆** — 所有 BCD 改动都有备份，一条命令撤销

---

## 快速开始

### 0. 环境检查（只读，随便跑）

```powershell
# 管理员 PowerShell
git clone https://github.com/liuyanting0313/vhd-dual-boot.git
cd vhd-dual-boot\scripts

powershell -NoProfile -ExecutionPolicy Bypass -File .\00-check.ps1
```

**全绿再往下走。** 有红项先解决（见 [前置条件](docs/02-prerequisites.md)）。

### 1-5. 按顺序执行

```powershell
.\01-prepare.ps1          # 备份 BCD + 关快速启动
.\02-create-base.ps1      # 创建空母盘（之后手动部署 Windows）
.\03-add-base-entry.ps1   # 给母盘加启动项 → 重启进母盘配置 → sysprep
.\04-seal-base.ps1        # 封箱：设只读 + 移出菜单
.\05-create-work.ps1      # 派生 Work + 链检查 + 加启动项
```

**或者双击 `scripts\build.cmd`**，它有交互菜单，自动提权。

### 完成后

重启，启动菜单里会多一项 **`Win11-Work`**。选它，就是一个全新的、和母盘隔离的工作系统。

**以后想重置：**

```powershell
.\05-create-work.ps1 -Reset      # 旧盘改名保留，不删除
```

---

## 每一步在做什么

| 脚本 | 作用 | 可否重复跑 | 风险 |
|---|---|---|---|
| `00-check.ps1` | 检查 8 项环境条件 | ✅ 只读 | 无 |
| `01-prepare.ps1` | 备份 BCD、建目录、关快速启动/休眠 | ✅ 幂等 | 低（可回滚） |
| `02-create-base.ps1` | 建空 VHDX + 分区 + 格式化 | ⚠️ 会重建 | 中 |
| `03-add-base-entry.ps1` | 加母盘启动项 | ⚠️ 会重复创建 | 低 |
| `04-seal-base.ps1` | 母盘设只读 + 移出菜单 | ✅ 幂等 | 低 |
| `05-create-work.ps1` | 派生 Work + 链验证 + 加启动项 | ✅ 支持 `-Reset` | 低 |
| `99-rollback.ps1` | 六种回滚场景 | ✅ | 低 |

**中途唯一必须手动的是**：把 Windows 部署进 `Base.vhdx`（`02` 跑完会打印完整命令），以及进入母盘系统跑 `sysprep`。这两步是系统级操作，无法自动化。

---

## 仓库结构

```
.
├── README.md                    ← 你在这里
├── LICENSE                      MIT
├── .gitignore
├── docs/
│   ├── 01-concepts.md           原理：差分盘、BCD、VHDX 内部结构
│   ├── 02-prerequisites.md      硬件/系统/目录/备份要求
│   ├── 03-build-guide.md        五阶段完整流程 + 真实代码
│   ├── 04-pitfalls.md           ⭐ 14 条避坑指南（血泪教训）
│   ├── 05-daily-use.md          日常使用、重置、备份、压缩
│   ├── 06-troubleshooting.md    错误码对照与排错
│   ├── 07-real-environment.md   真实环境数据（GUID、时间线、体积）
│   └── FAQ.md                   常见问题
└── scripts/
    ├── README.md                脚本说明
    ├── build.cmd                一键入口（交互菜单）
    ├── 00-check.ps1
    ├── 01-prepare.ps1
    ├── 02-create-base.ps1
    ├── 03-add-base-entry.ps1
    ├── 04-seal-base.ps1
    ├── 05-create-work.ps1
    ├── 99-rollback.ps1
    └── lib/
        └── Common.ps1           公共函数库
```

---

## 前置条件

| 项 | 要求 | 检查方式 |
|---|---|---|
| 平台 | Windows 11（10 也可，未充分测试） | — |
| 引导 | **UEFI + GPT**，ESP 为 FAT32 | `00-check.ps1` |
| 磁盘 | 数据盘可用空间 ≥ 母盘大小 × 3 | `00-check.ps1` |
| 卷标 | 数据盘卷标为 `Data`（可改参数） | `00-check.ps1` |
| 权限 | 管理员 | `00-check.ps1` |

> **为什么强调 UEFI**：Legacy BIOS + MBR 环境下 VHD 启动支持很差，本工具只在 UEFI 环境验证过。

如果你的数据盘卷标不是 `Data`：

```powershell
.\00-check.ps1 -DataLabel "MyData"
.\01-prepare.ps1 -DataLabel "MyData"     # 后续所有脚本都要加同一个参数
```

---

## 安全设计

这套工具在**会改 BCD 和系统设置**的前提下，做了这些保护：

| 保护 | 实现 |
|---|---|
| 绝不在 Work 里操作 VHD 链 | 每个脚本开头检查 `Test-InVhd`，命中直接退出 |
| 每个阶段前自动备份 BCD | 备份到 `VHD\Logs\`，失败则中止 |
| 只改 BCD，不删数据 | 所有回滚只删启动项，VHD 文件原地保留 |
| 重置不删除旧盘 | `-Reset` 只是改名 `Work.replaced-时间戳.vhdx` |
| 母盘只读强制校验 | `04`/`05` 都检查 `IsReadOnly`，不符合就中止 |
| 链检查实读文件 | 只读挂载子盘，真的去读 `winload.efi` |
| `bcdedit` 静默失败检测 | 设置后回读验证 `device` 含 `vhd=`，失败自动删项 |
| 禁止孙盘 | 父盘是差分盘时直接拒绝 |

**所有改动都记录在** `VHD\state.json` / `entry-base.json` / `entry-work.json`，供回滚使用。

---

## 验证记录

本套工具在真实环境（Lenovo Legion / 2×1TB NVMe / UEFI / Windows 11 26300）验证通过。测试全部在沙盒里做，**没有改动任何真实系统盘或系统 BCD**。

| 测试项 | 方法 | 结果 |
|---|---|---|
| 8 个脚本语法 | PowerShell Parser | ✅ 全部 PARSE-OK |
| `Common.ps1` 函数 | 19 项单元测试 | ✅ 19/19 |
| 建盘 / 分区 / 格式化 | 沙盒 100-300 MB 小盘 | ✅ |
| 只读挂载 + 链检查 | 沙盒 | ✅ |
| 子盘读父盘 + 写隔离 | 沙盒 | ✅ |
| 母盘不被污染 | 沙盒 | ✅ |
| 重置流程（改名+重建+验证） | 沙盒 | ✅ |
| BCD 全流程 | `bcdedit /store` 副本 | ✅ 10/10 |
| 端到端演练 | 沙盒完整流程 | ✅ 14/14 |
| 系统 BCD 未被影响 | 前后比对 | ✅ 确认 |

> **BCD 测试手法**：用 `bcdedit /store <导出的副本>` 操作 BCD 副本，既验证了每个命令的真实行为，又完全不碰系统 BCD。

### 验证过程中发现并修复的 2 个真实缺陷

1. **分区类型陷阱** — VHD 内的系统分区类型是 `IFS` 而非 `Basic`，按 `Basic` 过滤会永远找不到分区，导致链检查必然失败。见 [pitfalls #13](docs/04-pitfalls.md)。
2. **`bcdedit` 静默失败** — 设置不存在的盘符时退出码为 0 但不生效，必须回读验证。见 [pitfalls #14](docs/04-pitfalls.md)。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [01 · 原理](docs/01-concepts.md) | 差分盘 copy-on-write、BCD 定位机制、VHDX 内部结构 |
| [02 · 前置条件](docs/02-prerequisites.md) | 硬件/系统/目录约定/必须的备份 |
| [03 · 构建指南](docs/03-build-guide.md) | 五阶段完整流程，每步的真实代码 |
| **[04 · 避坑指南](docs/04-pitfalls.md)** | **14 条血泪教训，强烈建议先读** |
| [05 · 日常使用](docs/05-daily-use.md) | 重置、备份、压缩、多分支 |
| [06 · 排错](docs/06-troubleshooting.md) | 错误码对照、症状 → 原因 → 处理 |
| [07 · 真实环境](docs/07-real-environment.md) | 实测数据：GUID、时间线、体积 |
| [FAQ](docs/FAQ.md) | 常见疑问 |

---

## 已知限制

| 限制 | 说明 | 缓解 |
|---|---|---|
| 单系统运行 | 同时只能进一个 | 接受 |
| Work 只增不减 | 差分盘特性，删文件不回收块 | 定期 `Optimize-VHD` |
| Base 单点故障 | 母盘损坏 = 所有子盘失效 | **单独备份 `Base.vhdx`** |
| 性能略降 | 差分读多一层查表 | 通常 <5%，感知不到 |
| 不能改父盘文件名 | 子盘按路径+卷 GUID 引用 | 改名后子盘全部失效 |

---

## 贡献

欢迎提 Issue / PR。特别需要：

- 在其他硬件平台（不同厂商 UEFI）上的验证结果
- Windows 10 / Server 版本的适配
- 更优雅的自动化方案（尤其 `02` 的 Windows 部署环节）

---

## License

[MIT](LICENSE)

---

<div align="center">

**如果这套工具帮到了你，点个 ⭐ 让更多人看到**

</div>
