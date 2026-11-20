# 设备协议合同

本页保留当前 OpenRayneo 设备链路所依赖的线协议、生命周期和恢复规则。
HTTP 路由及参数以 [本机 API 参考](../.agents/skills/openrayneo-api/references/api.md) 为准；
手机与 Mac 的数据交换见 [记录同步合同](record-sync-contract.md)，运行方式见 [runbook](runbook.md)。
项目计划与当前问题在 `.arch`，本页不保存构建流水或逐次实机调试日志。

协议依据主要是官方 RayNeo AI Android 1.0.5/1.0.10 的实际调用、原始指令和蓝牙抓包。
历史实机观察主要来自 Strix OS 1.0.5.12；其他固件须保留未知字段和原始结果。
SDK 枚举、发送成功、业务回复、设置读回与眼镜实际显示是不同证据层次。
文末索引保留原始 `analysis/` 入口；这些资料可能未随公开仓库分发。

## 1. 连接、认证与配对

BLE 承载发现、应用认证和业务消息；Classic Bluetooth SPP 承载主数据通路。
官方 SDK 的 `highSpeed` / `HIGH_AP(SPP)` 指这里的 SPP，未恢复可用的 Wi-Fi/USB 切换合同。
完整连接以 BLE 认证就绪且 RFCOMM 已连接为准，系统 bond、HFP 或眼镜连接动画不能替代它。

| 项目 | 当前合同 |
| --- | --- |
| BLE 服务 | `0000B81D-0000-1000-8000-00805F9B34FB` |
| BLE 发送 | `EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9` |
| BLE 接收 | `7DB3E235-3608-41F3-A03C-955FCBD2EA4B` |
| 配对资料 characteristic | `EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9` |
| SPP 服务 | `99999999-9999-9999-9999-999999999999` |
| RFCOMM | SDP 查询服务通道；当前实机通道 26 为超时后的已观测回退值 |
| RFCOMM 底层 | L2CAP PSM `0x0003`；实测 MTU 1011 是物理写分段上限 |

发现时结合名称、服务及 manufacturer data；已观测 company 字节 `16 57`、型号字节 `06` 和六字节经典地址。
认证前还要核对配对 characteristic 中的经典地址，避免只按相似名称选择设备。
应用注册与操作系统经典蓝牙 bond 分开处理。当前 **Mac** 的注册意图为：

- 新配对或明确重建 bond：BLE 注册 `pairValue` / TLV 27 使用 1。
- 普通连接、重连和使用现有配对：使用 2；该意图须跨 GUI/后台进程保留到本轮完成。
- 首次流程先 BLE 准备注册，释放 LE 并等断开，再由独立系统配对助手建立经典连接及 bond；随后重连 BLE、认证并开 SPP。
- 不因普通连接失败自动忘记 bond；HFP 网关也不是应用连接的必需门槛。

配对业务 `0x10` 的内部包为 `command:1 + length:BE16 + payload`，并非通用 protobuf envelope。
已恢复设备信息 17、认证请求 24、认证响应 25 的 TLV；22/23 的原始状态不能套 TLV 解码。
例如 `17 00 02 02 00` 是命令 23 的原始配对状态，不能直接当应用 ready。
认证使用现实现中的 challenge/device ID/协议常量计算；账户绑定 ECDH 分支尚未实现，遇到时明确失败。
Android 当前 [RayneoConnection.kt](../android/app/src/main/java/com/openrayneo/android/RayneoConnection.kt) 仍固定 TLV 27=1，
未同步采用 Mac 的普通重连 2；不能将 Mac 的已验流程泛化为两端已经一致。
详细字段、常量及系统配对调用保留在 [ProtocolCodec.swift](../Sources/OpenRayneoBridge/ProtocolCodec.swift)、
[BLEReadinessSession.swift](../Sources/OpenRayneoBridge/BLEReadinessSession.swift) 和
[BluetoothPairing.swift](../Sources/OpenRayneoBridge/BluetoothPairing.swift)，不要另造第二份认证算法。

BLE 写入按 `maximumWriteValueLength(.withoutResponse)` 分块，并服从 `canSendWriteWithoutResponse`；
等待 `peripheralIsReady` 后继续。蓝牙 delegate 在主队列，阻塞等待必须在工作队列。
SPP 写入也按实际 MTU 分块，物理分块不改变下面的应用帧。

## 2. AA55 帧与确认

```text
magic:2 | bodyLength:BE16 | sequence:BE16 | flags:1
        | address?:1 | sliceInfo?:N | businessID:1 | payload | crc16:BE16
```

`AA55` 为数据，`55AA` 为 transport ACK。
`bodyLength = 4 + addressLength + sliceInfoLength + payload.count`，不包含 magic、长度字段及尾部 CRC。
CRC16-XMODEM 覆盖从 sequence 到 payload 末尾的整个 body。

| flags 位 | 含义 |
| --- | --- |
| bit 0 | `needsResponse` |
| bit 1 | `useAddress`，存在一个 address 字节 |
| bit 2、3–4 | 保留 |
| bits 5–7 | `sliceInfoLength`，0–7 字节 |

普通无扩展帧 payload 最大 **65531 字节**；protobuf、JSON、UTF-8 和 base64 开销全部计入。
32768–65535 的 sequence/长度用无符号线值处理；Java `short` 的符号不是协议限制。
未恢复应用层大包分片/重组规则，不能通过增加 HTTP body 限额绕开 16 位帧长。
已声明的 sliceInfo 字段也不能作为猜测分片算法的依据。

入站 AA55 且 bit 0 置位时，发送同 sequence/business 的空 55AA：body 长度 4、flags 0、正确 CRC。
不对 ACK 再 ACK。官方 ACK 等待约 5 秒；超时是本次发送失败，不授权自动重放控制操作。
sequence 是每设备的 16 位序号；等待者至少按设备和序号关联，不能跨重连接收迟到结果。
transport ACK 只证明传输层确认，业务回复和实际执行仍须各自确认。

BLE 与 SPP 各自持有接收缓冲和半帧状态，但均接受业务帧。
SPP 发出的请求可能经 BLE 返回；不能只在发送所在链路注册回复。
录音等原版控制常用 flags 0，不能为了等待回复擅自改成 bit 0。

多数业务 payload 使用 protobuf `TransportMessage`：field 1 版本、2 事件 type、3 UTF-8 JSON、4 二进制。
常见版本为 1；JSON `action`、envelope type、外层 businessID、sequence 是四个独立字段。
录音控制按原始发送器编码显式空 field 4；不能把它当修复所有无回复问题的通用方法。

## 3. 连接恢复与主机状态

当前连接恢复汇合显式连接、业务需求、链路断开、设备入站 `0x10`/首字节 `0x1e` 提示和蓝牙上电。
`0x1e` 是入站恢复线索，尚无可据此构造的同名出站命令。
当前 Mac 一次恢复周期最多三次尝试，间隔 1/3 秒，总预算 45 秒；BLE 15 秒、SPP 8 秒、SDP 3 秒均受剩余预算限制。
曾成功连接且仍期望运行的服务可在失败周期后约 60 秒再尝试；首次失败不无限后台重试。
普通业务写入不绕过退避，显式连接/设备提示/上电可重新触发；suspend 撤销等待和后续重试。

所有 socket/delegate/查询按目标设备、连接 generation 与接收 epoch 隔离。
新连接清理旧半帧、控制队列和回执等待；迟到旧回调不接管新连接。
恢复连接不自动重放已失败的业务写；重新读取设备状态后由调用方决定下一步。
实现：[BridgeController.swift](../Sources/OpenRayneoBridge/BridgeController.swift)、
[BLEReadinessSession.swift](../Sources/OpenRayneoBridge/BLEReadinessSession.swift)、
[RFCOMMTransport.swift](../Sources/OpenRayneoBridge/RFCOMMTransport.swift)、
[BridgeProcessLifecycle.swift](../Sources/OpenRayneoBridge/BridgeProcessLifecycle.swift)。

全局前后台通知走 `0x10` 原始命令 31：前台 `1f 00 01 02`，后台 `1f 00 01 01`。
录音 `0x0e` type 14 的 `{isAppForeground:bool}` 是另一条业务通知，不能互相替代。
GUI 根据 `NSApp.isActive` 同步，而不是仅看窗口可见；headless 默认前台，可显式覆盖。
可查询/设置本机 `device/visibility`；该动作本身不自动建立连接。
状态分别记录 pending、已发送和 generation；`applicationAccepted:null` 表示没有业务接受确认。
正常退出可发送后台状态；焦点变化不会因此自动停止录音。
初始时钟/前后台/设置/原生录音/提词器同步入口在
[DeviceStateSynchronization.swift](../Sources/OpenRayneoBridge/DeviceStateSynchronization.swift)。

官方 handler 未注册入站队列只缓存 `0x0e/0x13/0x06/0x0f/0x14`：15 秒、总 24 条、每业务 8 条，
默认 payload 4096 字节，versionCheck 8192 字节，一次取出后移除。
它不是出站离线重试队列。当前 Mac 业务 handler 在连接前常驻；回执观察缓存不冒充此队列。

## 4. 活跃业务图

| businessID | 用途 | 当前合同入口 |
| --- | --- | --- |
| `0x06` | 能力/版本协商 | JSON capabilities；空列表可正常响应 |
| `0x09` | OTA | 版本、包拉取与安装后核验 |
| `0x0b` | 日志 | 压缩任务与独立文件传输 |
| `0x0d` | 原生助手、LifeLog | 两套不同 type 范围 |
| `0x0e` | 原生录音 | UUID、偏移、离线列表、完成信号 |
| `0x0f` | Launcher/设置/Dashboard | `{cmd,payload:{value,mode,data}}` |
| `0x10` | 认证/连接/前后台 | 原始 command/length/TLV 或状态 |
| `0x11/0x12` | 通用文件 | SmallCore/LargeCore，非两种无线连接 |
| `0x13` | 实时字幕 | SID 控制、音频与字幕显示 |
| `0x14` | 提词器 | 稿件/播放/进度；正文另走文件通道 |
| `0x15` | 通知 | 通知状态、MAP 请求/状态 |
| `0x16` | 日程/待办 | 批量、查询、状态变化 |
| `0x17` | 实时提示 | 独立持续音频/提示显示会话 |

只有 SDK 枚举的 `0x01/02/03/04/07/08/0a/0c/18/20`，不能据名称宣称可用。
目前未恢复眼镜应用安装、独立动作键、陀螺校准、低声设置、摄像/媒体流、Widget、心跳或导航完整合同。
表冠快捷设置走 `0x0f`；Dashboard 也走 `0x0f`。导航编号是十进制 32，不是提词器十进制 20。
不发送猜测的心跳、照片或导航包。

## 5. 原生助手与自动保留音频

原生唤醒走 `0x0d` AssistantMsg，和实时提示 `0x17`、LifeLog 的 161–168 不同。

| type | 方向/含义 |
| --- | --- |
| 1 | 眼镜唤醒 `{rc,mode,linkType}`；rc 1/2 语音、3 按钮、4 单次、5 Agent、6 LiveAI、7 共享音频 |
| 2 | 主机开始/停止收音 `{rc:1}` / `{rc:2}` |
| 3 | 眼镜 Opus，protobuf 二进制 field 4 |
| 4 | 主机 VAD：START 1、STOP 2、TIMEOUT 3 |
| 5 | 主机 ASR `{text,final}` |
| 6/9 | TTS 状态 / SpeechStatus：LISTENING 1、RESPONDING 2、THINKING 3 |
| 7/8 | 主机退出 / 眼镜退出；未明 rc 不自行扩展 |
| 11 | 手动下一轮，沿用上一回答 sid |
| 12/32 | 工作流完成 / SkillPayload 回答；按当前 SID 与调用顺序发送 |

回答 payload 含 `answer:{text,isFinal}`，以及 domain/intent/offline/query/round/sid/sub/timestamp/uuid/vendor 等字段。
chat 使用 `domain=intent=chat`、Unix 秒 timestamp；完整序列化以
[NativeAssistantPayload.swift](../Sources/OpenRayneoBridge/NativeAssistantPayload.swift) 为准。
唤醒 wakeID、收音 captureID、显示 SID、记录 ID、Agent task ID 和 DSH 会话身份必须分开。
停止收音不等于取消已经派发的 Agent；迟到回答须经过当前 wake/SID/显示意图门控。
DSH 原生 live 跨 wake 以稳定 phone ID + conversation key + preset 复用；显式新对话换 key。
任务创建时快照身份，旧任务不污染新对话；同会话按真实 turn/请求归属排队和取消，不仅按 sessionId 取回答。

Mac 原生 Opus decoder 直接配置 **16 kHz mono**，输出真实 16k 样本；不能将 48k 数据改 header 当成 16k。
ASR feed 是有确认游标的短期消费通道，确认后音频可清除。
每轮原生 capture 现在独立、自动流式写 16k PCM16 WAV，不需要 arm、TTL 或额外 60 秒限制。
既有 10–600 秒收音生命周期保持；正常 duration end 即可封口，不必等退出整个助手页。
完成后原子发布 App Support `OpenRayneo/NativeDiagnostics` 中的最近完整文件和 `latest.json`；
下一成功轮替换旧 latest，旧自建音频进废纸篓；当前临时录音和上一完整文件可以短暂共存。
断连、解码缺口或写入失败标记 incomplete，保留上一完整 latest。
状态区分当前 capture 和 `latest.captureID`，比较时禁止把上一轮误作当前；精确 GET 路由见 API 参考。
实现：[NativeAssistantController.swift](../Sources/OpenRayneoBridge/NativeAssistantController.swift)、
[NativeDiagnosticRecording.swift](../Sources/OpenRayneoBridge/NativeDiagnosticRecording.swift)。

## 6. 实时字幕、提示与双路 PCM

字幕 `0x13` 与提示 `0x17` 都使用 type 1 开始、2 结果/有效设置、3 控制、4 音频、5 文本。
SID 必须贯穿 start/audio/update/exit；只有收到匹配 SID 的成功配置才进入对应会话。
字幕临时配置 type 7/8；已用显示配置为 `font_size/content_width/max_lines/position/is_display/straight_view`。
字幕文本 mode 3，提示文本 mode 4，status 0 中间/1 最终，内容包含 `source_transcript` 和可选翻译。
提示开始常用 `{sid,trigger:1,force:false,code:0,settings:{mode:"conversation",source_language:"zh-CN",target_language:"zh-CN",save_audio:false,direction:"ahead"}}`。
成功结果 code 1 带 final_settings；字幕退出 reason_code 10，提示退出 reason_code 2。
`save_audio:false` 不会关闭 type-4 音频，也不决定本机是否保存。
打开页面只是音频/显示入口，ASR、speaker 和语义 Agent 处理由本机软件提供。

实际实时双路按 frame 解交错，各路独立 FIR/ASR/round/恢复游标：

- ch1 默认本人，无需登记；可 VAD/ASR，但跳过 embedding/diarization。
- ch2 完整 speaker + ASR；保留路别、身份依据和全部文字，不按同文猜测去重。
- 原生、全天混合和实际 mono 使用完整 speaker；`sourceChannel=1` 本身不是本人证明。
- Opus TOC 的 coded mono/stereo 可在同一流逐帧变化，不能作为物理输入路数；按入口协商及实际 decoder PCM format 取 1/2 路。
- 明确 stereo feed 才交错双路；旧 mono 客户端保持单路。采样率/声道数必须随 feed 元数据传递。

官方实时入口常以 48k stereo 解码；本地 speaker 按 lane 重采样至 16k，不能共用两路 FIR 状态。
没有真实 word 时间时保留整句范围和 speaker turns，不编造词级边界。
完整字段与墙钟映射见同步合同。实现：
[ChannelSpeakerProcessor.swift](../Sources/OpenRayneoBridge/ChannelSpeakerProcessor.swift)、
[DesktopChannelRound.swift](../Sources/OpenRayneoBridge/DesktopChannelRound.swift)、
[AssistantAudioFeed.swift](../Sources/OpenRayneoBridge/AssistantAudioFeed.swift)、
[PromptAudio.kt](../android/app/src/main/java/com/openrayneo/android/PromptAudio.kt)。

## 7. LifeLog / 全天入口

Launcher `0x0f` type 20 `life_log_switch` 请求开关，21 `life_log_switch_result` 返回状态。
持久开关、单轮收音和本地 workflow 是三个生命周期；不能只靠 result.value 或一包音频判断全部状态。
`life_log_switch_result.value` 是本轮操作结果：0成功、1无麦克风权限、2镜腿折叠、3低电，0不是关闭状态。
官方 1.0.10 开启 payload.data 为 JSON 字符串 `{delay:2}`，可选 delay 1–60 秒，关闭为 `data:""`；
delay 是 VAD 开始延迟，不能替代 A2 idleTimeoutSec，当前固件的该可选参数仍需实机确认。

| Assistant type | 含义 |
| --- | --- |
| 161/A1 | 眼镜唤醒本轮 |
| 162/A2 | 主机开始 `{taskId,idleTimeoutSec}` |
| 163/A3 | 实时 Opus，task/frame/VPU/VAD 元数据 |
| 164/A4 | 缓存兼容通路，taskId/bytes/isFinish |
| 165/A5 | 眼镜本轮结束，不代表本地转写/总结完成 |
| 166/A6 | 主机异常退出 |
| 167/A7 | 历史缓存查询；官方 1.0.10 重连路径跳过它 |
| 168/A8 | 主机上报 `{inRealtimePage}` |

A3 支持旧单帧及按 240 字节分帧的批量，frameCount 按实际可用数量限制，单包最多 31 帧。
不能把整批交给一次 Opus decode；保留 taskId/mode/vpuMask/vadMask，但这些 mask 不作为人物身份。
A4 按 taskId 保存原始 bytes；`.opus` 扩展不意味着 Ogg 容器。
缓存容量/保留时长未证实，不承诺全天无损离线录音或通过 A7 可靠补齐。
全天入口可能已有约 20 秒来源延迟，必须标注估计；不能套到原生实时 wake。
录音 offset 只计实际 PCM，跨轮静默由接收时间锚点表达，不把全天时间压成连续音频长度。
停止观察只撤销自己启用的开关/工作流，避免退出调试页误关其他拥有者。
实现：[LifeLogCaptureStore.swift](../Sources/OpenRayneoBridge/LifeLogCaptureStore.swift)。

## 8. 原生录音与离线恢复

`0x0e` version 1 同时带 JSON 和二进制 field 4；protocol UUID、sid 与本地存储 UUID 分开。

| type | 名称 / 主机请求 |
| --- | --- |
| 1 | start：`{uuid,sid,type:1,mode:1或2,action:1}`；sid 为开始 Unix 秒字符串 |
| 3 | 音频数据，按 uuid/offset 保存 |
| 4 | stop：`{uuid:<当前>,code:2,action:1}` |
| 5 | 重连状态，用于重新对齐已有录音 |
| 6/7 | 数据完成 / 离线信息 |
| 8 | pause：`{uuid,code:1,action:1}` |
| 9 | resume：`{uuid,action:1}`，不自行添加 code |
| 10 | 麦克风模式：`{uuid,mode,action:1}`；1 WideSpectrum、2 VoiceIsolation，不是 PCM 路号 |
| 11 | mark；眼镜 action 1，主机 action 2 回复 |
| 12 | syncList 查询 `{action:1}` / 对齐响应 action 2 |
| 13/14/255 | 镜腿状态 / 录音前后台 / 蓝牙变化 |

已恢复实时录音格式为 240 字节/20ms Opus 包，解码为 48k stereo；按原始字节 offset 合并范围。
type 3 不另造逐包业务 ACK；type 6 也没有已恢复的额外完成 ACK，外层 needsResponse 仍独立处理。
`completed:true` 仅是完成信号；必须同时满足从零开始的连续包覆盖、正且包对齐的长度及已知 expectedBytes。
`offline_size` 外层字段与列表项 `offlineSize` 不同；后者被官方用于进度总量，真实固件非空列表的完整大小语义仍待确认。
不以推测总量/进度 100%/可播放前缀冒充完整录音，不用静音填补丢包。
重连先查状态和离线列表，不自动另开录音；保留 UUID、范围及 writer 以继续。

syncList 项为 `{uuid,offlineSize}`；`items` 省略与空数组不能擅自视为等价。
导入未知录音必须先持久建立 protocol UUID → 新 local UUID 与 writer/cache，再复核设备 generation。
导入整批发送 `{action:2,total_items:N,deleteOther:false}`，省略 items；N 包括合格旧续传和新导入。
该响应没有 UUID 列表，不能承诺“只下载选择的未知项”；可能重传已知项，按 offset 去重。
显式选择的续传仍使用 items。导入期间禁止与 live/tail 或其他传输竞争。
删除离线录音必须基于新鲜完整列表保留其他项；不拿缺项/超时授权清空。

mark type 11 主机只发 `{uuid,code,action:2}`，不发送本地标记文字/时间。
code 1 本地保存成功，2 相邻标记不足五秒，3 无匹配 durable 会话或保存失败。
位置为录音相对整秒，优先录音进度；fallback/接收 offset 校准须保存 timeBasis。
资料库编辑/删除仅改本地索引，tombstone 防止刷新复活；剪辑副本按保留区间重映射标记。
实现：[NativeRecordingController.swift](../Sources/OpenRayneoBridge/NativeRecordingController.swift)、
[RecordingMarker.swift](../Sources/OpenRayneoBridge/RecordingMarker.swift)。

## 9. 通用文件与提词器

`0x11` SmallCore / `0x12` LargeCore 使用同一文件协议，不能把 bus_id 17/18 当提词器业务 20。
protobuf TransferMessage oneof 为：1 FileInfoSync、2 FileInfoAck、3 FileChunkReq、4 FileChunk、5 FileRecvState、6 FileCancel。
FileInfoSync 含 uuid/filename/filesize(uint64)/md5/bus_id；chunk 含 uuid/chunkid/chunkstart(uint64)/chunksize/data。
接收方拉取范围，单次最多 51200 字节；缺省 protobuf 零值可表示起点 0 和 SUCCESS 0。
按范围并集与协议 MD5 核验；重复范围不追加第二份数据，CRC 故障有限重试后失败。
发送完成须等远端 FileRecvState SUCCESS；接收完成须文件覆盖和 MD5，完成通知发送失败另记状态。
取消先停本机，未完成文件进废纸篓；能连接时发送 FileCancel，不为取消强制重连。
120 秒无进展判超时；尚无跨进程自动续传合同，已有 offset 字段不构成持久 resume 协议。
实现：[FileTransferController.swift](../Sources/OpenRayneoBridge/FileTransferController.swift)。

提词器 `0x14` 的 action 1 请求/2 响应，type 1列表、2选稿、3开始读、4暂停、5继续、6停止、7设置、8进度、9音频、10状态、11toast。
列表 type 为 fullSync1/batchTop2/batchAdd3/batchDelete4/updateContent5；删除单稿不发清空整个列表。
稿件 did、UTF-8 字节 total、checksum 与 UI UTF-16 光标不是同一单位。
眼镜选稿后先解析本机稿件，以实际正文长度为准，回复 type2/action2/code1 或缺稿 code5，再经 `0x11` 传正文。
文件完成和提词器接收确认分别等待，后者 code1/7 为已恢复成功分支；开始读再回应 type3。
scroll 为 followSpeak1/linear2/manual3；设置及页内高亮位置须沿已恢复 serializer，不猜 mode。
连接恢复读取状态/checksum，不把眼镜位置无条件覆盖本机未提交编辑。
实现：[TeleprompterRepository.swift](../Sources/OpenRayneoBridge/TeleprompterRepository.swift)、
[TeleprompterFollowController.swift](../Sources/OpenRayneoBridge/TeleprompterFollowController.swift)。

## 10. 设置、Dashboard、日程与通知

Launcher `0x0f`：type 1/4 查询 general status/settings，2/3 状态变更，5/6 设置变更，14/15 reset/ack，
16/17 assistant config/sync，18/19 Dashboard，20/21 LifeLog，22/23 setup，24 preview。
`payload.data` 常为 JSON **字符串**，不能直接替换成嵌套对象。

| 控制 | cmd / 关键值 |
| --- | --- |
| 显示/唤醒/隐私 | `display_config:{height,distance}`；`wakeup_config:{headup_switch,headup_degree,crown_switch}`；`privacy_config` |
| 表冠/头控 | `crown_config` 的方向及 double/longPress；`head_gestures` value/mode 为0/1 |
| 单位/时间 | 原拼写 `system_unints_config`；`sync_time:{utc,offset,timezone}` |
| 自动休眠 | `auto_lock_time` 秒：5/10/15/25/40/60/120 |
| 息屏互动 | crown_switch 0关闭/1保留旧陀螺仪/2扑克牌/3弹珠；不是快捷键 |
| 专注 | `focus_mode`；data.type=2 保存策略，1手动开关，4关闭无动画；手动保留刚读回策略 |
| AI 开关/唤醒/打断 | type16，`set_ai_state/set_ai_voice_wakeup/set_ai_work_mode`，mode0/1 |
| AI 语言/唤醒词 | `set_ai_lang` mode1–7=zh-CN/zh-HK/en-US/fr-FR/de-DE/es-ES/it-IT；`set_ai_wakeup_word` 1小雷/2英语 |
| AI 名称 | `set_ai_model_str` data字符串；未恢复无线 timbre setter |

`sync_ai_settings` 是增量同步，不是某条 setter 的特定成功 ACK；和完整 voiceAssistantConfig 合并，保留未知值及未提交编辑。
恢复出厂 type14 `factory_reset` value1；解绑流程设备清除 value2。必须明确 type15 `factory_reset_ack` value0 才报接受。
设备清除、官方账号解绑、本机忘记是三种动作；当前官方云已停用，不自动串联它们。

Dashboard `data` 内容与布局分开：`dashboard_update` 只序列化 `{simple_mode,widgets}`，不补造 widgets_data 写入。
组件线值 weather1/todo2/schedule3/stock4/email5/worldClock6；simple_mode0/1/2。
城市/股票/邮箱/时钟身份随各自完整 `*_update` 内容发送；`payload.value` 为结果0成功/1无新数据/2网络错/3服务错/4未授权。
删除天气组件仅移除布局并停本地刷新，未恢复“空列表清除最后城市”的固件合同。
`glass_preview` type24 是入站页面报告，不是控制/截图；data 的 `scence` 优先于 scene，原索引需按场景转换。

日程/待办 `0x16`：type5 schedule批次、6 todo批次、15查询/16回复，9权限状态；变化另见现 serializer。
日程 startTime/endTime 为 Unix **秒**，createTime/lastModifiedTime 为毫秒，localTimeOffset 为秒。
保持 total/isLastBatch/eventList、ID、来源及状态；查询完整性不足不按缺项删除。
系统日历是 EventKit 数据来源，不是新蓝牙业务：明确选可写目标，失败不静默改投；默认 AI 新增仅眼镜。
仅同步所选来源今天/明天；眼镜列表缺项不得删除系统事件。重复事件编辑/删除范围和全天排他结束日由 EventKit 路径处理。

通知 `0x15`：type2内容、3状态、4回复 `{cmd,notificationUID}`、0x11全量设置。
MAP 请求 type0x16 `{requestId,enabled:bool}`，type0x17 回 `{requestId,state,code?}`；state1已连/0断开。
只用匹配 requestId 完成本轮申请；false 是关闭请求，不是只读查询；普通通知设置不包含 MAP 权限。
未恢复任意短信正文/手机号发送合同，Mac 镜像也不提供 Android MAP/RemoteInput 能力。
上述控制的精确字段与 API 均由文末源码和 API 参考维护。

## 11. 能力、维护与云边界

`0x06` capabilities 空列表可返回 OK，不能由“能力注册”推导固件扩展/任意应用安装或录音必须注册。
OTA `0x09` type1版本、3 NAND大小(OtaSize=原ZIP字节)、4传输页(Mode2普通)、5版本请求、6清单、7范围拉取、8进度、9安装、10失败。
本地包按 `OtaFileInfo.json` 的真实清单/路径/大小/MD5 准备，type6保留清单原文，type7二进制回应拉取。
进度100或type9仅表示进入安装；重连 type1 目标版本匹配且 OtaValidationConfirmed=true 才标完成。
未证实的 type2电量/11空闲回复字段不作为升级门控；不以少量回收组件冒充完整包。
日志 `0x0b` type16 `start_log_task`，type17 ACK value0成功/1压缩中/2空间不足/3压缩失败/4其他错。
value0 的 data 是文件 UUID，按设备+UUID等通用文件完成后才算下载完成。

Beta 关闭官方登录、上传、云记忆/音频、固件联网下载、反馈发送及 `0x19` HTTP 代理。
旧本机缓存保留；眼镜硬件业务、本机 Agent、手机同步和显式本地 OTA 包是独立入口。
边界以 [OfficialCloudPolicy.swift](../Sources/OpenRayneoBridge/OfficialCloudPolicy.swift) 为准，旧云源码仍可审阅但不是活跃产品合同。

## 12. 实现与原始证据索引

以下原始资料保留于本地 `analysis/`；未列全的数值应从对应 serializer/现实现取，不从旧 UI 文案猜测。

| 领域 | 当前实现 | 保留的逆向入口 |
| --- | --- | --- |
| 配对/双链路/恢复 | [BLEReadinessSession](../Sources/OpenRayneoBridge/BLEReadinessSession.swift)、[BridgeController](../Sources/OpenRayneoBridge/BridgeController.swift)、[BluetoothPairing](../Sources/OpenRayneoBridge/BluetoothPairing.swift) | [reconnect](../analysis/reverse-2026-11-03/reconnect/)、[native-protocols](../analysis/reverse-2026-11-03/native-protocols/) |
| 能力/早到入站队列 | [CapabilityController](../Sources/OpenRayneoBridge/CapabilityController.swift)、常驻 handler | [capability-registry-init.asm](../analysis/reverse-2026-11-03/capability-registry-init.asm)、[pending-message-enqueue.asm](../analysis/reverse-2026-11-03/pending-message-enqueue.asm) |
| 帧/扩展/ACK | [ProtocolCodec](../Sources/OpenRayneoBridge/ProtocolCodec.swift)、[RFCOMMTransport](../Sources/OpenRayneoBridge/RFCOMMTransport.swift) | [transport-reader-fallback.java](../analysis/reverse-2026-11-03/transport-reader-fallback.java)、[transport-ack-manager.java](../analysis/reverse-2026-11-03/transport-ack-manager.java) |
| 原生/全天/实时音频 | NativeAssistantController、LifeLogCaptureStore、SpeechController | [memory-read](../analysis/reverse-2026-11-03/memory-read/)、[caption-protocols](../analysis/reverse-2026-11-03/caption-protocols/)、[后续实时入口审计](../analysis/reverse-2026-11-07/official-interactive/) |
| 原生录音/离线/标记 | NativeRecordingController、RecordingMarker | [recording-orphan-import](../analysis/reverse-2026-11-03/recording-orphan-import/)、[recording-marks](../analysis/reverse-2026-11-03/recording-marks/)、[原始包](../analysis/reverse-2026-11-03/baseline-hci/) |
| 文件传输 | FileTransferController | [file_transfer.proto](../analysis/reverse-2026-11-03/apk-native/file_transfer.proto)、[SDK源](../analysis/reverse-2026-11-03/jadx/sources/K5/) |
| 字幕/提词/导航边界 | [TeleprompterRepository](../Sources/OpenRayneoBridge/TeleprompterRepository.swift)、SpeechController | [display-navigation](../analysis/reverse-2026-11-03/display-navigation/)、[glasses-teleprompter-logs](../analysis/reverse-2026-11-03/glasses-teleprompter-logs/) |
| Launcher/AI/表冠/息屏 | [GlassesSettingsController](../Sources/OpenRayneoBridge/GlassesSettingsController.swift) | [launcher-setters](../analysis/reverse-2026-11-03/launcher-setters/)、[assistant-settings](../analysis/reverse-2026-11-03/assistant-settings/)、[device-actions](../analysis/reverse-2026-11-03/device-actions/)、[wake-display](../analysis/reverse-2026-11-03/wake-display/) |
| Dashboard/天气/预览 | [DashboardLayoutModel](../Sources/OpenRayneoBridge/DashboardLayoutModel.swift)、[DashboardPreviewStateStore](../Sources/OpenRayneoBridge/DashboardPreviewStateStore.swift) | [dashboard-serializers](../analysis/reverse-2026-11-03/dashboard-serializers/)、[weather-removal](../analysis/reverse-2026-11-03/weather-removal/)、[dashboard-preview](../analysis/reverse-2026-11-03/dashboard-preview/) |
| 日程/系统日历 | [ScheduleController](../Sources/OpenRayneoBridge/ScheduleController.swift)、[CalendarSyncModel](../Sources/OpenRayneoBridge/CalendarSyncModel.swift) | [calendar-writeback](../analysis/reverse-2026-11-03/calendar-writeback/)、[mutation-hci](../analysis/reverse-2026-11-03/mutation-hci/) |
| 通知/MAP | [NotificationMirrorModel](../Sources/OpenRayneoBridge/NotificationMirrorModel.swift) | [notification-replies](../analysis/reverse-2026-11-03/notification-replies/) |
| 能力/OTA/日志/未知业务 | [CapabilityController](../Sources/OpenRayneoBridge/CapabilityController.swift)、[OTAUpdateController](../Sources/OpenRayneoBridge/OTAUpdateController.swift)、[MaintenanceController](../Sources/OpenRayneoBridge/MaintenanceController.swift) | [maintenance-enums.json](../analysis/reverse-2026-11-03/maintenance-enums.json)、[log-ack-handler.asm](../analysis/reverse-2026-11-03/log-ack-handler.asm)、[other-device-businesses](../analysis/reverse-2026-11-03/other-device-businesses/) |

SDK 源、Dart VM 指令边界与对象池统一保留在 [JADX](../analysis/reverse-2026-11-03/jadx/)、
[Blutter](../analysis/reverse-2026-11-03/blutter-output/)；原始抓包高于字段猜测，实际 sender 高于仅名称/字符串。
