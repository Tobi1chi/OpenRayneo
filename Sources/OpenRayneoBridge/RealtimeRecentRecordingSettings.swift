// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Developer opt-in for keeping the latest realtime dual-mic capture as a WAV for offline speaker analysis.
/// The headless capture owner writes `RealtimeDiagnostics/latest.json`; this view only reads it.
@MainActor
struct RealtimeRecentRecordingSettings: View {
    static let key = "realtimeSaveLatestWAV"
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/RealtimeDiagnostics", isDirectory: true)
    }
    @AppStorage(Self.key) private var enabled = false
    @State private var latest: [String: Any]?

    var body: some View {
        GroupBox("实时双麦诊断录音") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动保存最近一轮实时双麦 WAV（下次开始收音生效）", isOn: $enabled)
                Text("“AI 助手”实时提示双麦与“声音与说话人”眼镜收音共用：按交给识别的格式保存（双路为双声道，16k或48k），只保留最近一轮完整录音，上一轮移到废纸篓；丢包或中断的一轮不覆盖上一份。录到的可能包含旁人声音，仅保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(summary).font(.caption).monospacedDigit().textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button("刷新") { reload() }
                    Button("在 Finder 中显示") { reveal() }.disabled(latest == nil)
                }
            }.padding(6)
        }
        .onAppear { reload() }
    }

    private var summary: String {
        guard let latest, let path = latest["path"] as? String else { return "尚无已保存的实时录音" }
        let seconds = latest["durationSeconds"] as? Double ?? 0
        let channels = latest["channels"] as? Int ?? 0, rate = latest["sampleRate"] as? Int ?? 0
        return String(format: "%.1f 秒 · %d 声道 · %d Hz · ", seconds, channels, rate) + (path as NSString).lastPathComponent
    }

    private func reload() {
        let index = Self.directory.appendingPathComponent("latest.json")
        guard let data = FileManager.default.contents(atPath: index.path) else { latest = nil; return }
        latest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func reveal() {
        guard let path = latest?["path"] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
