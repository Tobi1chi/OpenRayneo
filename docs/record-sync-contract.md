# 相遇记录同步合同 v1

手机是记录、转写、总结和人物档案的权威端；Mac 保存持久副本及 Agent 派生项离线队列。
配置手机地址与专用凭据后，Mac 每 15 秒尝试同步；断网时仍可读取副本、写笔记，下次继续交换。
设备线协议见 [protocol](protocol.md)；精确本机路由见 [API 参考](../.agents/skills/openrayneo-api/references/api.md)。

## 1. 监听面与权限

手机相遇同步默认 `http://<phone>:8767`，必须携带 `Authorization: Bearer <sync-token>`。
只开放本页的 exchange/audio 两路由；与本机 Agent token 分开，可独立启停和轮换凭据。
本机 Agent 控制入口仍为 loopback（手机默认 8766），Mac 设备控制 API 也只绑定 loopback。
不因开启同步而把眼镜控制或人物编辑接口暴露到 LAN。
当前使用显式可达地址、无云中转；HTTP 凭据只应通过可信本地网络传输。
手机持久保存两个监听面的启用设置，进程重启恢复此前启用项。

## 2. 增量交换

`POST /v1/sync/exchange`，JSON：

```json
{
  "protocolVersion": 1,
  "cursor": 0,
  "limit": 100,
  "derived": [{
    "id": "UUID", "recordId": "record UUID", "revision": 1,
    "sourceRevision": 7, "kind": "note", "text": "补充笔记",
    "tags": [], "agent": "local-agent", "updatedAt": 1794800000000,
    "stale": false
  }]
}
```

响应：

```json
{
  "protocolVersion": 1, "cursor": 12, "hasMore": false,
  "records": [], "people": [], "acceptedDerivedIds": ["UUID"]
}
```

- 手机持久维护全局单调 change sequence；记录和人物共用序列，每对象发送当前最新快照。
- 按 sequence 排序，records/people **合计**占用 limit（当前范围 1–100）。cursor=0 分页取得全部当前对象。
- 后续只取 sequence 大于 cursor 的对象；响应 cursor 为本批最后 sequence，空批保留请求值。
- `hasMore=true` 继续下一页，不能只同步 records 后误跳过同一游标范围的 people。
- 先应用 incoming derived，再计算本次变更页；接受派生也会进入记录快照变化。
- 原记录 `revision` 仅由手机递增，派生确认不自行递增源版本；序列游标不是源 revision。
- Mac 原子落盘记录、人物、派生、outbox 和新 cursor 后才更新内存进度；写失败保留旧状态重取。
- Mac 保留完整对象中的未知 JSON 字段，重复页按 id/revision 合并，不新增重复记录。
- 空页/列表缺项不表示删除。当前协议无通用跨端删除墓碑或远端清库指令。

## 3. 源对象与时间

记录核心字段如下；新增字段向后兼容，读取端不以旧字段白名单重建对象。

| 字段 | 合同 |
| --- | --- |
| `id,revision` | 手机记录身份与源版本 |
| `mode` | `DAILY` / `MEETING` / `ENROLL` |
| `source` | `REALTIME` / `NATIVE` / `ALWAYS_ON` |
| `createdAt,endedAt` | Unix 毫秒，endedAt 可空；不是音频样本 offset |
| `title,segments,summary,summaryStale` | 原文及旧版汇总兼容字段 |
| `summaries,memories,derived` | 总结快照、记忆与派生 |
| `processingPending,audioPending` | 尚待处理 / 尚在写原音频，不能因 ASR/模型失败清空进度 |
| `audioId,audioSamples,audioChannels` | 音频身份、每声道 16k frames、实际存储声道数 |
| `speakerPeople,channelPolicy,processingCursors` | 记录内身份映射、声道策略、每路处理游标 |
| `audioAnchors` | 各收音轮次 PCM offset 与手机接收墙钟映射 |

`audioAnchors` 形如 `[{"offsetMS":20000,"receivedAt":1794800000000,"timeBasis":"received"}]`。
它保存实际接收时刻，不声称眼镜提供了可证实的原始发声时间。
全天轮次间静默不能被“启用时刻 + 累计 PCM 时长”压缩掉；回放沿用原锚点。

`segment.beginMS/endMS` 是记录 PCM 样本域的毫秒，用于 ASR/speaker 对齐和原音频截取。
`timelineAt/timelineEndAt` 是经锚点映射的接收墙钟范围；`timeBasis` 为 `received` 或旧库 `legacy-estimate`。
日/月列表和日总结按墙钟归日。真实词时间跨锚点可分组；没有词时间的整句保留实际范围，不编词时间。
Mac 副本保留这些字段；其记录范围查询仍采用第 7 节的记录级区间，消费方逐句归日须读取 timeline 字段。

分段同时保留 `id,text,speaker,personId,stable,mixed,revision,receivedAt,roundId,candidates,matchReason`。
未知、混叠、未识别本人均照常存档/同步；不为得到人物名而丢弃文字。
`processingMode=live/backfill` 表示处理路径；补齐首次新段可交本机 Agent，已完成旧段不重复派发。
Agent 上下文带 `timelineAt,timeBasis,asrCompletedAt,age_seconds,processing_delay_seconds`；age/delay 基于接收锚点。
全天入口约 20 秒来源延迟仅为另列估计，不能用它改写原生时间或替代语义决策。
DSH `input.backfill=true` 是历史上下文，插件不将历史指令自动作为新操作执行。

`summaries` 每项含 `kind,text,createdAt,recordIds,stale,day`。
kind 为 rolling/record_end/day_end；day_end.day 是 `YYYY-MM-DD`，跨午夜记录可以归入多天快照。
源片段/人物归属变更后相关派生和总结标 stale；当日新记录也使已有 day_end 的来源集合过期。

人物含 `id,name,self,contactUri,model,revision` 和合并/纠正元数据。
`mergedInto` 保留退休身份及历史关联；不是删除旧人物 ID 或自动全库改写所有片段。
显式纠正/合并/拆分由手机选择历史范围并修订受影响记录，人工归属不得被音频补齐覆盖。
默认交换去掉 `speakerSamples`、人物 samples/embedding 和原音频；Mac 人物快照不能当作可做声纹推理的参考库。
Mac 本地声纹资料与手机声纹资料独立，当前不通过该协议同步原始向量。

## 4. 双路与旧 mono

`audioChannels=1/2` 表示**实际存储**声道数；旧 ORPCM1 缺字段默认 1。
`audioSamples` 为每声道共享的 frames，不是 stereo 交错 short 总数；PCM 样本率为 16000。

| 策略/字段 | 含义 |
| --- | --- |
| `dual_channel1_self` | 实际双路 REALTIME：ch1 独立 ASR、默认本人、跳过 embedding/diarization；ch2 独立完整 speaker/ASR |
| `full_speaker` | 原生、全天混合或实际 mono，全部按完整 speaker 处理 |
| `legacy_selected_mono` | 旧版只保存选中一路；不能补造已丢另一通道 |
| `segment.sourceChannel` | 存档 PCM 的路号 1/2；mono/混合也是 1，因此不能直接据此认本人 |
| `identityBasis` | `channel1_default_self` / `voiceprint` / `unknown` / `mixed` / `manual` |

保留 channelPolicy + sourceChannel + identityBasis；两路同文或都匹配本人也不删除任何一路。
Opus coded channels 允许逐帧变化，不能按 TOC 把一段 stereo 会话改成“真实 mono”。

`processingCursors={"1":frames,"2":frames}` 是每路持久完成游标。
恢复从 min(cursor) 读共享 raw，再按各路 cursor 剪去已完成部分；ch1 领先不跳过 ch2。
成功无语音也推进到真实已完成 frames，不能仅取 max(text.endMS) 让静音路永久重跑。
共享 audioAnchors，segment IDs 带路别；历史拆分按 sourceChannel 取对应 PCM。

手机内部 ORPCM2 为带声道数的加密交错 PCM，ORPCM1 mono 仍可读取。
writer 按每声道一秒切块（mono 32000 / stereo 64000 字节），大 append 不能写出 reader 不接受的超长块。
seek/recover 按 frame，尾块保留实际长度；该内部加密格式不跨端，Mac 只消费 JSON 和 WAV。

## 5. 派生、确认与离线重试

派生 kind 为 `analysis/note/tags`；id 为 UUID，revision 由创建端递增，sourceRevision 指明分析依据的源版本。
Mac 不写源转写或源人物；编辑同 id 时取本地索引和记录内 derived 的已知最大 revision 后递增。
手机按 id/revision 幂等：已有同版/更新版可确认，记录不存在不确认；应用后快照包含该派生。
源 revision 改变则 stale=true，新分析使用新 sourceRevision 可刷新，旧分析保留。

`acceptedDerivedIds` 仅含 ID，确认对象是**本次请求发送的版本**。
发送 X/rev1 后若本机产生 rev2，rev1 的确认不能清除 rev2 outbox。
当前 Mac 将 API 修改、网络交换和持久化放在同一串行队列，交换期间不能并发修改 revision/peer；
今后异步化必须继续用发送快照 revision 和 peer 上下文确认，不能改成仅按 ID 清队列。
确认项仍保存在副本，未确认项持久保留；网络超时可重放同一派生，不复制第二项。

peer 地址变化需要显式 `resetCursor:true` 并从 0 全量取；旧副本保留。
旧 peer 请求的结果/游标不能应用到新 peer；当前同一串行队列保证切换不插入在途交换中。
源账户/手机更换并不授权隐式删除旧副本，当前没有自动跨手机身份合并。

## 6. 按需音频

`GET /v1/sync/audio?recordId=<URL-encoded UUID>` 返回 `audio/wav`。
无可用音频 404；仍在写音频 409；只按已知 recordId 解析，不能读取任意文件路径。

WAV 为 16 kHz PCM16、实际 mono/stereo，双路按 frame 交错：
`Content-Length = 44 + audioSamples * audioChannels * 2`。
不将 stereo 帧数当样本总数，不以 mono header 标注双路 bytes。
Mac 仅在显式请求后下载并缓存独立文件，普通交换不拉音频；本机 API 返回该缓存路径。

## 7. Mac 本机 Agent 路由

以下路由复用 Mac loopback API 和既有 Bearer 鉴权，不复用手机 LAN sync token。

| 路由 | 合同 |
| --- | --- |
| `GET /v1/records` / `POST /v1/records/query` | `from/to` Unix ms、recordId、text；返回副本 |
| `GET /v1/records/people` | 不含声纹 samples 的人物快照 |
| `POST /v1/records/derived` | 提交派生；省略 id/revision/updatedAt/agent 时生成默认值 |
| `POST /v1/records/audio` | `{recordId}`，显式获取音频缓存 |
| `GET /v1/records/sync` | 不含 token 的状态、cursor、pendingCount、错误 |
| `PATCH /v1/records/sync` | `{peerURL,token,enabled,resetCursor?}` |
| `POST /v1/records/sync` | 入队立即尝试一次，不把入队回执当已完成交换 |

Mac 记录级查询用 `[createdAt,endedAt)` 与 `[from,to)` 半开区间交集；endedAt=null 延续到查询时刻。
手机本地查询的空 endedAt 则只在 audioPending 时延续 now，否则取实际 segment.endTimeOf 或 createdAt。
二者都不把累积 PCM offset 直接当跨日发声墙钟；精确逐句时间须使用 timelineAt/timelineEndAt。

## 8. 代码依据

- 手机协议与监听：[RecordSyncServer.kt](../android/app/src/main/java/com/openrayneo/android/RecordSyncServer.kt)。
- 源 revision、分页、派生幂等、人物纠正：[ConversationRepository.kt](../android/app/src/main/java/com/openrayneo/android/ConversationRepository.kt)。
- 字段及双时间：[ConversationModels.kt](../android/app/src/main/java/com/openrayneo/android/ConversationModels.kt)。
- 原音频块/seek/recover/WAV：[MeetingAudioStore.kt](../android/app/src/main/java/com/openrayneo/android/MeetingAudioStore.kt)。
- 补齐和独立 lane 游标：[ConversationController.kt](../android/app/src/main/java/com/openrayneo/android/ConversationController.kt)。
- Mac 原子副本、派生 outbox 与 peer 队列：[RecordSyncController.swift](../Sources/OpenRayneoBridge/RecordSyncController.swift)。
