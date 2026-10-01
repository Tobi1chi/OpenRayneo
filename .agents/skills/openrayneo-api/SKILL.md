---
name: openrayneo-api
description: 通过本机 OpenRayneo Bridge HTTP API 操作 RayNeo iO 眼镜，包括连接诊断、通知、字幕/TUI、实时提示、提词、待办、天气、眼镜麦克风录音和本地 ASR。用户要求向眼镜显示内容、录音或编写本地 API 集成时使用；不用于修改固件或操作官方手机云服务。
---

# OpenRayneo 本地眼镜控制

使用已运行的 Bridge 完成用户要求，先检查连接，再执行对应功能。此 skill 不代表额外的设备操作授权；用户已明确要求的操作无需重复确认。不要为显示文字附带开启录音或全天智记。

## 建立调用环境

- 优先复用桌面 App 的 **设备与 API** 页面。点击 **连接并启用 API** 后取得当前地址和令牌；GUI 端口可能不是 8765。服务重启后重新取得两者。
- 将地址和令牌置于执行环境的 `OPENRAYNEO_API_URL`、`OPENRAYNEO_API_TOKEN`。地址示例为 `http://127.0.0.1:8765`，仅为示例。令牌从本地安全配置或用户提供的环境取得，不打印、不提交到 Git、不放进 URL。缺少时请用户在本机配置，避免要求把真实令牌贴进对话。
- 眼镜保持开机。手机占用连接时关闭手机系统蓝牙。不要另起第二个 Bridge 争用同一副眼镜，不要终止占用端口的无关进程。
- 尚未运行服务或尚未配对时，按 [连接与恢复](references/connection.md) 操作。配对不是 HTTP API；已配对设备不要重新配对。

在仓库根目录调用随附脚本；如果 skill 被复制到别处，使用其实际脚本绝对路径。Python 通过 `uv run python` 运行，无第三方运行时依赖。

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /health
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /v1/device
```

脚本仅访问显式配置的本机地址，不经过代理、不跟随重定向、不自动重试。输出 `http_status` 和 `response`，HTTP 错误退出码为 1，本地调用错误为 2。`/health` 不需要令牌，其余接口需要 Bearer token。输出可能包含私人任务或语音内容，应按需读取并在分享前脱敏。

`/health` 的 `ok: true` 只证明服务运行。`bleReady: true` 与 `rfcommConnected: true` 才表示两个连接阶段就绪。未连接时可调用一次 `POST /v1/device/connect`，再检查状态。若失败，读取诊断并按连接参考处理，不循环重试。

## 选择操作

按需读取 [API 接口与会话规则](references/api.md)，不要凭官方 APK 的内部消息名猜 HTTP 路由。

| 用户意图 | 使用路径 |
| --- | --- |
| 短通知 | `/v1/notifications` |
| 自定义文字、TUI、导航画面、字符动画 | `/v1/captions/start` → `/text` → `/stop` |
| 标题和回答两段文字 | `/v1/prompts/start` → `/text` → `/stop` |
| 长稿与滚动控制 | `/v1/teleprompter`，以及 `/pause`、`/resume`、`/stop` |
| 待办、天气 | `/v1/todos`、`/v1/dashboard`、`/v1/weather/*` |
| 保存眼镜声音 | `/v1/recording/*` |
| 眼镜声音转文字并显示 | `/v1/asr/*` |
| 全天智记协议实验 | `/v1/lifelog/*`；仅诊断，不提供全天 WAV 或缓存导出 |

一个通知例子（只在用户要求发送时执行）：

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py POST /v1/notifications --body - <<'JSON'
{"title":"OpenRayneo","body":"本机发送的测试通知"}
JSON
```

也可以 `--body /absolute/path/payload.json`。使用 JSON 序列化或带引号的 heredoc 保留中文、换行和特殊字符，不将正文插入可执行 shell 字符串。

## 会话与验证

- 一个 agent 顺序拥有一套显示/音频操作；不要与 GUI 播放器或其他 agent 同时写。GUI 不会同步外部 API 发起的会话。切换前结束自己启动的对应会话；遇到来源不明的 `409`，先确认当前活动，不盲目发送所有 stop。
- 保存自己启动的类型和 SID。字幕/提示 start 必须返回 `accepted: true` 才发送正文；启动超时也可能保留会话，先用匹配的 stop 清理。
- TUI 使用 `final: true` 整帧替换；网格、空白和首行补偿见 [显示规则](references/api.md#显示与-tui)。不要把半角 ASCII 字符数当作屏幕宽度。
- `200`/`202`、`sent`、`acknowledged`、`readBack` 与“佩戴者看到画面”是不同证据。报告 API 已发送或已回读，不虚报真机显示成功。
- 超时不证明写入失败。待办新增等非幂等操作先读回再决定是否重发；脚本不代替这个判断。
- 有限实验完成后停止自己开启的会话。用户要求保持显示时保留并交代结束方式。录音结束必须核对 `running: false`、`recording.finalized: true`、`error: null`，然后提供本地文件路径。

## 使用与维护

本目录是完整的 skill 包，可留在仓库的 `.agents/skills/` 中供支持仓库 skill 的 agent 发现，或整体复制到本地 agent 的 skill 目录。可显式要求“使用 `$openrayneo-api`”。其他 agent 也可直接读取本文件。

接口说明按本仓库实现核对。更新时查看 `Sources/OpenRayneoBridge/main.swift`、`DisplayController.swift`、`SpeechController.swift` 的路由，以及 `docs/` 中对应功能文档。脚本不负责配对、启动服务或解释设备回执。
