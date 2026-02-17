# tv-vigil

Android TV 后台应用守夜人 — 自动清理赖在后台的流氓应用，释放内存，让电视不再卡顿。

**无需 Root**，通过 ADB 即可部署，支持重启后自动恢复。

## 工作原理

```
appkiller.sh (运行在电视上)
  ├── 每 60 秒检查一次所有目标应用
  ├── 如果应用在前台 → 不管
  ├── 如果应用在后台超过 3 分钟 → force-stop
  └── 日志 + 统计写入 /data/local/tmp/

watchdog.sh (运行在局域网内的 Mac/Linux 上, 通过 crontab)
  ├── 每 5 分钟检查电视上 appkiller 是否在运行
  └── 没运行就自动推送并启动 → 电视重启后自动恢复
```

## 快速开始

### 前置条件

- 电视开启了 ADB 调试（设置 → 开发者选项 → USB 调试 / 网络调试）
- 一台同局域网的 Mac 或 Linux（用于运行 watchdog 保活）
- 已安装 `adb`（`brew install android-platform-tools` 或 `apt install android-tools-adb`）

### 一键部署

```bash
git clone https://github.com/Caldis/tv-vigil.git
cd tv-vigil

# 编辑 appkiller.sh 顶部的 ROGUE_APPS 列表，填入你要管控的应用包名
# 查看已安装的第三方应用: adb shell pm list packages -3

./setup.sh 192.168.1.100  # 替换为你的电视 IP
```

setup 脚本会自动完成：推送脚本到电视 → 启动 → 可选安装 watchdog 定时任务。

## 配置

编辑 `appkiller.sh` 顶部的 CONFIG 区域：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `THRESHOLD` | `180` | 后台多少秒后杀掉（默认 3 分钟） |
| `CHECK_INTERVAL` | `60` | 巡逻间隔（秒） |
| `ROGUE_APPS` | 见文件 | 要管控的应用包名列表 |

编辑 `watchdog.sh` 顶部的 CONFIG 区域：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ADB` | `/opt/homebrew/bin/adb` | adb 路径（Linux 改为 `/usr/bin/adb`） |
| `TV_IP` | `192.168.1.209` | 电视 IP 地址 |

## 查看状态

### 命令行管理 (vigil.sh)

```bash
# 查看完整状态（连接、守护进程、统计）
./vigil.sh status [TV_IP]

# 查看最近日志（默认 20 行）
./vigil.sh log [行数] [TV_IP]

# 查看击杀统计（含每应用明细）
./vigil.sh stats [TV_IP]

# 启动/重启守护进程（自动推送脚本）
./vigil.sh start [TV_IP]

# 停止守护进程
./vigil.sh stop [TV_IP]
```

### 手动查看（直接 adb）

```bash
# 实时日志（每次巡逻 + 每次杀应用都会记录）
adb shell cat /data/local/tmp/appkiller.log

# 累计统计（总巡逻次数、总击杀数、每应用击杀数）
adb shell cat /data/local/tmp/appkiller_stats

# watchdog 日志（在运行 watchdog 的机器上）
cat watchdog.log
```

日志示例：
```
02-17 19:06:46 cycle #1 fg=com.ktcp.video run=1 bg=0 killed=0
02-17 19:10:51 KILL com.cibn.tv (bg 240s)
02-17 19:10:51 cycle #5 fg=com.google.android.tvlauncher run=2 bg=1 killed=1
```

## 兼容性

- Android 9+ (API 28+)
- 无需 Root
- 已测试：Sony BRAVIA (MT5895)，理论兼容所有 Android TV

## Agent / 自动化接口

`vigil.sh` 支持 `--json` 参数输出结构化 JSON，所有响应使用统一信封格式 `{ok, error, data}`：

```bash
./vigil.sh --json status
./vigil.sh --json stats
./vigil.sh --json log 10
./vigil.sh --json start
./vigil.sh --json stop
```

示例输出 (`--json status`)：

```json
{
  "ok": true,
  "error": null,
  "data": {
    "connected": true,
    "daemon": "running",
    "pid": 1234,
    "uptime_min": 45,
    "total_cycles": 27,
    "total_kills": 3,
    "total_skips": 1,
    "script_installed": true
  }
}
```

### 退出码

| 代码 | 含义 |
|------|------|
| `0` | 成功 |
| `1` | 参数错误 |
| `2` | 无法连接电视（ADB 不可达） |
| `3` | 守护进程未运行 / 无统计数据 |
| `4` | 启动/停止操作失败 |

### 项目清单

`agent.json` 位于仓库根目录，以机器可读格式描述所有命令、参数、退出码和配置结构。

## AI 部署指南

将以下内容发给你的 AI 助手即可完成部署：

> 请帮我部署 tv-vigil 到我的 Android TV。
> 仓库地址：https://github.com/Caldis/tv-vigil
> 电视 IP：[填入你的电视IP]
> 我要管控的应用：[填入包名，或让 AI 通过 adb shell pm list packages -3 自动发现]
> watchdog 运行在：[填入你的 Mac/Linux 机器信息]
>
> 步骤：clone 仓库 → 编辑 appkiller.sh 中的 ROGUE_APPS → 运行 setup.sh → 确认运行正常

## License

MIT
