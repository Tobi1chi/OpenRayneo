# OpenRayneo

[English](README.md) · [简体中文](README.zh-CN.md)

**从 Mac 向雷鸟 RayNeo iO 眼镜发送通知、提词稿、实时文字和待办。**

OpenRayneo 是一个非官方、实验性的蓝牙 Bridge，提供本机 HTTP API，可供脚本、桌面应用和本地自动化调用。Bridge 直接连接眼镜，无需手机中转、云服务或修改官方 App。

目前复用眼镜已有的通知、提词器、字幕、实时提示和待办界面，不提供任意图形绘制、屏幕镜像或自定义显示布局。

## 本地 Agent Skill

仓库提供可分发的 [OpenRayneo API skill](.agents/skills/openrayneo-api/SKILL.md)，包含连接指引、接口示例、会话规则和本机请求脚本，供其他人的 agent 操作已运行的 Bridge。安装 skill 不会自动安装 Bridge 或配对眼镜。

支持 `.agents/skills/` 的 agent 可从仓库发现它。跨项目使用时，将整个 `.agents/skills/openrayneo-api/` 目录复制到 agent 的 skill 目录；Codex 对应 `${CODEX_HOME:-$HOME/.codex}/skills/`。其他 agent 也可以直接读取 `SKILL.md`，保留同目录下的 `references/` 和 `scripts/` 即可。

在本机配置当前服务的 `OPENRAYNEO_API_URL` 和 `OPENRAYNEO_API_TOKEN`，然后要求：**“使用 $openrayneo-api 检查眼镜连接，并显示我提供的文字。”** 不要公开令牌。调用脚本通过 `uv` 运行，仅使用 Python 标准库，不会自动重试设备写入。

## 已验证功能

以下结果来自一台 RayNeo iO 和运行 macOS 15.6.1 的 Apple Silicon Mac：

| 功能 | 实测结果 |
| --- | --- |
| Mac 蓝牙直连 | BLE 认证和 RFCOMM 26 通道正常 |
| 自定义通知 | 中文标题、正文正常显示 |
| 中文提词稿 | 短稿和 120 行、16,319 字节的长稿正常显示 |
| 播放控制 | 暂停、继续、退出均已目视确认 |
| 实时字幕 | 两行中文正常显示，新文字直接替换，无明显加载 |
| 实时提示 | 中文问题与回答正常显示，连续更新替换上一组 |
| 待办 | 新条目与原有条目同时显示，测试条目删除已回读确认 |
| 天气卡片 | 自定义名称、负温度、描述、温度范围、夜间图标及小时预报顺序均已目视确认 |
| 眼镜麦克风 ASR | Mac 本地识别中文语音，眼镜实时提示页正文持续更新，已目视确认 |
| 本地 WAV 录音 | 连续双声道录音已保存并回放，确认两路音频内容不同 |
| 麦克风通道映射 | 用户实验确认：1 号为骨传导麦，采集自己；2 号为前向麦，采集他人 |
| 全天智记唤醒诊断 | Mac 直连开启、应答唤醒和接收音频；本人及外部人声均触发过唤醒 |
| 较大数据写入 | 按 RFCOMM 协商的 MTU 分段发送 |
| 连接诊断 | 通过 HTTP 查询连接阶段并重试 |

测试时未记录眼镜固件版本。其他固件、其他雷鸟型号、Intel Mac 和更早的 macOS 版本尚未验证。

## 环境要求

- 已开机、已与 Mac 配对的 RayNeo **iO** 眼镜。
- macOS 13 或更高版本：这是软件包的部署目标，实测版本为 15.6.1。
- Xcode Command Line Tools 或 Xcode，Swift 5.10 或更高版本；开发环境实测为 Swift 6.1.2。
- 按 macOS 提示，授予 Bridge 或启动它的应用蓝牙访问权限。

项目使用 Apple 系统框架，没有第三方 Swift 包依赖。可选的眼镜麦克风 ASR 还需要 `libopus` 和系统本地语音识别资源，详见 [ASR 配置](docs/asr.md)。构建和运行均不需要官方 Android APK 或蓝牙抓包文件。

## 快速开始

### 1. 构建

如尚未安装 Apple 开发工具：

```sh
xcode-select --install
```

克隆并构建：

```sh
git clone https://github.com/Tobi1chi/OpenRayneo.git
cd OpenRayneo
sh scripts/build-app.sh
```

脚本生成 `OpenRayneoBridge.app`，其中包含 macOS 要求的蓝牙用途说明。这是本机构建的命令行应用包，不是经过公证的图形安装程序。

### 2. 配对并启动

在 **系统设置 → 蓝牙** 中将眼镜与 Mac 配对，并自行完成系统配对确认。首次连接时让眼镜靠近 Mac；若手机平时连接这副眼镜，建议暂时关闭手机的系统蓝牙。

在第一个终端中启动：

```sh
export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge
```

如系统询问，请允许蓝牙访问。保持该终端运行，按 `Ctrl+C` 停止服务。

默认 API 地址是 `http://127.0.0.1:8765`，启动输出会显示令牌。在第二个终端设置相同令牌，再执行后面的示例：

```sh
export OPENRAYNEO_API_TOKEN='粘贴第一个终端显示的令牌'
```

如果 Mac 配对了多副 iO，请在启动前设置 `RAYNEO_ADDRESS`，指定目标设备的经典蓝牙地址。

### 3. 连接并发送通知

```sh
curl -X POST http://127.0.0.1:8765/v1/device/connect \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"

curl -X POST http://127.0.0.1:8765/v1/notifications \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"来自 Mac 的通知","body":"你的本地应用可以向这里发送文字。"}'
```

通知和提词稿接口也会按需连接，因此可以省略显式的连接请求。

## API

除 `GET /health` 外，所有接口都要求 `Authorization: Bearer <token>`。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `GET` | `/health` | 服务状态和 BLE/RFCOMM 连接标志 |
| `GET` | `/v1/device` | BLE 阶段、扫描数量、最近的 BLE 错误及连接状态 |
| `POST` | `/v1/device/connect` | 建立连接，不发送显示内容 |
| `POST` | `/v1/notifications` | 发送通知，必填字符串 `title` 和 `body` |
| `POST` | `/v1/teleprompter` | 传输并启动提词稿，必填非空字符串 `text` |
| `POST` | `/v1/teleprompter/pause` | 暂停当前稿件 |
| `POST` | `/v1/teleprompter/resume` | 继续当前稿件 |
| `POST` | `/v1/teleprompter/stop` | 退出当前稿件 |
| `POST` | `/v1/captions/start`、`/text`、`/stop` | 启动、更新、退出实时字幕 |
| `POST` | `/v1/prompts/start`、`/text`、`/stop` | 启动、更新、退出实时提示 |
| `GET` | `/v1/todos` | 读取完整任务快照 |
| `POST` | `/v1/todos` | 保留已有记录并新增待办，必填 `title` |
| `DELETE` | `/v1/todos/{id}` | 删除当前 Bridge 进程创建的待办 |
| `GET` | `/v1/display/events` | 最近的显示回执及已丢弃音频包数量 |
| `GET` | `/v1/dashboard` | 读取首页组件配置及天气城市 ID |
| `POST` | `/v1/weather/current` | 修改当前位置天气，必填 `location`、`temp`、`icon` |
| `POST` | `/v1/weather/cities` | 使用非空 `cities` 数组更新城市天气数据 |
| `POST` | `/v1/asr/authorize` | 请求 macOS 语音识别权限 |
| `POST` | `/v1/asr/start`、`/stop` | 启停眼镜麦克风和 Mac 本地语音识别 |
| `GET` | `/v1/asr` | 音频统计、当前识别文字、显示写入结果及错误 |
| `POST` | `/v1/recording/start`、`/stop` | 启停连续双声道 WAV 录音 |
| `GET` | `/v1/recording` | 文件路径、录音时长、文件完成状态和音频统计 |
| `POST` | `/v1/lifelog/observe`、`/switch`、`/record`、`/stop` | 实验性全天智记监听、开关、音频请求及退出 |
| `GET` | `/v1/lifelog` | 唤醒/退出事件及音频、VPU、VAD 计数 |

### 提词器

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"演示稿","text":"你好，雷鸟眼镜。\n这段文字由 Mac 直接发送。","speed":60}'
```

`title` 默认值为 `OpenRayneo`，`speed` 默认值为 `120`。测试使用过 `60` 和 `120`，固件支持的完整范围和单位尚未确定。当前布局采用三秒倒计时。

成功响应包含稿件 ID：

```json
{"ok":true,"sent":"teleprompter","did":"<script-id>"}
```

控制当前 Bridge 进程创建的稿件：

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter/pause \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/resume \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

### 字幕、实时提示与待办

```sh
curl -X POST http://127.0.0.1:8765/v1/captions/start \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/captions/text \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"text":"实时字幕\n由本地应用持续更新。"}'
curl -X POST http://127.0.0.1:8765/v1/captions/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

启动响应中确认 `accepted: true` 后再发送文字。将路径中的 `captions` 换成 `prompts` 即可使用实时提示页面；文字请求可包含作为回答的 `translation` 和 `final: true`。结束后调用对应的 `stop`。实时提示启动会开启眼镜音频上行；只有显式启动 ASR 会话后才处理音频，其他情况下直接丢弃。

新增待办接受 `{"title":"准备讲稿","important":false}`，返回 `eventID` 和 `readBack`。实现采用完整列表读取、合并、同步，写入期间请断开官方手机 App。需要手动打开眼镜的待办菜单查看。删除仅限当前 Bridge 进程创建的条目，重启后不会恢复条目归属。已验证行为和限制详见[显示协议与 API 说明](docs/display-protocol.md)。

实验性天气接口接受调用方提供的数据，不会自行获取预报。修改城市卡片前，可用 `/v1/dashboard` 读取现有城市 ID。响应中的 `acknowledged` 和原始回执不等于目视显示确认。当前位置和城市卡片的格式见[天气协议与示例](docs/schedule-weather-protocol.md)。测试值会保留到后续更新覆盖它们。

### 眼镜麦克风 ASR

实验性 ASR 在 Mac 上解码眼镜音频，调用 Apple 本地语音识别，再将结果显示到眼镜的实时提示页面。不使用 Mac 麦克风，也不上传音频。需要安装 `opus`，通过 `open` 启动应用包以正确归属 macOS 权限，然后调用 ASR 授权和启动接口。[ASR 配置与 API](docs/asr.md) 包含启动命令、时长限制和诊断方法。

### 本地 WAV 录音

调用 `/v1/recording/start` 可以只录音、不识别；也可以在 ASR 启动请求中加入 `"record": true`。音频持续追加到同一个 48 kHz、16-bit 双声道 WAV，每秒更新文件头，停止时完成写入。默认保存到 `~/Music/OpenRayneo/Recordings/`。详见[录音使用、容量限制和声道分析](docs/recording.md)。

### 响应含义

全天智记诊断与实时提示模式下的 ASR/录音独立，当前只统计音频，不保存或识别；观察期间会占用显示/音频控制。实验性接口和唤醒测试结果见[全天智记协议笔记](docs/lifelog-protocol.md)。

- `200`：查询成功、连接接口已打开 RFCOMM，或收到显示启动回执（需检查 `accepted`）。`/health` 中的 `ok: true` 只表示服务运行正常，眼镜连接状态需查看 `bleReady` 和 `rfcommConnected`。
- `202`：显示或控制数据帧已经写出。提词稿启动还会等待文件传输确认，但返回值不等于目视显示或播放状态确认。
- 错误响应为 `{"error":"..."}`。常见状态包括参数错误 `400`、令牌错误 `401`、没有活动稿件 `409`、数据过大 `413`、连接或传输失败 `503`/`504`。

## 配置

启动前通过环境变量配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENRAYNEO_API_TOKEN` | 启动时生成 | API 令牌，会打印到启动输出 |
| `OPENRAYNEO_PORT` | `8765` | 本机 HTTP 端口 |
| `RAYNEO_ADDRESS` | 自动选择唯一配对的 iO | 多设备时指定经典蓝牙地址 |
| `OPENRAYNEO_RECORDINGS_DIR` | `~/Music/OpenRayneo/Recordings/` | 显式请求录音时的 WAV 保存目录 |
| `OPENRAYNEO_OPUS_LIBRARY` | Homebrew 标准路径 | 可选的 ASR Opus 解码动态库路径 |
| `OPENRAYNEO_BLE_TRACE` | 关闭 | 设为 `1`，记录附近广播名称、服务、可连接性和 RSSI |

服务仅监听 `127.0.0.1`，面向本地集成。启动令牌属于访问凭据，分享日志前应移除；BLE 调试日志还可能包含附近设备的名称。

## 常见问题

**无法选择眼镜：**先在 macOS 中配对；如有多副 iO，设置 `RAYNEO_ADDRESS`。

**BLE 扫描超时：**保持眼镜唤醒并靠近 Mac，检查其配对或可发现状态，暂时关闭手机的系统蓝牙。实测仅断开手机 App 有时不足以释放连接，同时也应检查 macOS 的蓝牙权限。

**连接失败后重试：**先查看 `GET /v1/device`，再调用 `POST /v1/device/connect`。BLE 阶段等待 15 秒，超时后会清理扫描及待建立连接；RFCOMM 打开阶段另有 12 秒等待时间。

**从手机切回后 RFCOMM 超时：**如果 macOS 日志出现 `BT_ERROR_INVALID_LINK_KEY`，停止 Bridge，在 Mac 蓝牙设置中忽略眼镜，让眼镜进入配对模式后重新配对。本次实测这样恢复了数据通道，无需在官方手机 App 中解绑账户。

**控制返回 `409`：**先通过当前 Bridge 进程启动稿件。进程重启或执行 `stop` 后，不会恢复原稿件的活动状态。字幕和提示文字要求已接受的会话；启动失败后需先调用对应 `stop` 再重试。

## 当前限制

- 项目处于早期原型阶段，硬件验证范围有限，不是官方 SDK。
- 每个进程管理一副选定的眼镜和一份活动稿件，不同步手机 App 的提词稿库。
- 实测长稿只触发了一次应用层文件块请求；多次请求及更长稿件仍需真机验证。
- 单个协议载荷最多 65,531 字节，封装字段会占用其中一部分空间。超大帧返回 `413`；该限制与 RFCOMM 的 MTU 分段不同。
- 尚未实现账户绑定的 ECDH 认证；固件要求此认证时会明确报错。

## 开发

```sh
swift build
sh scripts/build-app.sh
```

GitHub Actions 在 macOS 上构建应用，蓝牙行为仍需真机测试。[协议笔记](docs/protocol.md) 记录了连接流程、数据格式和验证范围。

欢迎提交 Issue 和 Pull Request。连接问题请附上眼镜型号及固件版本、macOS 版本和脱敏后的 `/v1/device` 响应。不要公开令牌、设备地址、私人通知正文、官方 APK 或原始抓包。

## 许可证与项目关系

源码采用 [Apache License 2.0](LICENSE)。OpenRayneo 是独立项目，与雷鸟没有隶属或背书关系；相关名称和商标属于各自权利人。仓库不分发官方 APK、固件镜像或抓取的用户数据。
