# UAC 静默提权工具

## 一句话说明

**双击 .ps1 → 拖入 exe → 点创建 → 桌面多一个快捷方式，启动不弹 UAC。**

---

## 原理

### 为什么会有 UAC 弹窗？

某些程序在快捷方式或清单文件中设置了 `requireAdministrator`，Windows 每次启动时都会弹出"是否允许此应用对你的设备进行更改"。

### 怎么绕过？

**利用 Windows 原生的任务计划程序（Task Scheduler）：**

1. 创建一个计划任务，配置"以最高权限运行"，指向目标程序
2. 创建一个快捷方式，目标不是直接启动 exe，而是调用 `schtasks /run /tn "任务名"`
3. 用户双击快捷方式 → `schtasks` 触发计划任务 → 任务以管理员权限静默启动目标程序

**为什么这样就不弹窗？** 因为 `schtasks` 本身不需要管理员权限来触发一个已存在的任务。任务的提权发生在系统层面，不经过 UAC 弹窗流程。

### 安全性

| 项目 | 说明 |
|------|------|
| 全局 UAC | 不受影响，仍然开启 |
| EnableLUA 注册表 | 不修改 |
| 其他程序 | 不受任何影响 |
| 仅白名单生效 | 只有你主动创建了任务的程序才会静默提权 |
| 系统攻击面 | 未扩大，计划任务是 Windows 原生功能 |

---

## 使用方法

### 方法一：GUI（推荐）

1. 右键 `UACSilentLauncher.ps1` → **使用 PowerShell 运行**
2. 拖动目标 .exe 文件到文本框，或点击"浏览"
3. 确认快捷方式名称
4. 点击"创建静默启动快捷方式"
5. 桌面出现新快捷方式，双击即可无 UAC 启动

### 方法二：命令行

```powershell
# 创建静默启动
.\UACSilentLauncher.ps1 -TargetPath "C:\Program Files\App\App.exe"

# 自定义快捷方式名
.\UACSilentLauncher.ps1 -TargetPath "C:\App\App.exe" -ShortcutName "我的应用(静默)"

# 列出所有静默任务
.\UACSilentLauncher.ps1 -List

# 删除指定静默任务
.\UACSilentLauncher.ps1 -Remove -RemoveTaskName "UACSilent_App"
```

### 固定到任务栏

创建快捷方式后，右键桌面上的新快捷方式 → **显示更多选项** → **固定到任务栏**。

---

## 系统要求

- Windows 10 / 11（Windows 7/8 未测试但理论上支持）
- PowerShell 5.1+（Windows 自带，无需安装）
- 首次创建任务时需要管理员权限（脚本会自动请求提升）

---

## 项目结构

```
UAC-SilentLauncher/
├── UACSilentLauncher.ps1   # 主脚本（GUI + CLI）
├── README.md               # 本文件
└── LICENSE                 # MIT
```

---

## 常见问题

**Q: 需要每次都运行这个脚本吗？**
A: 不需要。创建一次即可，以后直接点击桌面快捷方式启动。

**Q: 会影响软件更新吗？**
A: 不会。计划任务指向的是 exe 路径，软件更新后 exe 在原地不变，一切正常。

**Q: 会被杀毒软件拦截吗？**
A: 使用 Windows 原生 schtasks，不涉及第三方程序，一般不触发杀软。

**Q: 为什么不直接关 UAC？**
A: 关闭全局 UAC 会降低整台电脑的安全性。本方案只对白名单程序生效。

**Q: 对带反作弊的游戏（如 ACE）安全吗？**
A: 计划任务方式启动的程序与正常启动的运行环境相同，路径和进程名不变，一般不影响反作弊。但有个别反作弊系统可能检测父进程链（由 svchost→schtasks→你的程序），如遇问题请自行测试。

---

## 技术细节

### 计划任务配置

| 属性 | 值 |
|------|-----|
| 触发方式 | ONCE（仅手动触发） |
| 运行级别 | HIGHEST |
| 用户身份 | 当前用户 |
| 启动方式 | 允许按需运行 |

### 快捷方式配置

| 属性 | 值 |
|------|-----|
| 目标 | `schtasks.exe` |
| 参数 | `/run /tn "UACSilent_xxx"` |
| 图标 | 自动提取原 exe 图标 |
| 运行方式 | 最小化（避免闪黑窗） |

---

## 许可

MIT License — 随便用，随便改，随便分发。
