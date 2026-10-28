# 差分双系统原理

> 理解了这几个机制，后面所有操作都会变得理所当然。

## 目录

1. [整体架构](#1-整体架构)
2. [差分盘 = Copy-on-Write](#2-差分盘--copy-on-write)
3. [子盘如何记住父盘](#3-子盘如何记住父盘)
4. [BCD 如何指向 VHD](#4-bcd-如何指向-vhd)
5. [为什么要 sysprep](#5-为什么要-sysprep)
6. [三个铁律](#6-三个铁律)

---

## 1. 整体架构

```
磁盘布局（真实数据）

磁盘 0 (NVMe 954GB)                 磁盘 1 (NVMe 954GB)
├─ part1 System    450MB  FAT32      ← ESP（UEFI 引导）
├─ part2 Reserved   16MB
├─ part3 Basic     951GB  NTFS  D:   ← 物理 Windows（卷标 Windows-SSD）
└─ part4 Recovery  0.87GB
                                     └─ part2 Basic 953GB NTFS E:  ← 数据盘（卷标 Data）
```

**关键点：VHD 全部放在数据盘（`E:`），不碰系统盘分区表。**

```
E:\VHD\
    Base.vhdx     48 GB   只读，母盘
    Work.vhdx     86 GB   差分盘，日常工作系统
```

---

## 2. 差分盘 = Copy-on-Write

### 读的过程

```
读块 A  →  父盘没写过这个块  →  问子盘  →  子盘有  →  读子盘
读块 B  →  父盘有，子盘没写过  →  读父盘
读块 C  →  （第一次写）→ 先复制父盘原块到子盘 → 改写子盘
```

### 写的过程

```
写块 C  →  只写进子盘，父盘永不改变
```

### 由此推出

| 现象 | 原因 |
|---|---|
| `Work.vhdx` 初始只有 4 MB | 只是元数据 + 索引表 |
| 用着用着变大 | 每写一个新块，就多占一块 |
| 删文件后文件不缩小 | 块已分配，不会自动回收 |
| 父盘只读后仍能正常写入 | 写入全发生在子盘 |
| 父盘一旦可写，子盘全部失效 | copy-on-write 前提被破坏 |

---

## 3. 子盘如何记住父盘

这是最容易出问题的地方。实测从 `Work.vhdx` 内部读出来的父盘引用：

```
parent_linkage{793ae55f-6270-4904-b51f-b906ee7e736f}
    absolute_win32_path  : D:\VHD\Base.vhdx
    relative_path        : .\Base.vhdx
    volume_path          : \\?\Volume{79e9bac7-a3ad-4262-a557-d4134770d729}\VHD\Base.vhdx
```

### 三条路径各自的含义

| 路径 | 含义 | 什么时候用 |
|---|---|---|
| `absolute_win32_path` | 绝对路径（含盘符） | 原环境 |
| `relative_path` | 相对子盘的路径 | **父盘与子盘同目录时最优先** |
| `volume_path` | 卷 GUID 路径 | **跨系统、跨盘符时最可靠** |

### 关键结论

**`diskpart` 显示的 `Parent Filename:` 可能是 `\Device\HarddiskVolume6\...` 或 `E:\VHD\Base.vhdx`，这只是它按当前环境解析后的结果，不是文件里存的原始值。**

真正的绑定靠**卷 GUID**，所以：

- ✅ 换盘符没关系（物理系统 `D:` / Work 里 `E:` 都能用）
- ❌ **但文件名和相对位置不能变**
- ❌ 不能把父盘移到别的磁盘

---

## 4. BCD 如何指向 VHD

### BCD 里的写法

```cmd
device    vhd=[E:]\VHD\Work.vhdx,locate=custom:12000002
osdevice  vhd=[E:]\VHD\Work.vhdx,locate=custom:22000002
```

- `vhd=[盘符:]\路径\文件.vhdx` — 指向 VHD 文件
- `locate=custom:...` — Windows 自动加的定位参数，**不要手动删改**

### 完整示例（实测）

```
Windows Boot Loader
-------------------
identifier              {ced6181f-bae1-11f1-94bc-a085277a74a6}
device                  vhd=[E:]\VHD\Work.vhdx,locate=custom:12000002
path                    \Windows\system32\winload.efi
description             Win11-Work
osdevice                vhd=[E:]\VHD\Work.vhdx,locate=custom:22000002
systemroot              \Windows
```

### ⚠️ 重要陷阱

**`bcdedit /set` 设置不存在的盘符时，退出码为 0，但不生效。**

```powershell
# X: 不存在
bcdedit /set {guid} device 'vhd=[X:]\VHD\Base.vhdx'
# 退出码 0，无报错

# 但回读发现没生效：
bcdedit /enum {guid}
#   device    partition=D:      ← 还是模板原值！
```

**所以必须回读验证。** 详见 [04-pitfalls.md](04-pitfalls.md)。

---

## 5. 为什么要 sysprep

差分盘共享同一个：

- Machine SID
- 计算机名
- 驱动缓存
- 用户配置文件

如果不 generalize，从同一母盘派生的每个 Work 都会有**相同的 SID**，在多机/域环境会出问题。

`sysprep /generalize /oobe` 会：

1. 重置 SID
2. 删除用户配置文件
3. 清理硬件相关状态（HAL 检测、即插即用设备）
4. 把系统置为 OOBE（开箱即用）状态

**代价**：所有用户级配置丢失，只能保留系统级的东西。

**建议**：母盘里只装系统级软件（运行时、驱动、开发工具链），不装依赖特定用户配置的东西。

---

## 6. 三个铁律

```
┌──────────────────────────────────────────────┐
│  1. 父盘（Base.vhdx）必须只读               │
│     可写 = 所有子盘数据错乱                │
├──────────────────────────────────────────────┤
│  2. 父盘不能改名 / 移动 / 删除              │
│     子盘按卷 GUID + 文件名引用             │
├──────────────────────────────────────────────┤
│  3. 同一时刻只能挂载一次                    │
│     两个系统同时挂载同一 VHD = 损坏         │
└──────────────────────────────────────────────┘
```

违反任何一条，Work 都无法启动。

**但好消息是**：只要 `Base.vhdx` 完好，Work 坏了随时能重建（几秒钟）。

---

## 下一步

- [环境准备](02-prerequisites.md)
- [详细构建指南](03-build-guide.md)
- **[避坑指南（强烈建议先读）](04-pitfalls.md)**
