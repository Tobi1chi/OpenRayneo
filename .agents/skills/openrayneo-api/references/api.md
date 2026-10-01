# API 接口与会话规则

## 约定

所有 `/v1/` 路由都使用 Bearer token。正文是 JSON 对象；无参数 POST 可以不带正文。脚本的 `response` 是下文的接口返回对象。

- `/health` 不鉴权，返回 `ok`、`bleReady`、`rfcommConnected`。
- `GET /v1/device` 返回 `ble` 诊断及 `rfcommConnected`；`POST /v1/device/connect` 连接并返回诊断。
- `202` 只确认请求已写出；字幕启动即使返回 `200`，也要检查 `accepted` 判断是否成功。
- `GET /v1/display/events` 是最近 64 条相关回执及丢弃音频计数，可能含私人文字，不是全局活动会话查询。
- 常见失败：`400` 参数错误，`401` 令牌错误，`403` 权限或所有权限制，`409` 会话冲突，`413` 数据过大，`503`/`504` 连接或传输失败。
- 没有 HTTP 配对、断开、重启服务、导航、视频上传或日程写入接口。导航/字符视频由调用方生成完整文本帧，走字幕接口。动态选路和 GPS 数据源不由 Bridge 提供。

## 通知和提词

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `POST /v1/notifications` | `{"title":"提示","body":"下一步操作"}`，二者均为字符串 |
| `POST /v1/teleprompter` | `{"title":"演讲稿","text":"非空稿件","speed":120}`；标题默认 OpenRayneo，速度默认 120 |
| `POST /v1/teleprompter/pause` | 暂停当前稿件 |
| `POST /v1/teleprompter/resume` | 继续当前稿件 |
| `POST /v1/teleprompter/stop` | 结束当前稿件 |

通知和提词会按需连接。先停止自己开启的字幕、提示或音频会话，再开始提词。提词返回的 `did` 是文档标识，控制接口无需传它。非 ASCII 文本用 UTF-8 JSON 发送；不要自行打包底层蓝牙分片。

## 显示与 TUI

字幕：`POST /v1/captions/start`，正文可为 `{}`，默认 `font_size:2`、`content_width:100`、`max_lines:5`。

```json
{"font_size":1,"content_width":100,"max_lines":7}
```

确认返回 `accepted:true`，并核对 `reply.effective_config`，固件可能钳制请求值。然后调用 `POST /v1/captions/text`：

```json
{"text":"第一行\n第二行","final":true}
```

结束：`POST /v1/captions/stop`。start 超时也可能留下待确认会话，需要 stop。重复 stop 没有匹配会话时会返回 `409`，并非通用幂等接口。

实时提示：使用对应的 `/v1/prompts/start`、`/text`、`/stop`，start 正文为 `{}`。正文示例：

```json
{"text":"固定标题","translation":"正文或回答放在这里","final":true}
```

提示页面会激活眼镜音频上行，即使协议 `save_audio:false`。普通显示路径丢弃音频，仅显式 ASR/录音会解码或保存。纯文本面板优先用字幕，结束提示时发 stop。

### 网格规则

- 已在测试设备验证：字体 1 使用 26×7 全角网格；字体 2 使用 20×5 或 20×6。字号是固件枚举，不是像素值。
- 方块 `█` 与全角空白 `U+3000` 的固定布局可用。半角 ASCII 两种视频模式出现过右边缘不齐；普通空格、NBSP、数字空格不能作为已验证的等宽替代。
- 文本格可把 ASCII `!`–`~` 加 `0xFEE0` 转为全角形式，普通空格换 `U+3000`。混排宽度仍需核对；不要声称所有 Unicode/emoji 都占一格。
- 全角灰度字符调色板使用 Mac 参考字体校准，佩戴者于 2026-10-01 确认在测试眼镜上显示和对齐正常；其他设备/固件可用标尺复核。点阵 Braille 已被佩戴者报告不可用。
- 每帧发送全部行，并显式 `final:true`，否则可能逐字出现。清除旧字符用空白填回相应格子，不发送 ANSI 转义或光标控制码。
- 字体 2 的导航实测：新会话首帧不补位，成功发送后的后续帧在**整幅字符串最前面**补一个 `U+3000`，不是每行都补。重开/停止/服务重启后重置。HTTP 后端不自动做这个 GUI 渲染补偿；字体 1 的视频补偿仍需单独验证。
- 日用 5–10 次更新/秒。顺序等待每次 HTTP 请求，按单调时间挑选最新帧并跳过过期帧，不排队追赶。不把请求发送频率称作屏幕物理刷新率。
- 佩戴者在眼镜上退出后，主机 SID 可能仍在；结束自己记录的会话并重新 start，不无限发送到旧 SID。

## 待办

| 方法与路径 | 正文 / 返回 |
| --- | --- |
| `GET /v1/todos` | 完整待办快照 |
| `POST /v1/todos` | `{"title":"准备材料","important":false}`；返回 `eventID` 和 `readBack` |
| `DELETE /v1/todos/{id}` | 仅能删除当前 Bridge 进程创建的 ID |

底层是完整列表读、合并、同步，不是追加消息。保持官方手机 App 断开，避免并发写。新增超时先 GET 检查是否已存在，不直接重发制造重复。保留原始大整数 ID，避免 JavaScript Number 精度损失。服务重启丢失删除所有权，不可为此强制发送空列表。查看列表需在眼镜上手动打开待办；`readBack:true` 表示服务端已回读，页面显示仍需在眼镜上确认。

## 天气

`GET /v1/dashboard` 返回 `reply` 和可用时的 `config`。城市天气使用 `config.widgets_data.weather.location_ids` 内的既有 ID，不猜测、不改变城市配置。

`POST /v1/weather/current` 更新首页当前位置天气：

```json
{"location":"测试位置","temp":31,"icon":100}
```

`POST /v1/weather/cities` 更新城市卡片：

```json
{"cities":[{
  "location":"测试城市","location_id":"实际配置中的城市ID",
  "temp":12,"icon":100,"des":"测试数据","temp_range":"18°/6°",
  "hourly":[
    {"time":"8am","temp":11,"icon":100},
    {"time":"9am","temp":12,"icon":100},
    {"time":"10am","temp":13,"icon":100}
  ]
}]}
```

每个城市需要非空 `location`、`location_id` 和整数 `temp`、`icon`。`hourly` 是按显示顺序排列的数组，不能换成无序对象或按时间标签字典序排序。100/150 分别在实测中显示晴天/夜间月亮，完整图标表未知。首页和城市卡片可分别更新。

天气来源由调用方负责；模拟数据明确标注测试，不伪装成实时预报。写入返回 `202`、`acknowledged` 和原始 `reply`，不把 `payload.value` 擅自解释成通用成功码。dashboard 没有旧天气数值，无法充当恢复备份；测试值会保留至下次更新。

## 眼镜麦克风、ASR 与 WAV

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `GET /v1/asr` 或 `GET /v1/recording` | 共享音频会话状态、统计、错误；ASR 状态可能含语音正文 |
| `POST /v1/asr/authorize` | 请求系统语音识别权限；可能等待 60 秒，不开始录音 |
| `POST /v1/asr/start` | `{"locale":"zh-CN","duration":120,"record":false}`；10–600 秒 |
| `POST /v1/recording/start` | `{"duration":60}`；默认 300 秒，允许 10–21600 秒 |
| `POST /v1/asr/stop` 或 `POST /v1/recording/stop` | 停止同一个音频会话，重复停止安全 |

需要本机 libopus。ASR 还需 Apple 本地识别语言资源及语音权限（`speechAuthorization:3`），不使用 Mac 麦克风，不回退到云识别。只录 WAV 不需要语音识别权限。

只在用户要求音频功能时 start，给定有限时长。先结束现有显示；音频会话占用提示页，重复 start 或同时手动写提示/提词会冲突。用户只要求 ASR 时默认不保存文件；需要保存时显式 `record:true`，其录音随 ASR 停止。长时录音用 recording-only 接口。

WAV 是单个持续追加的 48 kHz、16-bit 双声道文件，默认在 `~/Music/OpenRayneo/Recordings/`。每秒更新头，停止时结束写入。完成后检查 `running:false`、`recording.finalized:true`、`error:null`，使用返回的 `recording.path`，不要猜文件名。断连或无音频会停止，不能自动续入旧文件。

测试机通道 1（PCM 索引 0）被佩戴者确认是骨传导/自己的声音，通道 2（索引 1）是前向/他人声音；不是所有设备的硬件规格保证。现有 ASR 混合两路；没有独立选择麦克风或说话人分离 API。

## 全天智记诊断（仅按要求使用）

1. `POST /v1/lifelog/observe`，`{"duration":60}`，支持 10–600 秒，默认 300。
2. 用户要求启用时 `POST /v1/lifelog/switch`，`{"enabled":true}`；observe 本身不是打开开关。
3. `GET /v1/lifelog` 读取事件与计数。观察器会自动回应唤醒，并接收、计数和丢弃音频；不是纯被动抓包。
4. 只有需要强制一轮音频请求时调用 `POST /v1/lifelog/record`；此名字不表示保存 WAV。
5. `POST /v1/lifelog/stop` 清理；检查 `observing:false`、`enabledByProbe:false` 和 `error`。若开关关闭未确认，应告知用户核对眼镜状态。

此路径会独占音频/显示控制。它不解码保存全天录音，不导出缓存，不提供 ASR。状态标志常驻只表示功能已开启，是否在录音看事件流。LifeLog 与 Proactive AI 的双通道结论需分别实测。
