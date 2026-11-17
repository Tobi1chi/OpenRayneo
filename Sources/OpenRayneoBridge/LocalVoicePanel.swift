// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@MainActor
struct LocalVoicePanel: View {
    @ObservedObject var bridge: DesktopBridge
    @ObservedObject var model: LocalVoiceLab
    @ObservedObject var asr: LocalASRSettings
    @State private var recordingID: UUID?
    private var assessment: LocalVoiceAssessment { model.assessment }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("在 Mac 对照 Android 的声音算法").font(.headline)
            Text("双路眼镜输入默认通道1归属本人，仅做VAD；通道2独立完成分段、声纹和转写。单声道与全天混合音频全量识别，音频和声音特征在本机处理。")
                .font(.callout).foregroundStyle(.secondary)
            LocalASRPanel(model: asr)
            GroupBox("输入与处理") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("用途", selection: $model.enrolling) { Text("说话人分段与匹配").tag(false); Text("登记声音").tag(true) }.pickerStyle(.segmented)
                    Picker("音频策略", selection: $model.channel) {
                        Text("眼镜双路：1本人＋2识别（默认）").tag(3)
                        Text("实验：仅声道1全量识别").tag(1); Text("实验：仅声道2").tag(2); Text("实验：双声道混合").tag(0)
                    }
                    HStack {
                        Button("选择录音文件…") { model.chooseFile() }
                        Text(model.sourceURL?.lastPathComponent ?? "尚未选择文件").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("分析录音") { model.analyzeFile() }.disabled(model.sourceURL == nil)
                    }
                    HStack {
                        Picker("录音资料库", selection: $recordingID) {
                            Text("选择已有录音").tag(nil as UUID?)
                            ForEach(bridge.recordingLibrary.entries.filter { $0.available && $0.finalized }) { entry in
                                Text("\(entry.title) · \(entry.durationLabel)").tag(Optional(entry.id))
                            }
                        }
                        Button("使用此录音") { model.sourceURL = bridge.recordingLibrary.entries.first { $0.id == recordingID }?.audioURL }
                            .disabled(recordingID == nil)
                    }
                    HStack {
                        Stepper("实时采集 \(model.duration) 秒", value: $model.duration, in: 10...600, step: 10)
                        Button("开始眼镜收音") { model.startLive(bridge: bridge) }
                            .disabled(!bridge.connected || bridge.activeSession != nil || bridge.assistant.active)
                    }
                    Toggle("分段完成后，使用本地 ASR 生成文字", isOn: $model.transcribe).disabled(model.enrolling || !asr.ready)
                    HStack {
                        Text("人物匹配阈值")
                        Slider(value: $model.threshold, in: 0.5...0.95, step: 0.01)
                        Text(model.threshold, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                    Text("默认人物匹配0.70、候选差距0.08、跨句聚类0.60、分段聚类0.65。文件最多30分钟；实时收音不保存原始文件，结果保留在内存供回听。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).disabled(model.running)
            }
            GroupBox("本轮结果") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(String(format: "音频 %.1f 秒 · %d 个片段 · %d 位临时说话人", model.receivedSeconds, model.turns.count, model.speakers.count))
                        Spacer()
                        if model.running { ProgressView().controlSize(.small); Button(model.stopping ? "正在结束…" : "停止") { model.stop() }.disabled(model.stopping) }
                        Button("停止回听") { model.stopPlayback() }
                        Button("导出结果…") { model.exportResult() }.disabled(model.running || model.turns.isEmpty)
                    }
                    if model.running { ProgressView(value: model.progress) }
                    Text(model.status).textSelection(.enabled)
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !model.running, model.receivedSeconds > 0 {
                        Text(String(format: "本轮耗时 %.2f 秒（含模型加载、实时收音等待与所选转写）；手机性能及整机功耗需另测。", model.elapsed))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.enrolling {
                        Text(String(format: "候选人声 %.2f 秒 · 一致样本 %.2f 秒 / 10 秒", assessment.totalSeconds, assessment.seconds))
                        Text(assessment.message).font(.callout)
                    }
                    ForEach(model.turns) { turn in
                        HStack(alignment: .top, spacing: 12) {
                            Text(turn.speaker).font(.headline).frame(width: 45)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(time(turn.beginMS)) – \(time(turn.endMS)) · 通道\(turn.sourceChannel) · \(turn.identityBasis)").monospacedDigit().font(.caption)
                                HStack {
                                    Text(model.people.first { $0.id == turn.personID }?.name ?? (turn.mixed ? "重叠语音" : "未匹配人物"))
                                    if let score = turn.score { Text(String(format: "相似度 %.3f", score)).foregroundStyle(.secondary) }
                                }.font(.callout)
                                if let text = turn.text, !text.isEmpty { Text(text).textSelection(.enabled) }
                            }
                            Spacer()
                            Button("回听") { model.play(turn) }.disabled(model.running)
                        }.padding(9).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(8)
            }
            if model.enrolling {
                GroupBox("确认并保存登记") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("更新人物", selection: $model.selectedPerson) {
                            Text("新建人物").tag(""); ForEach(model.people) { Text($0.name).tag($0.id) }
                        }.onChange(of: model.selectedPerson) { id in
                            if let person = model.people.first(where: { $0.id == id }) { model.name = person.name; model.isSelf = person.isSelf }
                        }
                        TextField("名字", text: $model.name)
                        Toggle("这是我的声音", isOn: $model.isSelf)
                        if !assessment.ready && !assessment.confirmationVectors.isEmpty {
                            Toggle("我确认这些人声全部由本人说出", isOn: $model.confirmed)
                        }
                        Button("保存声音档案") { model.saveEnrollment() }.disabled(!model.canSave)
                        Text("至少10秒、3段人声，且一致样本占80%；手动确认入口与手机一致。保存到本机钥匙串，不同步到手机。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(model.running)
                }
            } else if !model.speakers.isEmpty {
                GroupBox("为临时说话人绑定人物") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("说话人", selection: $model.bindingSpeaker) {
                            Text("选择 A / B / C…").tag(""); ForEach(model.speakers, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("人物", selection: $model.bindingPerson) { Text("新建人物").tag(""); ForEach(model.people) { Text($0.name).tag($0.id) } }
                        if model.bindingPerson.isEmpty { TextField("新人物名字", text: $model.bindingName) }
                        Toggle("记住这个声音，用于下次匹配", isOn: $model.rememberVoice)
                        Button("绑定本轮该说话人") { model.bindSpeaker() }.disabled(model.bindingSpeaker.isEmpty)
                        Text("只命名会更新本轮归属；勾选记住声音才保存特征。重叠语音不用于学习。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(model.running)
                }
            }
            GroupBox("本机声音档案") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.people.isEmpty { Text("尚未登记人物声音").foregroundStyle(.secondary) }
                    ForEach(model.people) { person in
                        HStack {
                            Text(person.name + (person.isSelf ? " · 我" : "")); Spacer()
                            Text("\(person.samples.count)个声音样本").foregroundStyle(.secondary)
                            Button("移除声音") { model.removeVoice(person.id) }.disabled(model.running || person.samples.isEmpty)
                        }
                    }
                }.padding(8)
            }
        }.task { model.loadPeople() }
    }
    private func time(_ ms: Int64) -> String { String(format: "%02d:%02d.%03d", ms / 60000, ms / 1000 % 60, ms % 1000) }
}

@MainActor
struct LocalASRPanel: View {
    @ObservedObject var model: LocalASRSettings
    var body: some View {
        GroupBox("本地 ASR 与断网兜底") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("AI 助手 ASR 路由", selection: $model.policy) { ForEach(DesktopASRPolicy.allCases) { Text($0.rawValue).tag($0) } }
                HStack {
                    Button(model.ready ? "准备／预热本地模型" : "下载并准备本地模型") { model.prepare() }.disabled(model.preparing)
                    Button("释放模型内存") { model.unload() }.disabled(model.preparing)
                    if model.preparing { ProgressView(value: model.progress).frame(width: 150) }
                }
                Text(model.status).font(.callout).textSelection(.enabled)
                Text("Whisper tiny 多语言；Core ML 编码器和解码器配置为 CPU + Neural Engine，前处理用 CPU，不启用 GPU。VAD 断句后按需转写；实际算子分配由 Core ML 决定。首次准备联网下载模型与分词器，准备后本地转写不上传音频。路由在新 ASR 轮次生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
