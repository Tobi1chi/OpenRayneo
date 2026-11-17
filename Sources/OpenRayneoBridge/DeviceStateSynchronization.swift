// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Refreshes independent device state once per connected transport generation.
final class DeviceStateSynchronization {
    struct Step {
        let name: String
        let confirmation: String
        let read: () throws -> [String: Any]
    }

    private let queue = DispatchQueue(label: "openrayneo.device-state-sync")
    private let lock = NSLock()
    private let isCurrent: (Int) -> Bool
    private let steps: () -> [Step]
    private var revision = 0
    private var generation: Int?
    private var completion: DispatchGroup?
    private var phase = "idle"
    private var startedAt: Date?
    private var finishedAt: Date?
    private var modules: [String: [String: Any]] = [:]

    init(isCurrent: @escaping (Int) -> Bool, steps: @escaping () -> [Step]) {
        self.isCurrent = isCurrent
        self.steps = steps
    }

    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["phase": phase, "fresh": phase == "ready", "generation": generation as Any? ?? NSNull(),
            "startedAt": startedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "finishedAt": finishedAt?.timeIntervalSince1970 as Any? ?? NSNull(), "modules": modules]
    }

    func connectionLost() {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        generation = nil
        completion = nil
        phase = "disconnected"
        for name in Array(modules.keys) { modules[name]?["stale"] = true }
    }

    @discardableResult
    func request(generation: Int, refresh: Bool = false) -> DispatchGroup {
        lock.lock()
        if self.generation == generation, let completion,
           !refresh || phase == "queued" || phase == "syncing" {
            lock.unlock()
            return completion
        }
        revision += 1
        let expectedRevision = revision
        let group = DispatchGroup(); group.enter()
        self.generation = generation
        completion = group
        phase = "queued"
        startedAt = Date(); finishedAt = nil
        for name in Array(modules.keys) { modules[name]?["stale"] = true }
        lock.unlock()
        queue.async { [weak self] in
            defer { group.leave() }
            self?.run(generation: generation, revision: expectedRevision)
        }
        return group
    }

    private func current(_ generation: Int, _ revision: Int) -> Bool {
        lock.lock(); let matches = self.generation == generation && self.revision == revision; lock.unlock()
        return matches && isCurrent(generation)
    }

    private func run(generation: Int, revision: Int) {
        guard current(generation, revision) else { return }
        lock.lock()
        guard self.revision == revision, self.generation == generation else { lock.unlock(); return }
        phase = "syncing"; lock.unlock()
        var failures = false
        for step in steps() {
            guard current(generation, revision) else { return }
            lock.lock()
            guard self.revision == revision, self.generation == generation else { lock.unlock(); return }
            var entry = modules[step.name] ?? [:]
            entry["phase"] = "syncing"; entry["generation"] = generation
            entry["startedAt"] = Date().timeIntervalSince1970
            entry.removeValue(forKey: "error")
            modules[step.name] = entry
            lock.unlock()
            let result: Result<[String: Any], Error>
            do { result = .success(try step.read()) } catch { result = .failure(error) }
            guard current(generation, revision) else { return }
            lock.lock()
            guard self.revision == revision, self.generation == generation else { lock.unlock(); return }
            entry["finishedAt"] = Date().timeIntervalSince1970
            switch result {
            case .success(let value):
                entry["phase"] = step.confirmation
                entry["value"] = value; entry["valueGeneration"] = generation
                entry["stale"] = false
            case .failure(let error):
                failures = true
                entry["phase"] = "failed"
                entry["error"] = (error as? BridgeError)?.message ?? error.localizedDescription
            }
            modules[step.name] = entry
            lock.unlock()
        }
        guard current(generation, revision) else { return }
        lock.lock()
        guard self.revision == revision, self.generation == generation else { lock.unlock(); return }
        phase = failures ? "partial" : "ready"
        finishedAt = Date()
        lock.unlock()
    }
}
