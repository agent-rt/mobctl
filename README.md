# mobctl

> **Agent 优先的移动端模拟器 / 真机管理 CLI** —— 把 Android Emulator、iOS Simulator
> 和 Android 真机拉到「可用（ready）」状态，再把稳定句柄交给下游自动化工具。

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d)](https://ziglang.org)
[![status](https://img.shields.io/badge/status-MVP-brightgreen)]()
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 为什么需要 mobctl

移动端自动化很少从「跑测试」开始，而是从「让设备先可用」开始。这件事今天散落在
一堆工具里，而且对 Agent 极不友好：

- 模拟器、真机、诊断、日志、恢复分散在 `simctl` / `adb` / `emulator` / `devicectl` 各自的语义里
- Agent 很难稳定判断「这台设备**到底 ready 了没有**」
- 大量流程只返回人类可读的文本日志，不利于程序消费
- 失败时没有统一的状态、证据和恢复建议

`mobctl` 专注补齐这块空白，只回答五个问题：

```
1. 我有哪些可用的模拟器 / 真机？
2. 目标当前是什么状态？
3. 我如何把它启动 / 连通到可用状态？
4. 我如何确认它真的 ready 了？
5. 我如何把稳定句柄和失败证据交给 Agent？
```

它**不是**完整的移动测试框架、设备农场、应用分发平台或录屏识别工具。

## 核心特性

- **Ready 优先于启动完成** —— `boot` / `connect` 只是手段，`ready` 才是结果，且必须附**判定证据**
- **AgentFirst** —— 所有命令都能输出统一 JSON 信封；文本只是 view 层
- **幂等** —— `ensure` 是主入口，已 ready 的对象绝不重复启动 / 连接
- **平台差异显式化** —— `sim` 与 `device` 分开语义，Android / iOS 的 ready 规则各自表达，原始状态保留在 `raw_state`
- **失败可恢复** —— 错误分类 + `retryable` + 下一步建议；`unauthorized` 这类需人工确认的步骤**显式上报，绝不静默重试**
- **单一静态二进制 / 快启动** —— Zig 0.16，无运行时依赖

## 安装

需要 [Zig 0.16.0](https://ziglang.org/download/)。

```bash
git clone <repo> mobctl && cd mobctl
zig build               # 产物在 zig-out/bin/mobctl
zig build run -- --help # 直接跑
```

把 `zig-out/bin/mobctl` 放进 `PATH` 即可。

**外部工具链**（按需）：iOS 需要 Xcode（`xcrun simctl` / `devicectl`）；
Android 需要 SDK（`$ANDROID_HOME` 下的 `emulator` 与 `platform-tools/adb`）。
先跑 `mobctl doctor` 确认环境。

## 快速开始

```bash
# 0. 体检：iOS / Android 工具链是否就绪
mobctl doctor

# 1. 看看有哪些模拟器
mobctl sim list

# 2. 幂等地确保一台 iOS 模拟器 ready（已 ready 直接复用，否则 boot + 等待）
mobctl sim ensure "iPhone 17 Pro" --json

# 3. 列出物理 Android 真机（自动排除模拟器）
mobctl device list

# 4. 等真机就绪并拿到稳定句柄
mobctl device ensure LF15D56B00015 --json
mobctl device handle LF15D56B00015 --json

# 5. 导出整个环境的机器可读快照
mobctl report --format json
```

真实输出示例（`sim ensure`，从关机状态 boot 到 ready）：

```json
{
  "schema_version": 1,
  "success": true,
  "command": "sim ensure",
  "kind": "sim",
  "platform": "ios",
  "device_id": "8008ED9B-8F7B-468D-A424-E9F31587DB7A",
  "state": "ready",
  "elapsed_ms": 2369,
  "handle": {
    "transport": "simctl",
    "connection_hint": "xcrun simctl 8008ED9B-...",
    "ready_at": "now",
    "runtime": "iOS 26.4",
    "app_container_hint": "booted"
  },
  "diagnostics": ["simctl state=Booted", "spawn /usr/bin/true ok"]
}
```

## 命令参考

每个命令都支持 `--json` 输出统一信封；每个命令也都有专属帮助 —— `mobctl <命令> --help`（如 `mobctl device logs --help`）查看该命令的全部选项、语义与示例。

### `sim` — 模拟器（Android Emulator / iOS Simulator）

| 命令 | 说明 |
|------|------|
| `sim list [--platform android\|ios]` | 列出候选，关联运行中的实例 |
| `sim status <id\|name>` | 查询单个状态 |
| `sim boot <id\|name>` | 启动（已运行则幂等复用） |
| `sim wait-ready <id\|name> [--timeout <s>]` | 轮询至 ready，返回证据 |
| `sim ensure <id\|name> [--timeout <s>]` | **幂等主入口**：已 ready 复用，否则 boot + wait |
| `sim shutdown <id\|name> [--force]` | 关闭 |
| `sim reset <id\|name>` | 显式重置（清数据） |
| `sim handle <id\|name>` | 导出稳定句柄 |
| `sim logs [id\|name] [-f] [--grep S] [--lines N]` | 采集日志（dump / `-f` 实时；文本 / NDJSON）；省略 selector 时若唯一则自动选中 |

### `device` — 真机（Android，iOS 真机为 P1）

| 命令 | 说明 |
|------|------|
| `device list [--platform android]` | 列出物理设备（**排除模拟器**），区分 usb/wifi、trusted |
| `device status <serial\|name>` | 查询单个状态 |
| `device connect <ip[:port]>` | wifi 连接（`adb connect`，默认端口 5555） |
| `device disconnect <serial>` | 断开 wifi 连接 |
| `device wait-ready <serial\|name> [--timeout <s>]` | 轮询至 ready；`unauthorized` 立即显式上报 |
| `device ensure <serial\|name>` | 幂等主入口（真机无 boot，已 ready 即复用） |
| `device handle <serial\|name>` | 导出稳定句柄 |
| `device logs [serial\|name] [-f] [--grep S] [--pid N] [--package P] [--tag T] [--level W] [--color]` | `adb logcat`；dump / `-f` 实时；`--json` 输出**结构化记录**（time/pid/tid/level/tag/message）；TTY 下默认 **pidcat 风格着色对齐**（tag 着色右对齐、level 色块、消息换行），管道/`--no-color` 转纯文本；借鉴 [pidcat](https://github.com/JakeWharton/pidcat)；唯一设备时可省略 selector |

### 共享命令

| 命令 | 说明 |
|------|------|
| `doctor [--json]` | 诊断工具链 / SDK / 依赖，每项 `status: ok\|warn\|fail` + `detail` + `fix` |
| `report [--format json\|ndjson\|md]` | 聚合体检 + 设备清单为一份机器可读报告 |

### 日志调试（`logs`）

`logs` 同时照顾三类受众：

- **人类**（TTY）→ [pidcat](https://github.com/JakeWharton/pidcat) 风格着色对齐（tag 按名着色右对齐、level 色块、消息换行、连续同 tag 留空）
- **脚本**（管道 / `--no-color`）→ 纯 logcat 文本，可直接 `grep`
- **Agent**（`--json`）→ 结构化记录，无需正则即可按字段过滤

过滤选项可任意组合：

| 选项 | 作用 |
|------|------|
| `--grep <子串>` | 只输出含该子串的行（进程内，跨平台） |
| `--pid <pid>` | 只看该进程（Android） |
| `--package <pkg>` | 只看该包的进程（`pidof` 解析，支持多进程） |
| `--tag <tag>` / `--level <V\|D\|I\|W\|E\|F>` | 按 tag / 最低优先级过滤（Android） |
| `-f, --follow` | 实时跟随（`tail -f` 式），Ctrl-C 结束 |
| `--lines <N>` | dump 行数上限（默认 200） |

```bash
mobctl device logs --package com.example.app -f   # 跟随某 app 的日志
mobctl device logs --level E --lines 500          # 最近 500 行里的错误
mobctl device logs --grep ANR --json              # 含 ANR 的行 → 结构化记录
```

`--json` 时每行解析为：

```json
{"time":"06-01 16:06:33.243","pid":2892,"tid":2892,"level":"D","tag":"DeviceStatisticsService","message":"onReceive: ..."}
```

## 统一输出契约

所有结构化返回都用同一个**信封**，这是 AgentFirst 的核心：

```jsonc
{
  "schema_version": 1,        // 格式版本
  "success": true,
  "command": "ensure",        // 对应用户命令
  "kind": "sim",              // sim | device
  "platform": "android",      // android | ios
  "device_id": "Pixel_8_API_35",
  "state": "ready",           // 统一枚举，不漂移
  "raw_state": "device",      // 平台原始态（保留语义）
  "elapsed_ms": 18432,
  "handle": { ... },          // 可直接喂给下游工具
  "warnings": [], "artifacts": [], "diagnostics": []
}
```

失败时带可分类、可判断是否重试的 `error`：

```jsonc
{
  "success": false,
  "error": {
    "kind": "permission_denied",   // 14 类错误之一
    "code": "adb_unauthorized",
    "message": "...",
    "retryable": false,            // 指导 Agent 是否重试
    "fatal": false
  },
  "diagnostics": ["Accept the USB debugging prompt on the device."]
}
```

**句柄（handle）**分两层：必选字段（`transport` / `connection_hint` + 顶层身份）
任何时候都在；平台可选字段（`ready_at` / `runtime` / `connection_type` /
`pairing_state` / `trust_state` / `app_container_hint`）只在该平台真正适用时出现。

**退出码**：`0` 成功 / 体检无 fail；`1` 未知命令或体检有 fail。

## 架构

```
mobctl
├── cli/            # 仅路由 + 参数解析，不含业务逻辑
│   ├── args.zig
│   └── cmd/        # sim · device · doctor · report
├── shared/         # 跨子域复用
│   ├── envelope.zig  # 统一信封 + 状态/句柄类型
│   ├── error.zig     # 三层错误模型（error set / Kind / Info）
│   ├── exec.zig      # 子进程捕获 + 分离启动
│   └── report.zig    # Check / Report
├── sim/            # 模拟器生命周期：discovery · boot · wait_ready · …
└── device/         # 真机生命周期：discovery · connect · wait_ready · …
```

错误模型刻意拆三层，绕开「Zig error 不能携带数据」：`error{}`（控制流）→
`Kind` 枚举（进 JSON 的稳定分类）→ `Info` 结构体（带 message / retryable /
diagnostics，进信封）。

## 平台支持矩阵

| | 发现 | 状态 | 启动/连通 | 就绪 | 幂等 | 句柄 | 日志 | 生命周期 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **Android Emulator** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **iOS Simulator** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Android 真机** | ✅ | ✅ | ✅¹ | ✅ | ✅ | ✅ | ✅ | ✅¹ |
| **iOS 真机** | — | — | — | — | — | — | — | — |

¹ 真机的「连通/释放」即 wifi `connect` / `disconnect`；USB 设备插上即被发现。
iOS 真机（pair / trust / developer mode）为 **P1**，暂不在 MVP 内。

## 开发

```bash
zig build           # 构建
zig build run -- …  # 运行
zig build test      # 单元测试
```

## 设计原则

| 原则 | 含义 |
|------|------|
| AgentFirst | 结构化结果优先于文本 |
| Idempotent | 重复调用不产生额外副作用 |
| Fast path | 已 ready 对象快速复用 |
| Observable | 状态、耗时、证据全可见 |
| Recoverable | 失败给出下一步建议 |
| Platform-aware | Android / iOS 差异显式化 |

## 路线图

- [ ] iOS 真机（pair / trust / developer mode，P1）
- [ ] 设备状态轮询 / 批量操作
- [ ] artifacts 落盘（目前 logs 走 stdout + NDJSON）

## License

MIT
