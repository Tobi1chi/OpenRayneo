---
name: openrayneo-api
description: 通过本机 OpenRayneo Bridge HTTP API 操作 RayNeo iO 眼镜，读取语音 Agent 事件与手机同步记录，关联回写分析、标签和笔记。用于眼镜显示、通知、提词、待办、天气、麦克风录音、本地 ASR、虚拟麦克风转送及本机 Agent 集成；不用于修改固件或操作官方手机云服务。
---

# OpenRayneo 本地眼镜控制

使用已运行的 Bridge 完成用户要求。设备操作先检查连接；查询记录或同步副本可使用无眼镜的本机服务。操作授权以用户要求为准；用户已明确要求的操作无需重复确认。不要为显示文字附带开启录音或全天智记。

## 建立调用环境

- 优先复用桌面 App 的 **Agent 工作台** 或 **设备连接** 页面。点击 **连接并启用 API** 后取得当前地址和令牌；GUI 端口可能不是 8765。服务重启后重新取得两者。
- 只需记录查询／同步时，在工作台选择 **仅启动记录与 Agent 服务**；命令行对应 `openrayneo-bridge --headless --local-services-only`。此模式不初始化蓝牙，仍只监听 loopback 并要求 Bearer。`GET /v1/device` 返回 `mode:local-services-only`，设备操作需另行连接眼镜。
- 将地址和令牌置于执行环境的 `OPENRAYNEO_API_URL`、`OPENRAYNEO_API_TOKEN`。地址示例为 `http://127.0.0.1:8765`，仅为示例。令牌从本地安全配置或用户提供的环境取得，不打印、不提交到 Git、不放进 URL。缺少时请用户在本机配置，避免要求把真实令牌贴进对话。
- 操作眼镜时保持眼镜开机；手机占用设备连接时先释放该连接。单纯同步或读取手机记录无需断开手机蓝牙。不要另起第二个 Bridge 争用同一副眼镜，不要终止占用端口的无关进程。
- 尚未运行服务或尚未配对时，按 [连接与恢复](references/connection.md) 操作。配对不是 HTTP API；已配对设备不要重新配对。

在仓库根目录调用随附脚本；如果 skill 被复制到别处，使用其实际脚本绝对路径。Python 通过 `uv run python` 运行，无第三方运行时依赖。

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /health
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /v1/device
```

脚本仅访问显式配置的本机地址，不经过代理、不跟随重定向、不自动重试。输出 `http_status` 和 `response`，HTTP 错误退出码为 1，本地调用错误为 2。`/health` 不需要令牌，其余接口需要 Bearer token。输出可能包含私人任务或语音内容，应按需读取并在分享前脱敏。

设备操作要求 `/health` 的 `bleReady: true` 与 `rfcommConnected: true`；`ok:true` 表示服务运行。设备模式未连接时可调用一次 `POST /v1/device/connect`，再检查状态。若失败，读取诊断并按连接参考处理，不循环重试。本机记录服务无需连接眼镜。

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
| 用眼镜作为 Codex 或其他应用的麦克风 | `/v1/prompts/start` 传 `microphone_enabled:true` 才转送 Channel 1/2，`/v1/prompts/text` 同时更新回答，`/v1/prompts/stop` 结束；设备与状态使用 `/v1/virtual-mic/devices`、`/v1/virtual-mic`，需安装 App 自带驱动 |
| 全天智记音频实验 | `/v1/lifelog/*`；有限观察、分帧检查或按要求保存单声道 WAV，不提供全天 WAV 或缓存导出 |
| 外部 Agent 接收语音并回复 | `/v1/agent/events` 读取最终整句和 `replyTarget`；原生事件／PCM 用 `/v1/assistant/native*`，按当前 wakeID 或 SID 回写；见 [语音 Agent](references/api.md#外部-agent-语音事件) |
| 手机记录检索、关联分析／标签／笔记 | `/v1/records/query`、`/v1/records/derived`；连接配置与音频按需获取见 [记录副本](references/api.md#手机记录副本与派生回写) |

一个通知例子（只在用户要求发送时执行）：

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py POST /v1/notifications --body - <<'JSON'
{"title":"OpenRayneo","body":"本机发送的测试通知"}
JSON
```

也可以 `--body /absolute/path/payload.json`。使用 JSON 序列化或带引号的 heredoc 保留中文、换行和特殊字符，不将正文插入可执行 shell 字符串。

## 会话与验证

- 默认语音完整性、等待／提示／任务选择及通用回复由外部本机 Agent 负责，应用提供基础 ASR 和官方输入输出。助手页的“模型实验模式”需显式开启，接入 Agent 时保留默认模式。事件读取与回写目标规则见 [语音 Agent](references/api.md#外部-agent-语音事件)。
- 眼镜双路默认通道1归属稳定本人，通道2独立全量说话人分析；“小雷小雷”原生唤醒轮按用户策略默认本人（`native_wake_self`，不跑声纹）；全天智记等真实混合单声道全量处理。身份依据看 `identityBasis`，不单看 `sourceChannel`；显式 `pcm_layout:"stereo"` 保留双路，旧单声道API保持兼容，见同节的格式与时间规则。
- 一个 agent 顺序拥有一套显示/音频操作；不要与 GUI 播放器或其他 agent 同时写。GUI 会读取字幕／实时提示会话状态，显示外部 API 当前占用。切换前结束自己启动的对应会话；遇到来源不明的 `409`，先确认当前活动，不盲目发送所有 stop。
- 保存自己启动的类型和 SID。字幕/提示 start 必须返回 `accepted: true` 才发送正文；启动超时也可能保留会话，先用匹配的 stop 清理。
- 清屏使用 `POST /v1/captions/clear` 或 `/v1/prompts/clear`，传当前 `sid`。它保留会话和音频；`/text` 的 `clear_after_ms` 可在 1–600000 毫秒后清屏，后续新内容或会话变化会取消旧定时器。`final` 结束片段，与清屏分开。
- TUI 使用 `final: true` 整帧替换；网格、空白和首行补偿见 [显示规则](references/api.md#显示与-tui)。不要把半角 ASCII 字符数当作屏幕宽度。
- `200`/`202`、`sent`、`acknowledged`、`readBack` 与“佩戴者看到画面”是不同证据。报告 API 已发送或已回读，不虚报真机显示成功。
- 超时不证明写入失败。待办新增等非幂等操作先读回再决定是否重发；脚本不代替这个判断。
- 有限实验完成后停止自己开启的会话。用户要求保持显示时保留并交代结束方式。录音结束必须核对 `running: false`、`recording.finalized: true`、`error: null`，然后提供本地文件路径。

## 使用与维护

本目录是完整的 skill 包，可留在仓库的 `.agents/skills/` 中供支持仓库 skill 的 agent 发现，或整体复制到本地 agent 的 skill 目录。可显式要求“使用 `$openrayneo-api`”。其他 agent 也可直接读取本文件。

接口以本技能的 [API参考](references/api.md) 和实际路由为准。仓库架构与当前状态集中在 `.arch/`，操作说明为 `docs/runbook.md`，设备协议为 `docs/protocol.md`。打包技能仍独立携带本目录的参考与脚本；脚本不负责配对、启动服务或解释设备回执。
