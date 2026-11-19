// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import Combine
import SwiftUI

/// One record in the daily review: a Mac-local library entry or a read-only phone replica record.
struct RecordingReviewItem: Identifiable, Sendable {
    enum Origin: Sendable, Equatable { case mac(UUID), phone(String) }

    /// Consecutive segments of one speaker, shown as a single block.
    struct Turn: Identifiable, Sendable {
        let id: String
        let speaker: String
        let isSelf: Bool
        let time: Date?
        let offset: Double
        var text: String
    }

    let id: String
    let origin: Origin
    var title: String
    var start: Date
    var end: Date?
    /// End of the time span used to place the record on calendar days; `openEnded` spans until now.
    var rangeEnd: Date
    var openEnded = false
    var duration: Double
    var kind: String
    var summary = ""
    var summaryStale = false
    var turns: [Turn] = []
    var paragraphs: [String] = []
    var audioPath: String?
    var audioPending = false
    var hasPhoneAudio = false
    var audioNote: String?
    var pending: String?
    var searchText = ""

    var isPhone: Bool { if case .phone = origin { return true }; return false }
    var macID: UUID? { if case .mac(let id) = origin { return id }; return nil }
    var preview: String {
        let candidates: [String] = [summary] + turns.prefix(3).map(\.text) + Array(paragraphs.prefix(3))
        for candidate in candidates {
            let lines = candidate.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            if let line = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { return line }
        }
        return ""
    }

    init(entry: RecordingLibraryEntry) {
        id = "mac:\(entry.id.uuidString)"; origin = .mac(entry.id)
        title = entry.title
        start = entry.startedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? entry.createdAt
        duration = entry.duration
        end = entry.duration > 0 ? start.addingTimeInterval(entry.duration) : nil
        rangeEnd = end ?? start
        kind = entry.sourceName
        summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        paragraphs = entry.transcript.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if entry.source == "lifelog" { audioNote = "AlwaysOn 原始分段，在录音开发者工具中恢复后可播放。" }
        else if !entry.available { audioNote = "音频文件不在这台 Mac 上。" }
        else if !entry.finalized { audioNote = "音频尚未完成保存。" }
        else { audioPath = entry.audioPath }
        searchText = [title, summary, entry.transcript, entry.tags.joined(separator: " ")].joined(separator: "\n")
    }

    init(phoneID: String, start: Date, title: String, kind: String) {
        id = "phone:\(phoneID)"; origin = .phone(phoneID)
        self.start = start; self.title = title; self.kind = kind; duration = 0; rangeEnd = start
    }
}

struct RecordingDaySummary: Sendable {
    let text: String
    let stale: Bool
    let createdAt: Double
}

struct PhoneReplicaSnapshot: Sendable {
    var exists = false
    var items: [RecordingReviewItem] = []
    var daySummaries: [String: RecordingDaySummary] = [:]
    var modified: Date?
    var error: String?
}

/// Reads the phone-authoritative replica written by RecordSyncController; never writes it.
enum PhoneReplicaReader {
    static func read(folder: URL) -> PhoneReplicaSnapshot {
        var snapshot = PhoneReplicaSnapshot()
        let file = folder.appendingPathComponent("replica.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return snapshot }
        snapshot.exists = true
        snapshot.modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            snapshot.error = "手机同步副本无法读取，原文件保持不变。"
            return snapshot
        }
        let people = root["people"] as? [String: [String: Any]] ?? [:]
        let audioPaths = root["audioPaths"] as? [String: String] ?? [:]
        for (id, row) in root["records"] as? [String: [String: Any]] ?? [:] {
            snapshot.items.append(item(id: id, row: row, people: people, audioPath: audioPaths[id]))
            for summary in row["summaries"] as? [[String: Any]] ?? [] where summary["kind"] as? String == "day_end" {
                guard let day = summary["day"] as? String, !day.isEmpty, let text = summary["text"] as? String, !text.isEmpty else { continue }
                let next = RecordingDaySummary(text: text, stale: summary["stale"] as? Bool == true, createdAt: summary["createdAt"] as? Double ?? 0)
                if let current = snapshot.daySummaries[day], (current.stale ? 1 : 0, -current.createdAt) <= (next.stale ? 1 : 0, -next.createdAt) { continue }
                snapshot.daySummaries[day] = next
            }
        }
        return snapshot
    }

    private static func item(id: String, row: [String: Any], people: [String: [String: Any]], audioPath: String?) -> RecordingReviewItem {
        let createdAt = row["createdAt"] as? Double ?? 0
        let mode = ["DAILY": "日常", "MEETING": "会议", "ENROLL": "声音登记"][row["mode"] as? String ?? ""]
        let source = ["REALTIME": "实时收音", "NATIVE": "眼镜录音", "ALWAYS_ON": "全天记录"][row["source"] as? String ?? ""]
        let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "手机记录"
        var item = RecordingReviewItem(phoneID: id, start: Date(timeIntervalSince1970: createdAt / 1000), title: title,
                                       kind: [mode, source].compactMap { $0 }.joined(separator: " · "))
        let endedAt = row["endedAt"] as? Double
        item.end = endedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        let segments = (row["segments"] as? [[String: Any]] ?? []).sorted { ($0["beginMS"] as? Double ?? 0) < ($1["beginMS"] as? Double ?? 0) }
        let samples = row["audioSamples"] as? Double ?? 0
        item.duration = samples > 0 ? samples / 16000 : endedAt.map { ($0 - createdAt) / 1000 } ?? (segments.last?["endMS"] as? Double ?? 0) / 1000

        let recordEnd = (row["summaries"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "record_end" }
            .max { ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0) }
        if let text = recordEnd?["text"] as? String, !text.isEmpty {
            item.summary = text; item.summaryStale = recordEnd?["stale"] as? Bool == true
        } else {
            item.summary = row["summary"] as? String ?? ""
        }
        item.summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        item.summaryStale = item.summaryStale || row["summaryStale"] as? Bool == true

        let anchors = (row["audioAnchors"] as? [[String: Any]] ?? []).compactMap { anchor -> (Double, Double)? in
            guard let offset = anchor["offsetMS"] as? Double, let received = anchor["receivedAt"] as? Double else { return nil }
            return (offset, received)
        }
        let speakerPeople = row["speakerPeople"] as? [String: String] ?? [:]
        var names = Set<String>()
        var lastSpoken = createdAt
        for segment in segments {
            let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = segment["speaker"] as? String ?? "未知"
            let basis = segment["identityBasis"] as? String ?? ""
            let explicitPerson = (segment["personId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A manual correction is authoritative, including "unknown"; only automatic segments fall back to the label map.
            var personID = basis == "manual" ? explicitPerson : explicitPerson ?? speakerPeople[speaker]
            var visited = Set<String>()
            while let current = personID, let merged = people[current]?["mergedInto"] as? String, !merged.isEmpty, visited.insert(current).inserted {
                personID = merged
            }
            let person = personID.flatMap { people[$0] }
            let isSelf = person?["self"] as? Bool == true || ["channel1_default_self", "native_wake_self"].contains(basis)
            let name = isSelf ? "我" : (person?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (speaker == "未知" || speaker.isEmpty || basis == "manual" ? "未知说话人" : "说话人 \(speaker)")
            names.insert(name)
            let begin = segment["beginMS"] as? Double ?? 0
            let timeline = segment["timelineAt"] as? Double ?? 0
            let wallClock = timeline > 0 ? timeline : anchors.filter { $0.0 <= begin }.max { $0.0 < $1.0 }.map { $0.1 + begin - $0.0 } ?? createdAt + begin
            let time = Date(timeIntervalSince1970: wallClock / 1000)
            let timelineEnd = segment["timelineEndAt"] as? Double ?? 0
            lastSpoken = max(lastSpoken, timelineEnd > 0 ? timelineEnd : wallClock + (segment["endMS"] as? Double ?? begin) - begin)
            if let last = item.turns.last, last.speaker == name, let lastTime = last.time, time.timeIntervalSince(lastTime) < 120 {
                let joiner = last.text.last.map { "。！？；，、.!?…".contains($0) } == true ? "" : " "
                item.turns[item.turns.count - 1].text += joiner + text
            } else {
                item.turns.append(.init(id: segment["id"] as? String ?? "\(item.turns.count)", speaker: name, isSelf: isSelf,
                                        time: time, offset: begin / 1000, text: text))
            }
        }
        item.audioPending = row["audioPending"] as? Bool == true
        // Contract §7: a missing endedAt continues to now only while audio is still being written; otherwise the last segment ends it.
        item.rangeEnd = Date(timeIntervalSince1970: (endedAt ?? lastSpoken) / 1000)
        item.openEnded = endedAt == nil && item.audioPending
        item.hasPhoneAudio = samples > 0 || row["audioId"] as? String != nil
        if let audioPath, FileManager.default.fileExists(atPath: audioPath) { item.audioPath = audioPath }
        if row["processingPending"] as? Bool == true { item.pending = "音频已保存，转写与说话人分析待补齐。" }
        item.searchText = ([title, item.summary] + item.turns.map(\.text) + Array(names)).joined(separator: "\n")
        return item
    }
}

/// Audio playback for the review page, kept apart so position ticks only redraw views that observe it.
@MainActor
final class RecordingReviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var failure: String?
    var scrubbing = false
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func toggle(id: String, path: String) {
        if playingID == id, let player {
            if player.isPlaying { player.pause(); playing = false; ticker?.cancel() } else { player.play(); playing = true; tick() }
            return
        }
        guard load(id: id, path: path) else { return }
        player?.play(); playing = true; tick()
    }

    func seek(id: String, path: String, to seconds: Double, play: Bool = false) {
        if playingID != id { guard load(id: id, path: path) else { return } }
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        position = player.currentTime
        if play, !player.isPlaying { player.play(); playing = true; tick() }
    }

    func stop() {
        ticker?.cancel(); ticker = nil
        player?.stop(); player = nil
        playingID = nil; playing = false; position = 0; duration = 0; failure = nil
    }

    private func load(id: String, path: String) -> Bool {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.delegate = self; player.prepareToPlay()
            self.player = player; playingID = id; duration = player.duration
            return true
        } catch { failure = "无法播放这段音频：\(error.localizedDescription)"; return false }
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                if !self.scrubbing { self.position = player.currentTime }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.ticker?.cancel(); self.playing = false; player.currentTime = 0; self.position = 0
        }
    }
}

@MainActor
final class RecordingReviewModel: ObservableObject {
    enum Period: String, CaseIterable, Identifiable { case day = "按天", month = "按月"; var id: String { rawValue } }

    struct DaySection: Identifiable {
        let day: Date
        let items: [RecordingReviewItem]
        var id: Date { day }
    }

    let player = RecordingReviewPlayer()
    @Published private(set) var phone = PhoneReplicaSnapshot()
    @Published private(set) var loaded = false
    /// Merged Mac + phone items, newest first; rebuilt only when the library or the replica changes.
    @Published private(set) var items: [RecordingReviewItem] = []
    @Published private(set) var sections: [DaySection] = []
    @Published private(set) var visibleCount = 0
    @Published private(set) var selectionID: String?
    @Published var period: Period = .month { didSet { periodChanged() } }
    @Published var anchor = Date() { didSet { periodChanged() } }
    @Published var query = "" { didSet { rebuildSections() } }
    @Published private(set) var fetchingID: String?
    @Published var message: String?
    private weak var library: RecordingLibraryModel?
    private var librarySubscription: AnyCancellable?
    private var fetchTask: Task<Void, Never>?
    private var fetchedAudio: [String: String] = [:]
    private var reloadGeneration = 0
    private var calendar: Calendar { .current }

    var selected: RecordingReviewItem? { items.first { $0.id == selectionID } }
    var interval: DateInterval { calendar.dateInterval(of: period == .day ? .day : .month, for: anchor)! }
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var showsCurrentPeriod: Bool { let range = interval, now = Date(); return now >= range.start && now < range.end }

    /// Opens the page: follows library changes, reads the replica, then selects the record another page asked for
    /// (a one-shot request) or the newest one.
    func open(library: RecordingLibraryModel) async {
        self.library = library
        librarySubscription = library.$entries.combineLatest(library.$activeCloudOwnerScope)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildItems() }
        rebuildItems()
        await reload()
        let requested = library.reviewRequestID.map(RecordingReviewItem.Origin.mac)
        library.reviewRequestID = nil
        if let item = items.first(where: { $0.origin == requested }) ?? items.first {
            anchor = item.start
            select(item)
        }
    }

    func close() {
        fetchTask?.cancel(); fetchTask = nil; fetchingID = nil
        player.stop()
        librarySubscription = nil
    }

    func reload() async {
        let folder = RecordSyncController.directory
        let modified = (try? folder.appendingPathComponent("replica.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard !loaded || modified != phone.modified else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let snapshot = await Task.detached(priority: .userInitiated) { PhoneReplicaReader.read(folder: folder) }.value
        guard generation == reloadGeneration else { return }
        phone = snapshot; loaded = true
        rebuildItems()
    }

    /// The only selection path: Mac picks are mirrored into the library so export and Finder act on the shown entry.
    func select(_ item: RecordingReviewItem) {
        guard selectionID != item.id else { return }
        if player.playingID != item.id { player.stop() }
        message = nil
        selectionID = item.id
        if let id = item.macID, library?.selectedID != id { library?.selectedID = id }
    }

    func step(_ delta: Int) {
        anchor = calendar.date(byAdding: period == .day ? .day : .month, value: delta, to: anchor) ?? anchor
    }

    func daySummary(_ day: Date) -> RecordingDaySummary? { phone.daySummaries[Self.key(day)] }

    func fetchAudio(_ item: RecordingReviewItem, bridge: DesktopBridge) {
        guard case .phone(let recordID) = item.origin, fetchingID == nil else { return }
        fetchingID = item.id; message = nil
        fetchTask = Task {
            defer { if !Task.isCancelled { fetchingID = nil } }
            do {
                // Existing on-demand route: the service downloads /v1/sync/audio once and caches the WAV.
                // Its sync queue may be mid-exchange, so allow a long wait.
                let response = try await bridge.request("/v1/records/audio", body: ["recordId": recordID], timeout: 90)
                guard !Task.isCancelled else { return }
                guard let path = response["audioPath"] as? String else { message = "本机服务没有返回音频位置。"; return }
                fetchedAudio[recordID] = path
                rebuildItems()
            } catch {
                guard !Task.isCancelled else { return }
                message = "没能从手机获取音频：\(error.localizedDescription)。手机同步正忙时常会超时，稍后重试通常即可。"
            }
        }
    }

    private func rebuildItems() {
        guard let library else { return }
        let phoneItems = phone.items.map { item -> RecordingReviewItem in
            guard item.audioPath == nil, case .phone(let id) = item.origin, let path = fetchedAudio[id] else { return item }
            var ready = item; ready.audioPath = path; return ready
        }
        items = (library.visibleEntries.map(RecordingReviewItem.init(entry:)) + phoneItems).sorted { $0.start > $1.start }
        rebuildSections()
    }

    private func end(of item: RecordingReviewItem) -> Date {
        max(item.openEnded ? Date() : item.rangeEnd, item.start.addingTimeInterval(1))
    }

    /// Records sit on every calendar day their span overlaps, so all-day phone records show on each day they cover.
    private func rebuildSections() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var days: [Date: [RecordingReviewItem]] = [:]
        if !text.isEmpty {
            let matches = items.filter { $0.searchText.localizedCaseInsensitiveContains(text) }
            for item in matches { days[calendar.startOfDay(for: item.start), default: []].append(item) }
            visibleCount = matches.count
        } else {
            let range = interval
            var count = 0
            for item in items {
                let until = min(end(of: item), range.end)
                guard item.start < range.end, until > range.start else { continue }
                count += 1
                var day = calendar.startOfDay(for: max(item.start, range.start))
                while day < until {
                    days[day, default: []].append(item)
                    day = calendar.date(byAdding: .day, value: 1, to: day)!
                }
            }
            for key in phone.daySummaries.keys {
                if let day = Self.date(fromKey: key), day >= range.start, day < range.end, days[day] == nil { days[day] = [] }
            }
            visibleCount = count
        }
        sections = days.map { DaySection(day: $0.key, items: $0.value) }.sorted { $0.day > $1.day }
    }

    /// Changing the day or month moves the detail to that period's newest record when the old one is out of view.
    private func periodChanged() {
        rebuildSections()
        let shown = sections.flatMap(\.items)
        guard !shown.contains(where: { $0.id == selectionID }), let first = shown.first else { return }
        select(first)
    }

    static func key(_ day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Small date and duration labels for the review page, in the app's Chinese UI style.
private enum ReviewFormat {
    static func weekday(_ date: Date) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: date) - 1]
    }
    static func monthDay(_ date: Date) -> String {
        let calendar = Calendar.current, parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year != calendar.component(.year, from: Date()) ? "\(parts.year ?? 0)年" : ""
        return "\(year)\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
    static func relativeDay(_ date: Date) -> String? {
        Calendar.current.isDateInToday(date) ? "今天" : Calendar.current.isDateInYesterday(date) ? "昨天" : nil
    }
    static func clock(_ date: Date, seconds: Bool = false) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return seconds ? String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
            : String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    static func span(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分钟" }
        return total % 3600 / 60 == 0 ? "\(total / 3600) 小时" : "\(total / 3600) 小时 \(total % 3600 / 60) 分"
    }
    static func playhead(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@MainActor
struct RecordingReviewPanel: View {
    @ObservedObject var library: RecordingLibraryModel
    let bridge: DesktopBridge
    let serviceRunning: Bool
    @StateObject private var review = RecordingReviewModel()
    @State private var expandedSummaries = Set<Date>()
    @State private var exportingID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            timeline.frame(width: 300)
            detailColumn(review.selected)
        }
        .task {
            library.stopPlayback()
            await review.open(library: library)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await review.reload()
            }
        }
        .onDisappear { review.close() }
        .onChange(of: library.busy) { busy in
            guard !busy, let id = exportingID else { return }
            exportingID = nil
            if review.selected?.macID == id { review.message = library.status }
        }
    }

    // MARK: Timeline column

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if review.sections.isEmpty { emptyTimeline }
                    ForEach(review.sections) { section in
                        Section {
                            if let summary = review.daySummary(section.day) { daySummaryCard(summary, day: section.day) }
                            ForEach(section.items) { row($0, day: section.day) }
                        } header: { dayHeader(section) }
                    }
                }.padding(.bottom, 12)
            }
            replicaFooter
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("范围", selection: $review.period) {
                    ForEach(RecordingReviewModel.Period.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 116)
                Spacer()
                Button("今天") { review.anchor = Date() }.controlSize(.small)
                    .disabled(review.showsCurrentPeriod || review.searching)
                Button { library.refresh(); Task { await review.reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .medium))
                }.controlSize(.small).help("重新读取本机录音和手机副本").disabled(library.busy)
            }
            HStack(spacing: 2) {
                stepButton("chevron.left", help: review.period == .day ? "前一天" : "上个月") { review.step(-1) }
                VStack(spacing: 2) {
                    Text(periodTitle).font(.system(size: 14.5, weight: .semibold)).monospacedDigit()
                    Text(review.searching ? "搜索全部日期" : periodSubtitle)
                        .font(.system(size: 11)).foregroundStyle(Token.descriptionForeground)
                }.frame(maxWidth: .infinity)
                stepButton("chevron.right", help: review.period == .day ? "后一天" : "下个月") { review.step(1) }
            }.padding(6).opacity(review.searching ? 0.45 : 1).disabled(review.searching)
                .background(Token.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Token.cardBorder))
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Token.descriptionForeground)
                TextField("搜索标题、摘要和原话", text: $review.query).textFieldStyle(.plain).font(.system(size: 12.5))
                if review.searching {
                    Button { review.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Token.descriptionForeground).help("清除搜索")
                }
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Token.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Token.cardBorder))
        }
    }

    private var periodTitle: String {
        if review.period == .month {
            let parts = Calendar.current.dateComponents([.year, .month], from: review.anchor)
            return "\(parts.year ?? 0)年\(parts.month ?? 0)月"
        }
        return ReviewFormat.monthDay(review.anchor)
    }

    private var periodSubtitle: String {
        let records = review.visibleCount == 0 ? "没有录音" : "\(review.visibleCount) 条录音"
        guard review.period == .day else { return records }
        return [ReviewFormat.relativeDay(review.anchor), ReviewFormat.weekday(review.anchor), records].compactMap { $0 }.joined(separator: " · ")
    }

    private func stepButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Token.iconForeground).help(help)
    }

    private func dayHeader(_ section: RecordingReviewModel.DaySection) -> some View {
        let relative = ReviewFormat.relativeDay(section.day)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(relative ?? ReviewFormat.monthDay(section.day)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Token.foreground)
            Text(relative == nil ? ReviewFormat.weekday(section.day) : "\(ReviewFormat.monthDay(section.day)) \(ReviewFormat.weekday(section.day))")
                .font(.system(size: 11.5)).foregroundStyle(Token.descriptionForeground)
            Spacer()
            if !section.items.isEmpty {
                Text("\(section.items.count) 条").font(.system(size: 11)).foregroundStyle(Token.sideBarSectionHeaderForeground)
            }
        }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading).background(Token.pageBackground)
    }

    private func daySummaryCard(_ summary: RecordingDaySummary, day: Date) -> some View {
        let expanded = expandedSummaries.contains(day)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote").font(.system(size: 10.5, weight: .semibold))
                Text("日总结").font(.system(size: 11.5, weight: .semibold))
                if summary.stale { Text("· 待手机刷新").font(.system(size: 11)).foregroundStyle(Token.descriptionForeground) }
                Spacer()
            }.foregroundStyle(Token.badgeForeground)
            Text(summary.text).font(.system(size: 12.5)).lineSpacing(2.5).foregroundStyle(Token.foreground)
                .lineLimit(expanded ? nil : 4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if summary.text.count > 90 {
                Button(expanded ? "收起" : "展开全文") {
                    if expanded { expandedSummaries.remove(day) } else { expandedSummaries.insert(day) }
                }.buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Token.textLinkForeground)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Token.badgeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 6)
    }

    private func row(_ item: RecordingReviewItem, day: Date) -> some View {
        let selected = item.id == review.selectionID
        let preview = item.preview
        let continued = item.start < day
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { review.select(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(continued ? "续" : ReviewFormat.clock(item.start)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(selected ? Token.foreground : Token.descriptionForeground).frame(width: 38, alignment: .leading)
                    .help(continued ? "从 \(ReviewFormat.monthDay(item.start)) \(ReviewFormat.clock(item.start)) 延续到这一天" : "")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Token.foreground).lineLimit(1)
                    if !preview.isEmpty {
                        Text(preview).font(.system(size: 12)).foregroundStyle(Token.descriptionForeground).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        SourceBadge(phone: item.isPhone)
                        if item.duration > 0 {
                            Text(ReviewFormat.span(item.duration)).font(.system(size: 11)).foregroundStyle(Token.descriptionForeground)
                        }
                        PlayingMark(player: review.player, id: item.id)
                    }.padding(.top, 1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .background(selected ? Token.cardBackground : .clear, in: shape)
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(Token.listActiveSelectionIndicator).frame(width: 3, height: 16).padding(.leading, 3) }
                }
                .overlay(shape.strokeBorder(selected ? Token.cardBorder : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var emptyTimeline: some View {
        if !review.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
        } else if review.items.isEmpty {
            ReviewEmptyState(icon: "waveform", title: "还没有录音",
                             detail: "眼镜录音、导入的音频和从手机同步的记录，会按日期出现在这里。")
        } else if review.searching {
            ReviewEmptyState(icon: "magnifyingglass", title: "没有匹配的录音", detail: "换个关键词，或清除搜索回到按日期浏览。")
        } else {
            let earlier = review.items.first { $0.start < review.interval.start } ?? review.items.first
            ReviewEmptyState(icon: "calendar", title: review.period == .day ? "这一天没有录音" : "这个月没有录音",
                             detail: earlier.map { "最近一条在 \(ReviewFormat.relativeDay($0.start) ?? ReviewFormat.monthDay($0.start))。" } ?? "",
                             action: earlier.map { item in ("前往最近的记录", { review.anchor = item.start; review.select(item) }) })
        }
    }

    private var replicaFooter: some View {
        let phone = review.phone
        let text: String
        if let error = phone.error { text = error }
        else if !phone.exists { text = "手机记录尚未同步到这台 Mac。在 Agent 工作台配置手机同步后，会与本机录音一起按时间显示。" }
        else {
            let updated = phone.modified.map { " · 更新于 \(ReviewFormat.relativeDay($0) ?? ReviewFormat.monthDay($0)) \(ReviewFormat.clock($0))" } ?? ""
            text = "手机副本 \(phone.items.count) 条\(updated) · 以手机为准，只读"
        }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: phone.exists && phone.error == nil ? "iphone" : "iphone.slash").font(.system(size: 11.5)).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).foregroundStyle(phone.error == nil ? Token.descriptionForeground : Token.errorForeground)
            .padding(.top, 10).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Token.widgetBorder).frame(height: 1) }
    }

    // MARK: Detail column

    private func detailColumn(_ item: RecordingReviewItem?) -> some View {
        Group {
            if let item {
                detail(item)
            } else {
                ReviewEmptyState(icon: "text.bubble", title: "选择一条录音",
                                 detail: "左侧按日期列出手机和 Mac 的录音。选中后，在这里回看摘要和按说话人整理的对话。")
                    .frame(maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Token.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Token.cardBorder))
    }

    private func detail(_ item: RecordingReviewItem) -> some View {
        let busyHere = library.busy && item.macID != nil && library.activeEntryID == item.macID
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SourceBadge(phone: item.isPhone)
                    Text(detailLine(item)).font(.system(size: 12)).foregroundStyle(Token.descriptionForeground).lineLimit(1)
                    Spacer(minLength: 8)
                    if let id = item.macID {
                        Button { onShownEntry(id) { exportingID = id; library.exportWAV() } } label: { Image(systemName: "square.and.arrow.up") }
                            .help("导出音频").accessibilityLabel("导出音频")
                        Button { onShownEntry(id) { library.reveal() } } label: { Image(systemName: "folder") }
                            .help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                    }
                }.controlSize(.small).disabled(library.busy || item.audioPath == nil)
                Text(item.title).font(.system(size: 20, weight: .semibold)).tracking(-0.2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = item.audioPath {
                    ReviewPlayerBar(player: review.player, id: item.id, path: path, duration: item.duration)
                } else {
                    unavailablePlayer(item)
                }
                if busyHere {
                    HStack(spacing: 10) {
                        ProgressView(value: library.progress).controlSize(.small)
                        Button("取消") { library.cancel() }.controlSize(.small)
                    }
                } else if let message = review.message, !message.isEmpty {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(Token.descriptionForeground).textSelection(.enabled).lineLimit(3)
                }
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            Rectangle().fill(Token.widgetBorder).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    summarySection(item).padding(.bottom, 10)
                    transcriptSection(item)
                }.padding(.horizontal, 24).padding(.vertical, 22).frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.id(item.id)
        }
    }

    /// Export and Finder use the library's selection; make sure it is the entry on screen first.
    private func onShownEntry(_ id: UUID, _ action: () -> Void) {
        if library.selectedID != id { library.selectedID = id }
        action()
    }

    private func detailLine(_ item: RecordingReviewItem) -> String {
        var range = ReviewFormat.clock(item.start)
        if let end = item.end, end > item.start {
            range += "–" + (Calendar.current.isDate(end, inSameDayAs: item.start) ? ReviewFormat.clock(end) : "\(ReviewFormat.monthDay(end)) \(ReviewFormat.clock(end))")
        }
        let day = ReviewFormat.relativeDay(item.start).map { "\($0) " } ?? ""
        return ["\(day)\(ReviewFormat.monthDay(item.start)) \(ReviewFormat.weekday(item.start))", range,
                item.duration > 0 ? ReviewFormat.span(item.duration) : nil, item.kind.isEmpty ? nil : item.kind]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func unavailablePlayer(_ item: RecordingReviewItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Token.disabledForeground)
                .frame(width: 32, height: 32).background(Token.buttonSecondaryBackground, in: Circle())
            Text(audioUnavailableText(item)).font(.system(size: 12)).foregroundStyle(Token.descriptionForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if item.isPhone, item.hasPhoneAudio, !item.audioPending, serviceRunning {
                Button(review.fetchingID == item.id ? "正在获取…" : "从手机获取") { review.fetchAudio(item, bridge: bridge) }
                    .controlSize(.small).disabled(review.fetchingID != nil)
            }
        }.padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(Token.inputBackground, in: Capsule())
    }

    private func audioUnavailableText(_ item: RecordingReviewItem) -> String {
        guard item.isPhone else { return item.audioNote ?? "这条录音没有可播放的音频。" }
        if !item.hasPhoneAudio { return "这条手机记录没有保存原音频。" }
        if item.audioPending { return "手机仍在写入这段音频，稍后再获取。" }
        return serviceRunning ? "音频保存在手机上，需要时按需获取。" : "音频保存在手机上。启动本机服务并连通手机同步后可按需获取。"
    }

    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 11.5, weight: .semibold)).tracking(0.4).foregroundStyle(Token.descriptionForeground)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Token.sideBarSectionHeaderForeground) }
        }
    }

    private func summarySection(_ item: RecordingReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("摘要")
            if item.summary.isEmpty {
                Text(item.isPhone ? "手机还没有为这条记录整理摘要。" : "还没有摘要。可在录音开发者工具中转写并生成。")
                    .font(.system(size: 13)).foregroundStyle(Token.descriptionForeground)
            } else {
                Text(item.summary).font(.system(size: 14)).lineSpacing(5).foregroundStyle(Token.foreground)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Token.textCodeBlockBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if item.summaryStale {
                Label("说话人或原文有更正，摘要等待手机重新整理。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5)).foregroundStyle(Token.bannerWarningForeground)
            }
        }
    }

    @ViewBuilder private func transcriptSection(_ item: RecordingReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.turns.isEmpty {
                sectionLabel("对话", trailing: "\(Set(item.turns.map(\.speaker)).count) 位说话人 · \(item.turns.count) 段")
            } else {
                sectionLabel("转写", trailing: item.paragraphs.isEmpty ? nil : "\(item.paragraphs.count) 句")
            }
            if let pending = item.pending {
                Label(pending, systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(Token.descriptionForeground)
            }
            if item.turns.isEmpty && item.paragraphs.isEmpty {
                Text(item.isPhone ? "这条记录还没有转写内容。" : "还没有转写。可在录音开发者工具中转写这段音频。")
                    .font(.system(size: 13)).foregroundStyle(Token.descriptionForeground)
            }
        }
        ForEach(item.turns) { turn in turnView(turn, item: item) }
        ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { _, paragraph in
            Text(paragraph).font(.system(size: 14)).lineSpacing(5).foregroundStyle(Token.foreground)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func turnView(_ turn: RecordingReviewItem.Turn, item: RecordingReviewItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(initial(turn.speaker)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(turn.isSelf ? Token.badgeForeground : Token.iconForeground)
                .frame(width: 28, height: 28)
                .background(turn.isSelf ? Token.badgeBackground : Token.cardIconBackground, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(turn.speaker).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Token.foreground)
                    if let time = turn.time {
                        if let path = item.audioPath {
                            Button { review.player.seek(id: item.id, path: path, to: turn.offset, play: true) } label: {
                                Text(ReviewFormat.clock(time, seconds: true)).font(.system(size: 11)).monospacedDigit()
                            }.buttonStyle(.plain).foregroundStyle(Token.textLinkForeground).help("从这里播放")
                        } else {
                            Text(ReviewFormat.clock(time, seconds: true)).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Token.descriptionForeground)
                        }
                    }
                }
                Text(turn.text).font(.system(size: 14)).lineSpacing(4.5).foregroundStyle(Token.foreground)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func initial(_ name: String) -> String {
        if name == "未知说话人" { return "?" }
        if name.hasPrefix("说话人 ") { return String(name.dropFirst(4).prefix(2)) }
        return String(name.prefix(1)).uppercased()
    }
}

/// Play/pause and scrubber; the only view redrawn by playback ticks.
private struct ReviewPlayerBar: View {
    @ObservedObject var player: RecordingReviewPlayer
    let id: String
    let path: String
    let duration: Double

    var body: some View {
        let active = player.playingID == id
        let total = active && player.duration > 0 ? player.duration : duration
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { player.toggle(id: id, path: path) } label: {
                    Image(systemName: active && player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Token.buttonForeground)
                        .frame(width: 32, height: 32).background(Token.buttonBackground, in: Circle())
                }.buttonStyle(.plain).help(active && player.playing ? "暂停" : "播放")
                Text(ReviewFormat.playhead(active ? player.position : 0)).font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Token.descriptionForeground)
                Slider(value: Binding(get: { active ? player.position : 0 }, set: { player.seek(id: id, path: path, to: $0) }),
                       in: 0...max(total, 0.1), onEditingChanged: { player.scrubbing = $0 })
                    .controlSize(.small)
                Text(ReviewFormat.playhead(total)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Token.descriptionForeground)
            }.padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                .background(Token.inputBackground, in: Capsule())
            if let failure = player.failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(Token.errorForeground).lineLimit(2)
            }
        }
    }
}

private struct PlayingMark: View {
    @ObservedObject var player: RecordingReviewPlayer
    let id: String
    var body: some View {
        if player.playingID == id, player.playing {
            Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(Token.statusIndicatorActive)
        }
    }
}

private struct SourceBadge: View {
    let phone: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: phone ? "iphone" : "laptopcomputer").font(.system(size: 8.5, weight: .semibold))
            Text(phone ? "手机" : "Mac").font(.system(size: 10.5, weight: .semibold))
        }.padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(phone ? Token.badgeForeground : Token.badgeInactiveForeground)
            .background(phone ? Token.badgeBackground : Token.badgeInactiveBackground, in: Capsule())
    }
}

private struct ReviewEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(Token.disabledForeground).padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Token.foreground)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Token.descriptionForeground)
                    .multilineTextAlignment(.center).frame(maxWidth: 280).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0, action: action.1).controlSize(.small).padding(.top, 6)
            }
        }.padding(.horizontal, 20).padding(.vertical, 40).frame(maxWidth: .infinity)
    }
}
