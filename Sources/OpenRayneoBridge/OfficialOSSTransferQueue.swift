// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Serializes awaited operations; timed-out native work remains separately cancellable.
actor OfficialOSSTransferQueue {
    static let shared = OfficialOSSTransferQueue()

    enum Priority: Int, Sendable { case normal, high }
    enum Source: String, Sendable { case unspecified, systemCloudSync, userInitiatedSync }
    enum Kind: Sendable { case upload, download }
    enum TimeoutPolicy: Sendable { case recordingUpload }
    struct Owner: Equatable, Sendable {
        let scope: String
        let generation: UUID
        let accountEpoch: UUID?
    }
    struct Progress: Sendable {
        fileprivate let callback: @Sendable () -> Void
        func received() { callback() }
    }
    struct Failure: LocalizedError, Sendable {
        enum Reason: Sendable { case idle, execution }
        let reason: Reason
        var errorDescription: String? {
            switch reason {
            case .idle: return "上传连续 90 秒未收到进度事件，传输结果未确认。"
            case .execution: return "音频传输等待已超过 30 分钟，传输结果未确认。"
            }
        }
    }
    struct Item: Sendable {
        let id: UUID
        let ownerScope: String
        let taskID: String?
        let kind: Kind
        let priority: Priority
        let source: Source
        let preemptionRequested: Bool
        let preemptions: Int
    }
    struct Snapshot: Sendable {
        let running: Item?
        let waiting: [Item]
        let completedPreemptions: Int
        var awaitingResult: [Item] = []
    }

    // Mutable only on this actor. Each attempt gets a fresh cancellable child task;
    // the original caller remains pending across confirmed preemption/requeue.
    private final class Entry {
        let id = UUID()
        let owner: Owner
        let taskID: String?
        let kind: Kind
        let priority: Priority
        var source: Source
        var cancelled = false
        var preemptionRequested = false
        var preemptions = 0
        var cancelAttempt: (@Sendable () -> Void)?
        var drainAttempt: (@Sendable () async -> Void)?
        var attemptID: UUID?
        var resultDelivered = false
        var timeoutDelivery: ((Failure) -> Void)?
        var fallbackTimer: Task<Void, Never>?
        var idleTimer: Task<Void, Never>?
        var timeoutPolicy: TimeoutPolicy?

        init(owner: Owner, taskID: String?, kind: Kind, priority: Priority, source: Source) {
            let trimmed = taskID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.taskID = trimmed?.isEmpty == false ? trimmed : nil
            self.owner = owner
            self.kind = kind; self.priority = priority; self.source = source
        }
        var item: Item {
            Item(id: id, ownerScope: owner.scope, taskID: taskID, kind: kind, priority: priority, source: source,
                 preemptionRequested: preemptionRequested, preemptions: preemptions)
        }
    }
    private struct Waiter {
        let entry: Entry
        let continuation: CheckedContinuation<Void, Error>
    }
    private var entries: [UUID: Entry] = [:]
    private var awaitingResult: [UUID: Entry] = [:]
    private struct NativeKey: Hashable { let ownerScope: String; let taskID: String }
    private var nativeOperations: [NativeKey: Entry] = [:]
    private var holder: Entry?
    private var waiting: [Waiter] = []
    private var completedPreemptions = 0

    func snapshot() -> Snapshot {
        Snapshot(running: holder?.item, waiting: waiting.map { $0.entry.item }, completedPreemptions: completedPreemptions,
                 awaitingResult: awaitingResult.values.map(\.item).sorted { $0.id.uuidString < $1.id.uuidString })
    }

    @discardableResult
    func promoteToUserInitiated(taskID: String, owner: Owner) -> Int {
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else { return 0 }
        var promoted = 0
        for entry in allEntries() where entry.owner.scope == owner.scope && entry.owner.accountEpoch == owner.accountEpoch
            && entry.taskID == taskID && entry.source == .systemCloudSync && !entry.cancelled {
            entry.source = .userInitiatedSync; promoted += 1
        }
        return promoted
    }

    func run<T: Sendable>(owner: Owner, taskID: String?, kind: Kind, priority: Priority = .normal, source: Source = .unspecified,
                         timeoutPolicy: TimeoutPolicy? = nil,
                         discardLateResult: @escaping @Sendable (T) -> Void = { _ in },
                         operation: @escaping @Sendable (Progress) async throws -> T) async throws -> T {
        let entry = Entry(owner: owner, taskID: taskID, kind: kind, priority: priority, source: source)
        entry.timeoutPolicy = timeoutPolicy
        let id = entry.id
        entries[id] = entry
        defer { entries[id] = nil }
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                guard !entry.cancelled else { throw CancellationError() }
                try await acquire(entry)
                if Task.isCancelled || entry.cancelled { release(id: id); throw CancellationError() }
                let result = await performAttempt(entry, discardLateResult: discardLateResult, operation: operation)
                let interrupted: Bool
                if case .failure(let error) = result {
                    interrupted = error is CancellationError || (error as? URLError)?.code == .cancelled
                }
                else { interrupted = false }
                let requeue = entry.preemptionRequested && interrupted && !entry.cancelled && !Task.isCancelled
                entry.preemptionRequested = false
                if requeue { entry.preemptions += 1; completedPreemptions += 1 }
                release(id: id)
                if Task.isCancelled || entry.cancelled {
                    if case .success(let value) = result { discardLateResult(value) }
                    throw CancellationError()
                }
                if requeue { continue }
                return try result.get()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func performAttempt<T: Sendable>(_ entry: Entry, discardLateResult: @escaping @Sendable (T) -> Void,
        operation: @escaping @Sendable (Progress) async throws -> T) async -> Result<T, Error> {
        let key = entry.taskID.map { NativeKey(ownerScope: entry.owner.scope, taskID: $0) }
        if let key, let previous = nativeOperations[key], previous.id != entry.id {
            cancel(id: previous.id)
            // Protect the frozen audio/resume files before reusing this task ID.
            if let drain = previous.drainAttempt { await drain() }
        }
        if entry.cancelled || Task.isCancelled { return .failure(CancellationError()) }
        let attemptID = UUID(), entryID = entry.id
        entry.attemptID = attemptID; entry.resultDelivered = false
        if let key { nativeOperations[key] = entry }
        let progress = Progress { Task { await self.noteProgress(id: entryID, attemptID: attemptID) } }
        return await withCheckedContinuation { continuation in
            entry.timeoutDelivery = { continuation.resume(returning: .failure($0)) }
            let attempt = Task {
                let result: Result<T, Error>
                do { result = .success(try await operation(progress)) }
                catch { result = .failure(error) }
                self.finishAttempt(entry, attemptID: attemptID, result: result, continuation: continuation,
                                   discardLateResult: discardLateResult)
            }
            entry.cancelAttempt = { attempt.cancel() }
            entry.drainAttempt = { await attempt.value }
            entry.fallbackTimer = Task {
                do { try await Task.sleep(for: .seconds(1800)) } catch { return }
                self.timeout(entry, attemptID: attemptID, reason: .execution)
            }
            resetIdle(entry, attemptID: attemptID)
            requestPreemption()
        }
    }

    private func finishAttempt<T: Sendable>(_ entry: Entry, attemptID: UUID, result: Result<T, Error>,
                                            continuation: CheckedContinuation<Result<T, Error>, Never>,
                                            discardLateResult: @Sendable (T) -> Void) {
        guard entry.attemptID == attemptID else { return }
        stopTimers(entry)
        entry.cancelAttempt = nil; entry.drainAttempt = nil; entry.attemptID = nil
        if let taskID = entry.taskID {
            let key = NativeKey(ownerScope: entry.owner.scope, taskID: taskID)
            if nativeOperations[key]?.id == entry.id { nativeOperations[key] = nil }
        }
        awaitingResult[entry.id] = nil
        let delivered = entry.resultDelivered
        entry.resultDelivered = true; entry.timeoutDelivery = nil
        if !delivered { continuation.resume(returning: result) }
        else if case .success(let value) = result { discardLateResult(value) }
    }

    private func noteProgress(id: UUID, attemptID: UUID) {
        guard let entry = entries[id], entry.attemptID == attemptID, !entry.resultDelivered,
              entry.kind == .upload else { return }
        resetIdle(entry, attemptID: attemptID)
    }

    private func resetIdle(_ entry: Entry, attemptID: UUID) {
        guard entry.timeoutPolicy == .recordingUpload, entry.taskID != nil else { return }
        entry.idleTimer?.cancel()
        entry.idleTimer = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            self.timeout(entry, attemptID: attemptID, reason: .idle)
        }
    }

    private func timeout(_ entry: Entry, attemptID: UUID, reason: Failure.Reason) {
        guard entry.attemptID == attemptID, !entry.resultDelivered else { return }
        entry.resultDelivered = true; stopTimers(entry)
        awaitingResult[entry.id] = entry
        let deliver = entry.timeoutDelivery; entry.timeoutDelivery = nil
        deliver?(Failure(reason: reason))
        // Like the Dart Future wrapper, this ends waiting without cancelling native work.
    }

    private func stopTimers(_ entry: Entry) {
        entry.fallbackTimer?.cancel(); entry.idleTimer?.cancel()
        entry.fallbackTimer = nil; entry.idleTimer = nil
    }

    func cancelUnfinished(id: UUID, ownerScope: String) {
        guard let entry = awaitingResult[id], entry.owner.scope == ownerScope else { return }
        cancel(id: entry.id)
    }

    func cancelTask(taskID: String, ownerScope: String) {
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in allEntries() where entry.taskID == taskID && entry.owner.scope == ownerScope { cancel(id: entry.id) }
    }

    func cancel(owner: Owner, source: Source, taskIDs: Set<String>? = nil) {
        for entry in allEntries() where entry.owner == owner && entry.source == source {
            if let taskIDs, !taskIDs.contains(entry.taskID ?? "") { continue }
            cancel(id: entry.id)
        }
    }

    func cancelAll(owner: Owner) async {
        let matching = allEntries().filter { $0.owner == owner }
        for entry in matching { cancel(id: entry.id) }
        for entry in matching { if let drain = entry.drainAttempt { await drain() } }
    }

    private func allEntries() -> [Entry] {
        Array(entries.merging(awaitingResult) { _, latest in latest }.values)
    }

    private func acquire(_ entry: Entry) async throws {
        try Task.checkCancellation()
        if holder == nil { holder = entry; return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled || entry.cancelled { continuation.resume(throwing: CancellationError()); return }
            let index = waiting.firstIndex { $0.entry.priority.rawValue < entry.priority.rawValue } ?? waiting.endIndex
            waiting.insert(Waiter(entry: entry, continuation: continuation), at: index)
            requestPreemption()
        }
    }

    private func requestPreemption() {
        guard waiting.contains(where: { $0.entry.priority == .high && !$0.entry.cancelled }),
              let holder, holder.priority == .normal, holder.taskID != nil,
              !holder.cancelled, !holder.preemptionRequested, let cancel = holder.cancelAttempt else { return }
        holder.preemptionRequested = true
        cancel()
    }

    private func cancel(id: UUID) {
        guard let entry = entries[id] ?? awaitingResult[id] else { return }
        entry.cancelled = true; entry.preemptionRequested = false
        entry.cancelAttempt?()
        if let index = waiting.firstIndex(where: { $0.entry.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func release(id: UUID) {
        guard holder?.id == id else { return }
        if waiting.isEmpty { holder = nil }
        else {
            let next = waiting.removeFirst()
            holder = next.entry; next.continuation.resume()
        }
    }
}
