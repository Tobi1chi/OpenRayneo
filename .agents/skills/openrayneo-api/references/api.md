# API 接口与会话规则

## 约定

所有 `/v1/` 路由都使用 Bearer token。正文是 JSON 对象；无参数 POST 可以不带正文。脚本的 `response` 是下文的接口返回对象。

- `/health` 不鉴权，返回 `ok`、`bleReady`、`rfcommConnected`。
- `GET /v1/device` 返回 `ble` 诊断及 `rfcommConnected`；`POST /v1/device/connect` 连接并返回诊断。
- `POST /v1/device/pairing/prepare` 仅供桌面新建／重配流程：BLE 应用注册后释放 LE；不创建系统配对、不连接 RFCOMM、不启动收音。普通连接使用 connect，不调用此准备步骤。
- `GET /v1/device/synchronization` 读取当前连接代次的业务同步结果；`POST /v1/device/synchronize` 重新查询。顶层 `ready`／`partial` 与各模块的 `sent`／`read_back` 分开，断线后缓存标记 `stale`。
- `POST /v1/device/recover-data-channel` 仅中断当前 SPP 数据通道并验证自动恢复，保留 BLE 和配对；这是诊断操作。`POST /v1/device/recovery/suspend` 暂停后台恢复，显式 connect 可重新启用。
- `202` 通常只确认请求已写出或异步任务已启动；字幕启动即使返回 `200`，也要检查 `accepted` 判断是否成功。原生录音、文件传输、OTA 应继续查询各自状态，不能把已发送当作已完成。
- `GET /v1/display/events` 是最近 64 条相关回执及丢弃音频计数，可能含私人文字，不是全局活动会话查询。
- 常见失败：`400` 参数错误，`401` 令牌错误，`403` 权限或所有权限制，`409` 会话冲突，`413` 数据过大，`503`/`504` 连接或传输失败。
- 没有 HTTP 配对、断开、重启服务、原生导航或视频上传接口；导航/字符视频由调用方生成文本帧，走字幕接口。Mac 的当前位置天气使用系统定位，但没有通用 GPS 或路线 API。恢复出厂现有独立破坏性接口（见维护节），官方账号解绑仍无 HTTP 接口。

## 外部 Agent 语音事件

默认助手会话采集、ASR 并交付整句；完整性、等待／提示／任务分支与通用回复由本机 Agent 处理。助手页保留显式“模型实验模式”。HTTP 事件接口读取已发布的输入，不会自行启动采集或 ASR；GUI 助手会话启用基础 ASR 后发布最终整句，纯 API 工作流也可自行消费原生事件／PCM。

默认眼镜双路输入分别处理：通道1仅VAD＋ASR并归属稳定本人，不运行声纹或diarization；通道2独立完成VAD、说话人分段、声纹与ASR。真实单声道、原生助手和全天智记混合单声道全量说话人处理。事件附带 `sourceChannel`、`identityBasis`、`personId`、`beginMS/endMS` 和可用的 `speakerTurns`；身份依据为 `channel1_default_self/voiceprint/unknown/mixed/manual`，不能仅凭 sourceChannel=1 推断本人。时间粗粒度的 ASR 句子保留其实际相交的说话人区间，不猜词级切分；同一声音出现在两路时保留两份来源，不做猜测式文字去重。

`POST /v1/assistant-audio/start` 的 `pcm_layout:"stereo"` 显式返回交错双路 PCM，`sample_rate` 可为16000/48000；此模式忽略单路 `channel` 选择，保留真实两路。省略 pcm_layout 或设 mono 时，沿用旧 `channel:0` 混音、1/2选道的单声道接口。`POST /v1/assistant-audio/events` 用 `{"after":0}` 获取单消费者确认流，begin/pcm/end 事件带 `channels/sampleRate/format:pcm_s16le_interleaved`，PCM以Base64返回；帧数为字节数÷channels÷2，两路共用帧时钟。Opus包的mono/stereo编码标志只用于诊断，不作为物理通道或本人身份依据；合法mono-coded包在立体声会话中保留其decoder的两路输出，不因两路声音相同而删除。

`GET /v1/agent/events` 接收 `{"after":0}`，返回 `epoch`、`cursor`、`oldestCursor`、`overflow`、`events`。每条事件包含 `sequence`、`kind`、`text`、`sessionID`、`roundID`、`sentenceID`、`receivedAt`（Unix 毫秒）、`source`，有效眼镜采集可带 `replyTarget`。成功处理后用最后已处理 sequence 继续；发现 epoch 变化时从 after=0 读取。最近保留 512 条，`overflow:true` 说明消费者落后，应识别缺口并使用已有日志或记录补查。

原始 HTTP 支持 `?after=...`，随附 `request.py` 仅允许无 query 的路径，使用 GET JSON 正文：

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /v1/agent/events --body - <<'JSON'
{"after":0}
JSON
```

回写只使用事件所属的当前官方通道：

- `replyTarget.path:/v1/assistant/native/reply`：传该目标的 `wakeID`、非空 `text` 和可选 `query`。新 wake/next_round 后旧 wakeID 失效；`409` 时重新读取状态，不把旧回复送到新一轮。
- `replyTarget.path:/v1/prompts/text`：传目标 `sid`，正文如 `{"sid":"事件给定 SID","text":"提示","translation":"Agent 回答","final":true,"clear_after_ms":10000}`。保留原会话，旧 SID 或停止中的会话返回 `409`。
- 手动输入、音频导入或全天实验事件可能没有 replyTarget；根据用户要求选择现有通知／显示工具，不推断新的会话标识。`replyTarget` 表示输入来源，回写时仍以服务端当前会话检查为准。

原生唤醒/退出/下一轮状态继续使用 `/v1/assistant/native`；PCM 见[原生助手唤醒](#原生助手唤醒beta-验证中)。PCM 是单消费者确认流；若 GUI 正在消费同一流进行 ASR，Agent 读取最终整句，不同时争用 PCM 游标。

## 手机记录副本与派生回写

本组路由使用 Mac loopback API 与本机 Bearer，可在无眼镜的 `--headless --local-services-only` 模式运行。GUI 工作台也提供“仅启动记录与 Agent 服务”。先复用已有服务，不另起实例争用已有端口。

| 方法与路径 | 请求／含义 |
| --- | --- |
| `GET /v1/records` 或 `POST /v1/records/query` | 可选 `from/to`（Unix 毫秒）、`recordId`、`text`，返回完整记录数组及 sync 状态；按 `[createdAt,endedAt)` 与查询半开区间交集筛选，活跃记录延续至当前时间 |
| `GET /v1/records/people` | 同步的人物档案快照，不含声纹向量 |
| `POST /v1/records/derived` | `recordId/sourceRevision/kind`，可带 `id/revision/text/tags/agent`；新增 UUID、省略版本时从已知版本递增；返回派生项与 queued |
| `POST /v1/records/audio` | `{"recordId":"已有记录 UUID"}`，显式获取 WAV 并返回 `audioPath` 和 cached；重复请求复用缓存 |
| `GET /v1/records/sync` | peer、启用状态、游标、副本数、待回写数和错误，不返回 token |
| `PATCH /v1/records/sync` | `{"peerURL":"http://phone:8767","token":"手机专用同步凭据","enabled":true}`；更换地址时显式 `resetCursor:true` 从头补齐，已有副本保留 |
| `POST /v1/records/sync` | 排队立即尝试同步，返回当前状态；后续读取 GET 状态确认 |

脚本查询采用 POST JSON，或 GET JSON 正文；原始 HTTP 也支持 `/v1/records` 的 query 参数。记录保留 `id/revision/source/mode/createdAt/endedAt/title/segments/summary/summaryStale/memories/derived` 等字段；`sourceRevision` 必须使用这次分析依据的记录 `revision`。

```json
{"recordId":"源记录 UUID","sourceRevision":7,"kind":"analysis","text":"本机 Agent 分析","tags":["工作"],"agent":"local-agent"}
```

`kind` 为 `analysis/note/tags`。编辑时保留派生 `id`；省略 revision 自动取最大已知版本加一，显式旧版本不会覆盖新内容。`queued:true` 表示已在 Mac 持久保存并等待手机确认；离线仍可读取副本和新增派生项，重连自动补齐。原记录/人物由手机维护，Mac Agent 通过关联派生项补充；源版本变化会标记旧结果 `stale:true`，刷新分析时提交新 sourceRevision。

手机独立同步端口默认 8767，仅提供记录交换和音频；其专用 token 与 Mac 本机 API token 分开。配置一次可达 peer 后每 15 秒自动尝试，无需云中转；默认同步时间、转写、总结、来源与人物关联，原音频按需获取。修改手机地址和凭据应通过用户提供的安全本地配置完成，不打印真实 token。

新记录可带 `audioChannels`、`channelPolicy` 与分段 `sourceChannel/identityBasis`；手机旧记录或mono的sourceChannel=1仍需看身份依据。按需WAV使用实际单/双声道header，Mac原样缓存和播放，不强制转mono；分段时间定位使用同源帧游标，与交错样本数量分开。

## 通知和提词

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `POST /v1/notifications` | `{"title":"提示","body":"下一步操作"}`，二者均为字符串；可选 `notificationUID/appId/appName/subtitle/timestamp`（字符串）、`category`（整数）；`reply` 固定 false，没有任意应用图标字段 |
| `POST /v1/teleprompter` | `{"title":"演讲稿","text":"非空稿件","speed":120}`；可传 `did`、`settings`；标题默认 OpenRayneo，速度默认 120 |
| `GET /v1/teleprompter` | 本地播放／预览／跟读状态，包含 UTF-8 阅读位置、settings 和最近 controlEvents；不是整份持久稿件库查询 |
| `POST /v1/teleprompter/check-state` | 查询眼镜并恢复本地播放状态；非空正文校验值须与本地稿件一致。不会启动新显示或重新传稿 |
| `POST /v1/teleprompter/settings` | 当前稿件配置：`countdown/scroll/speed/gear/depth/size/width/leading`；`scroll:1` 为本地智能跟读，2 为自动滚动 |
| `POST /v1/teleprompter/progress` | `{"pageOffset":0,"highLightOffset":0}`，偏移按 UTF-8 字节 |
| `POST /v1/teleprompter/library` | `items` 数组及可选 `type/total`，同步稿件列表；不会创建 Mac 本地稿件文件 |
| `POST /v1/teleprompter/pause` | 暂停当前稿件 |
| `POST /v1/teleprompter/resume` | 继续当前稿件 |
| `POST /v1/teleprompter/stop` | 结束当前稿件 |

通知和提词会按需连接。先停止自己开启的字幕、提示或音频会话，再开始提词。提词返回的 `did` 是文档标识，控制接口无需传它。Mac 提词器提供本地稿件库、TXT/PDF/DOC/DOCX 导入、编辑、置顶及同步；智能跟读用眼镜音频与 Apple 本地识别，需要本机语音权限和语言资源，不能把 `202` 当作跟读对齐实测通过。非 ASCII 文本用 UTF-8 JSON 发送；不要自行打包底层蓝牙分片。

## 显示与 TUI

字幕：`POST /v1/captions/start`，正文可为 `{}`，默认 `font_size:2`、`content_width:100`、`max_lines:5`。

```json
{"font_size":1,"content_width":100,"max_lines":7}
```

确认返回 `accepted:true`，并核对 `reply.effective_config`，固件可能钳制请求值。然后调用 `POST /v1/captions/text`：

```json
{"text":"第一行\n第二行","final":true}
```

清屏：`POST /v1/captions/clear`，正文 `{"sid":"本次 start 返回的 SID"}`。它用完整空白帧替换文字，保留会话。`/text` 可传 `clear_after_ms:10000`，发送 10 秒后清屏；0 关闭定时，新内容、停止和断线会取消旧定时。`final:true` 是片段终态，与清屏分开。`GET /v1/caption-settings` 返回 `clearAt` 和最近动作结果。

结束：`POST /v1/captions/stop`。start 超时也可能留下待确认会话，需要 stop。重复 stop 没有匹配会话时会返回 `409`，并非通用幂等接口。

实时提示：使用对应的 `/v1/prompts/start`、`/text`、`/clear`、`/stop`。start 正文 `{}` 默认仅显示文字；传 `{"microphone_enabled":true}` 开启两路内置麦克风转送，需已安装驱动；`duration` 默认 3600、允许 10–21600 秒。返回 `accepted:true`、共享 SID 和音频状态。只显示文字时用 `{"microphone_enabled":false}`。更新正文沿用同一会话，不中断音频；stop 同时关闭页面和两路输出。AI 实时收音由 `/v1/assistant-audio/start` 启动时也允许 `/v1/prompts/text`，但须传该次返回的 `sid`；旧/缺 SID 或停止中返回 409，不得为更新回答另起会话。正文示例：

```json
{"text":"固定标题","translation":"正文或回答放在这里","final":true}
```

提示页面会激活眼镜音频上行，即使协议 `save_audio:false`。显式开启的麦克风模式解码并转送两路声音，不录音、不识别；仅 `microphone_enabled:false` 的文字会话丢弃音频。纯文本面板优先用字幕，结束提示时发 stop。

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
| `GET /v1/todos/local` | 本地缓存及归属，不向眼镜发起查询；包含眼镜主动回传的完成状态 |
| `POST /v1/todos` | `{"title":"准备材料","important":false}`；返回 `eventID` 和 `readBack` |
| `PATCH /v1/todos/{id}` | 修改本应用拥有项目的 `title` / `important` / `completed`（布尔；true 完成、false 撤销）；归属按眼镜和创建时间持久保存 |
| `DELETE /v1/todos/{id}` | 删除本应用拥有的项目，归属可跨 Bridge 重启恢复 |

新增和修改使用 type2 增量消息，删除使用 type7；查询与批次由共享串行同步器处理。保持官方手机 App 断开，避免并发写。新增超时先 GET 检查是否已存在，不直接重发制造重复。保留原始大整数 ID，避免 JavaScript Number 精度损失。归属记录持久保存；无法确认所有权时不可强制写入。眼镜 pending 查询不包含已完成项目；本地保留完成意图，只有收到对应回传才标记 `confirmed_by_glasses`。眼镜主动完成／撤销会更新本地缓存。查看列表需在眼镜上手动打开待办；`readBack:true` 表示服务端已回读，页面显示仍需在眼镜上确认。

## 日程

| 方法与路径 | 正文 / 返回 |
| --- | --- |
| `GET /v1/schedules` | `items` 完整快照 |
| `POST /v1/schedules` | `{"title":"讨论","startTime":1793844000,"endTime":1793845800}`，时间为 Unix 秒；可选 `localTimeOffset`（秒） |
| `PATCH /v1/schedules/{id}` | 修改 `title/startTime/endTime/localTimeOffset`，保留目标 ID |
| `DELETE /v1/schedules/{id}` | 删除选定日程 |
| `POST /v1/schedules/import` | `items` 及 `replaceEventIDs`（十进制字符串数组），完整读取后合并同步 |

写入通过完整列表读取、合并、发送、回读，返回 `eventID` 字符串与 `items`。与待办不同，当前日程接口没有本应用所有权限制；操作前确认目标，避免与官方 App 并发同步。Mac 提供手动日程管理和系统日历导入。官方创建／编辑／删除协议样本已经采集，Mac 写路径已实现；不据此宣称所有写操作均已实机验收。

系统日历的写入通过 Mac 页面及 Agent 的日程工具执行，需先由用户授权、勾选来源并明确选择可写目标。新建语音日程默认仅眼镜；系统映射项的编辑／删除路由原日历。系统保存成功但眼镜未同步时返回 `partial`，不自动重建或回滚系统事件。没有新增系统日历 HTTP 路由；上述 `/v1/schedules/*` 继续只操作眼镜。真实系统日历写入尚待选定目标后的验收。

## 天气

`GET /v1/dashboard` 返回 `reply` 和可用时的 `config`。更新既有城市时使用 `config.widgets_data.weather.location_ids` 的真实 ID；新增／删除城市配置应通过 Mac 城市管理或明确的 dashboard 配置更新，不能凭城市名称猜 ID。

`GET /v1/dashboard/preview` 只读取本机已接收的眼镜页面上报与最近布局缓存，不连接眼镜、不发包。`report:null` 表示尚未收到；`freshness` 区分本次连接上报、断连旧记录及重连后待上报。它不是截屏或切页接口，主动读取布局仍使用 `GET /v1/dashboard`。

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

## 眼镜设置与首页卡片

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `GET /v1/glasses/status`、`GET /v1/glasses/settings` | 设备状态／通用设置实际回读 |
| `GET /v1/glasses/changes` | 取出最近设置变化回执 |
| `PATCH /v1/glasses/brightness` | `{"value":3}` |
| `PATCH /v1/glasses/display`、`/wakeup`、`/units` | 对应配置字典，经 `data` JSON 字符串发送；先读取当前设置再修改 |
| `PATCH /v1/glasses/dashboard` | 原生首页布局：`simple_mode:0/1/2`、`widgets` 有序数组；0 卡片模式，1/2 两种简洁样式 |
| `POST /v1/glasses/cards` | `{"command":"stock_update","items":[...]}`；command 也允许 `clock_update/mail_update`，items 需符合官方字段 |
| `PATCH /v1/glasses/control` | `command` 为 `head_gestures/auto_lock_time/language_change/privacy_config/crown_config/sync_time/device_name_change/system_unints_config`，另传 `value/mode/data` |
| `PATCH /v1/glasses/assistant` | `command` 为 `set_ai_voice_wakeup/set_ai_work_mode/set_ai_lang/set_ai_model_str/set_ai_wakeup_word/set_ai_state`；总开关／语音唤醒／对话打断用 `mode:0/1`，唤醒词为 `1` 小雷小雷／`2` OK RayNeo 或 Hey RayNeo，对话语言为 `1...7`（普通话／粤语／英／法／德／西／意）；模型显示名称用 `data`，不是切换 Mac 模型 |
| `PATCH /v1/glasses/focus` | 更新定时／摘镜策略：`enabled` 当前状态、`enableGlassClose`、`automatic/begin/end/weekday`；保存后当前开关由时段计算 |
| `PATCH /v1/glasses/focus/enabled` | `{"enabled":true}`，手动立即开关；先读取并保留当前定时／摘镜策略 |

表冠例：`{"command":"crown_config","value":0,"data":{"double":0,"longPress":1}}`；线值 0 问AI、1 看板、2 专注、3 录音、4 字幕、5 提词、6 智记（仅双击）、7 无、8 待办、9 实时提示。头控例：`{"command":"head_gestures","value":1,"mode":0}`。写入返回原始回执，仍需检查状态／设置变化和眼镜实际显示。

`wakeup` 中 `crown_switch` 为息屏旋钮互动：0 关闭、2 扑克牌、3 弹珠，1 为保留的陀螺仪样式；与双击／长按的 `crown_config` 分开。正文同时保留 `headup_switch/headup_degree`。原版自动休眠选项为 5、10、15、25、40、60、120 秒。

勿扰手动开关与策略保存分别使用原版 trigger type 1 和 2；不要用快捷开关指令修改自动策略。`acknowledged:true` 不证明所有字段都已更新，需读取 `generalStatus.focusMode`；启用定时策略且当前在时段外时，保存后 `enable:0` 是设备计算的状态。

Mac **首页卡片**提供世界时钟与股票管理：腾讯行情搜索、刷新、按连接状态自动同步，以及独立手工价格。Mac **首页内容 → 当前位置天气**可请求系统定位，连接后每 30 分钟自动更新。股票搜索／定位在 GUI 服务层，不能假造额外 HTTP 路由。`mail_update` 支持手工卡片；Mac **首页卡片 → Apple Mail 邮件来源**已实现显式自动化授权、账户／文件夹选择、未读数与最新未读一封（至多 150 UTF-16 单元）预览，再手动同步。可选自动同步默认关闭，间隔 1／5／15 分钟，只在 Mail 已运行、已授权且眼镜连接时执行。它用本机 Mail，没有官方 OAuth，也没有新增邮件读取 HTTP 路由；本轮未执行真实 AppleEvents／邮件读取／硬件邮件显示验收。通知镜像内容适配仍关闭。

## 原生录音与本地资料库

这是眼镜录音服务 `0x0e`，与 `/v1/recording` 的实时提示双麦录音不同。

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `GET /v1/native-recording` | 活动／选中录音状态、`recordings` 历史、离线项目、字节覆盖和导出结果 |
| `POST /v1/native-recording/foreground` | `{"isAppForeground":true}`，上报前台状态 |
| `POST /v1/native-recording/query-status` | 查询眼镜当前录音 |
| `POST /v1/native-recording/start` | `{"mode":1}`；1 宽频、2 人声隔离 |
| `POST /v1/native-recording/pause`、`/resume`、`/stop` | 控制当前 UUID；无活动录音时返回 409 |
| `POST /v1/native-recording/mode` | `{"mode":2}`，改变处理模式，不是选择 PCM 声道 |
| `POST /v1/native-recording/mark` | `{"content":"可选标记文字"}`；活动录音中／暂停时在本地保存当前整秒标记，并发送原版 type11/action2 通知 |
| `POST /v1/native-recording/list` | 请求离线列表，之后 GET 读取异步结果 |
| `POST /v1/native-recording/sync` | `{"uuids":["..."]}`，重新读取列表后同步选中录音 |
| `POST /v1/native-recording/import-unmatched` | `{}`，重新核对眼镜闲置状态及完整列表，按原版省略 `items` 的整批协议导入本机未匹配录音，可能同时补传已有记录；不是任意 UUID 子集同步，不删除眼镜录音 |
| `POST /v1/native-recording/delete-offline` | `{"uuids":["..."]}`，读取完整列表后保留未选记录；进行中录音／传输拒绝删除 |
| `POST /v1/native-recording/select`、`/export` | `{"uuid":"..."}`，选择或导出本地录音 |

2026-11-04 在固件 1.0.5.12 上，start、pause、resume、mode2、stop 与空离线列表已通过；新录音 `completed:true` 后保存 4.18 秒、48 kHz 双声道、200,640 帧 WAV，原始 50,160 字节连续；两个必要传输 ACK 无错误。非空离线同步／删除仍待实机验证。`202`、idle 或单独 `completed:true` 均不证明文件完整，需核对 `finalized`、缺失范围与 `error`。

Mac **录音资料库**汇集本地录音和导入音频，支持标题／标签／搜索、播放、WAV 导出、百炼转写、DeepSeek 摘要及移至废纸篓。未完成原生录音可另存连续已收前缀，保留原始缓存。资料库不是新增 HTTP CRUD 服务；不要猜造对应路由。

原生状态包含 `markers`、`elapsedSeconds`、`markResult`。markResult.code 1 表示本机标记已保存，2 表示与前一标记不足五秒而未重复添加，3 表示当前录音不匹配或保存失败；它不是眼镜接受手机标记的回执。入站眼镜 type11/action1 先保存本地再回复；不向眼镜发送猜测的 mark time/content。资料库提供标记查看／跳播／本地编辑／删除，剪辑按保留区间重映射时间。来源音频有缺失时，标记时间不证明该处音频完整。设备方向与计时证据集中于仓库 `docs/protocol.md`；真实按钮／眼镜旋钮验收需单独记录。

## 文件、维护、OTA 与 AI 运行参数

| 方法与路径 | 正文 / 含义 |
| --- | --- |
| `GET /v1/files` | `transfers`、`receiveDirectory`，检查文件接收／发送最终状态；`automaticResume:false`，不承诺断连后自动续传 |
| `POST /v1/files/send` | `path`（本机普通文件绝对路径）；可选 `core:"small"/"large"`、`fileName`；文件 `businessID` 从 core 派生为 17／18，兼容传入时也必须匹配，不是接收内容的 App 业务号 |
| `POST /v1/files/cancel` | `{"uuid":"..."}`，立即取消选定本地任务，已连接时再发取消通知；`cancelNotificationSent` 不等于远端已确认停止 |
| `GET /v1/maintenance` | 最近固件／日志状态 |
| `GET /v1/firmware` | 向眼镜实际查询固件版本 |
| `POST /v1/glasses/factory-reset` | `{}`；固定仅发送 `value:1` 本地恢复出厂，不解绑官方账号；三秒等待 `factory_reset_ack` 且 `payload.value:0` 才返回 `accepted:true/requiresReconnect:true` |
| `POST /v1/glasses/unbind-reset` | `{}`；固定发送 `factory_reset value:2/mode:1`，等待明确业务ACK；仅设备清除，不执行官方云解绑或Mac系统解绑。GUI完整流程在云解绑成功后使用；真实破坏性操作未验 |
| `POST /v1/logs/request` | 请求眼镜压缩日志；之后用 `/v1/files` 追踪归档完成 |
| `GET /v1/ota` | OTA 准备／传输／安装验证状态 |
| `GET /v1/ota/official` | 官方会话配置状态、候选及检查／下载状态；不返回令牌或完整下载 URL |
| `POST /v1/ota/official/reload-session` | `{}`；仅重载本地所选官方会话并清空旧候选／检查／下载元数据，保留已下载文件；不连接设备、不发起新云请求；取消旧官方检查／下载并隔离迟到结果，已启动的本地设备安装不受影响 |
| `POST /v1/ota/check` | 使用本地官方账号会话异步检查更新；需先连接并读取固件版本；可选 identityEpoch 用于拒绝账号切换后的旧 GUI 请求。GUI 先自动刷新预检，独立 headless 调用遇过期返回异步 refresh_required，不自动下载 |
| `POST /v1/ota/download` | `{"candidateID":"当前候选ID"}`，异步下载当前候选 ZIP，不自动准备或安装 |
| `POST /v1/ota/official/cancel` | 取消官方检查或下载网络任务，与设备 OTA 安装取消无关 |
| `POST /v1/ota/prepare` | `{"path":"/absolute/package.zip","version":"target version"}`，解析本地包与清单 |
| `POST /v1/ota/start` | 从已准备包开始检查空间和供设备拉取 |
| `POST /v1/ota/verify` | 设备已报告安装后，重新查询版本验证；100% 传输不等于安装成功 |
| `POST /v1/ota/cancel` | 仅清理未激活的准备状态；真实传输／安装中返回 409，没有已证实的设备取消命令 |
| `GET /v1/assistant/runtime` | 模型、端点、超时、上下文、profileRevision、凭据是否已配置；不返回密钥 |
| `PATCH /v1/assistant/runtime` | `decisionModel/agentModel/asrModel`、三个 `*Endpoint`、`requestTimeoutSeconds/asrConnectionTimeoutSeconds/userName/deviceSerial/deviceModel/latitude/longitude`；作用于下一次助手会话 |
| `GET /v1/network-relay`、`POST /v1/network-relay` | 状态；Beta 默认关闭，只接受 `{"enabled":false}`；启用返回 403 |
| `GET /v1/capabilities`、`POST /v1/capabilities` | 缓存能力；POST 空对象查询，可用 `capabilities` 二维字符串数组上报 |

恢复出厂会删除眼镜内容，只在用户明确要求且理解清除范围时调用；GUI“固件与日志”提供破坏性确认，确认成功后关闭连接服务且不再发送设备清理命令。API 超时不能据此断言未清除，不自动重复请求。此接口已实现，未发送破坏性真机测试。

官方更新使用 Mac 账号面板保存的本应用 Keychain 会话，或启动环境的 `RAYNEO_ACCESS_TOKEN`、`RAYNEO_ACCOUNT_ID`；可选 `RAYNEO_REGION` 等见维护协议文档。它们是雷鸟官方会话，与 AI API 密钥不同。GUI 身份变化会请求本地重载；凭据轮换不会清候选。受保护 GUI 请求由统一协调器自动刷新，worker 不独立旋转 RT；普通鉴权失败按身份／凭据代次回报给 GUI 标记当前 AT 过期，不即时重放原云请求。GET 状态的 authenticationFailure 不含令牌。下次官方检查也重新读取所选会话。修改启动环境仍需重启。轮询 `/v1/ota` 的 `official` 区域判断检查／下载结果；GUI 下载后“填入准备区”只填路径和版本，准备与安装均另行手动发起。真实官方云认证／灰度检查／下载尚未验收。

通知页提供 Mac 通知镜像来源／数据结构检查、应用选择、结构导出和完全磁盘访问权限入口；所选应用新通知适配／基线／去重已接入，按用户要求保持关闭，未验收正文读取或转发。

实机已验证固件查询，以及 371,734 字节日志 tar.lz4 完整接收和协议 MD5 校验。通用发送、OTA 安装、智能跟读、网络转发与运行参数保存属于已实现路径，不能仅据源码存在称全部实机通过。AI 运行参数保存不配置官方眼镜账号，AI 提供商凭据仍从环境变量读取，响应 `deviceSynchronized:false`；官方账号另有专属 Keychain 会话，不与 AI 密钥混用。OTA 与日志归档都通过异步状态判断结果。

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

用户指定的眼镜双路策略为通道1默认本人、通道2完整说话人分析，助手与“声音与说话人”测试页按此执行；导入立体声眼镜录音同样保留两路，单声道全量识别。上表 `/v1/asr/*` 的 Apple 旧接口继续混合两路，普通 `/v1/recording/*` 仍保存实际双声道；需要带出处的输入使用上述助手双路路径。

## 两路内置虚拟麦克风

App 的“设备与 API”页面提供内置驱动安装包，安装由系统请求管理员授权；API 不安装驱动、不处理密码。安装后应出现 `OpenRayneo Microphone Channel 1/2`，UID 分别是 `com.openrayneo.microphone.channel1`、`com.openrayneo.microphone.channel2`。如未加载，由用户按安装指引重启 Mac，不自行重启系统音频服务。

`GET /v1/virtual-mic/devices` 返回在线虚拟双向设备的 `devices` 列表（`uid`、`name`、输入/输出通道数）。`POST /v1/virtual-mic/start` 使用 `{}` 或 `{"duration":3600}` 同时转送两路；duration 默认 3600、允许 10–21600 秒，两路内置设备均需就绪。声道 1 是佩戴者声音，声道 2 是前方声音，接收方分别选择对应输入设备。App 打包包含 Opus；单独运行 Swift 命令行构建时仍需本机解码库。

`GET /v1/virtual-mic` 返回共享音频状态，`engine:virtual-microphone`、`recording:null`，`virtualMicrophones` 为两路目标设备、通道、引擎状态和缓冲计数的数组，单数 `virtualMicrophone` 是第一路的兼容字段。转送不保存 WAV、不执行 ASR、不修改系统默认输入/输出；API 成功不能证明 Codex 已收到声音。

旧的显式 `{"deviceUID":"已安装的回环设备 uid","channel":1}` 请求保留为单路兼容模式，channel 可选 1 或 2；它不会同时启动内置两路。

ASR、录音和转送共享一个独占会话，任一 stop 均会结束该会话。仅在用户要求时启动，先结束自己拥有的显示/音频会话，记录模式和 SID。用 `POST /v1/virtual-mic/stop` 结束自己启动的转送；检查顶层 `running:false`、两路引擎 `running:false`、`error:null`，重复 stop 安全。转送与 `/v1/prompts/text` 共用实时提示页，可持续更新完整回答；短暂无音频或输出重配会保留页面，状态 `audioState` 为 `waiting`/`recovering`；`POST /v1/virtual-mic/recover` 在同一 SID 内重试输出并重置解码器；独立字幕、提词器与 ASR/录音仍互斥。声道归属取决于会话格式和decoder输出，单声道来源不能仅靠复制成双路就获得两种身份。

## 全天智记诊断（仅按要求使用）

1. `POST /v1/lifelog/observe`，`{"duration":60}`，支持 10–86400 秒，默认 300；仅在用户明确选择持续收音时使用 `duration:0`，直到手动停止或 App 退出。`inspect_audio:true` 检查解码；`record:true` 保存单声道 WAV 并默认保留原始分段；`preserve_audio:true` 可单独保留原始分段，默认关闭。`vad_start_delay_sec` 为 1–60，默认 2；`idle_timeout_sec` 为正整数，有限观察默认 30，持续模式默认 300。
2. 用户要求启用时 `POST /v1/lifelog/switch`，`{"enabled":true}`；observe 本身不是打开开关。
3. `GET /v1/lifelog` 读取事件与计数。观察器自动回应唤醒，未开启检查／保存时只计数。`audioInspection` 包含解码、任务归属与拒收计数、RMS、原始保留错误，以及可选 WAV 状态。无 taskId 的旧格式只回落到当前轮次并标记歧义；明确的其他 taskId 不会进入本轮 ASR。
4. 只有需要强制一轮音频请求时调用 `POST /v1/lifelog/record`；此名字不表示保存 WAV。
5. `POST /v1/lifelog/stop` 清理并排空已收音频；检查 `observing:false`、`finalizing:false`、`switchCleanupRequired:false` 和 `error`。开关结果只在 `switchResult.accepted:true` 时确认成功，`observedEnabled` 是独立状态回报，可能仍未知。关闭失败应重试 stop，或告知用户核对眼镜状态。

此路径独占音频／显示控制。AI 页可将当前轮次 PCM 送入百炼；HTTP 的 `assistant_capture:true` 配合 `POST /v1/lifelog/assistant-audio` 提供本机分段交接，本身不会调用云模型。保留的 A3 分段可在“录音资料库”手动恢复 WAV，再单独转写；恢复不会自动进入 Decision。它不是原版 A4 缓存导入，不发送旧版 A7 查询。保存 WAV 后仍需检查 `finalized:true` 和 `recordingError:null`。历史真机 A3 为单声道，不能替换两路独立麦克风；常驻图标也不等于正在录音。

## 原生助手唤醒（Beta 验证中）

`GET /v1/assistant/native` 读取 0x0D 原生唤醒状态、当前 `wakeID`、最近 64 条 wake/exit/next_round 事件和音频计数，不含原始音频。AlwaysOn 的 0xA1 不走此接口。

- `POST /v1/assistant/native/start`：`{"wakeID":"当前唤醒 ID","duration":60}`，开始最多 10–600 秒的本地收音，不自行调用模型；声音对照候选会自动保存最近一次capture原音。原生唤醒必须仍有效，现有显示／音频先结束。
- `POST /v1/assistant/native/audio`：`{"wakeID":"本次 captureID","after":0}`，获取带递增 sequence 的 begin/pcm/end/gap 事件，16kHz 单声道 S16LE PCM 以 Base64 返回。后续以已消费的 sequence 确认删除旧缓存；15 秒缓存溢出必须作为失败处理。此流为单个消费者使用。
- `POST /v1/assistant/native/stop`：传本次 wakeID，停止收音，保留眼镜原生助手页。
- `POST /v1/assistant/native/asr`：`{"wakeID":"当前唤醒 ID","text":"识别文字","final":true}`，对应官方 type5 ASR 文本，不是 NLP 回答接口。

### 最近原生助手会话音频

声音对照候选在每次真实native capture开始后自动流式保存16kHz mono PCM为私有WAV，结束后保留最近一轮。正常使用助手即可，无需arm、等待窗口或提前点击留存；原生收音仍沿用既有10–600秒生命周期，保存路径不再额外限制60秒或把整轮PCM攒在内存。

`GET /v1/assistant/native/diagnostic`沿用本机Bearer鉴权，查询当前保存状态及`latest`中的captureID、路径、帧数、字节数、时长和完整性。文件在本机`Application Support/OpenRayneo/NativeDiagnostics`，结束后发布latest元信息；下一轮成功保存后，旧音频移入Trash。录制期间可以同时存在当前写入文件和上一完整文件。

保存独立于ASR确认游标，不发额外眼镜命令、不改变唤醒或回复。异常／写入失败给出该轮incomplete及原因，上一完整latest保留；比较前核对目标captureID和时间，使用对应文件。App重开后仍可读取保存的latest。原始`native/audio`继续作为单消费者确认流使用，已从流清掉的历史声音应从latest文件取得；未落盘的旧轮次无法补回。

录音控制 type2 的 rc1/2 和 ASR type5 来自官方 SDK 实现；新接入仍需当前固件真机音频验证。Mac 默认收到唤醒只打开窗口，自动接听必须由用户在 AI 页启用。Beta 不代理雷鸟官方网络请求。`POST /v1/assistant/native/reply` 接受当前 `wakeID`、非空 `text`、可选 `query`，以固定 workflow/chat/chat 载荷写入原生助手页并发送完成通知；如仍在本轮收音，会先停止收音。此通道及其下一轮衔接仍待当前设备实时验收。
