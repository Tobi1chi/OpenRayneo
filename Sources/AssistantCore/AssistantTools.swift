// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AssistantToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public let isMutating: Bool
    public init(name: String, description: String, parametersJSON: String, isMutating: Bool) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON; self.isMutating = isMutating
    }
}

public struct AssistantToolCall: Codable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public protocol AssistantToolExecutor: Sendable {
    func definitions() async -> [AssistantToolDefinition]
    func context() async -> String
    func execute(_ call: AssistantToolCall) async throws -> String
}

public struct AssistantToolEvent: Codable, Sendable {
    public let timestamp: Date
    public let requestID: UUID
    public let phase: String
    public let call: AssistantToolCall
    public let result: String?
    public init(requestID: UUID, phase: String, call: AssistantToolCall, result: String? = nil) {
        timestamp = Date()
        self.requestID = requestID; self.phase = phase; self.call = call; self.result = result
    }
}

public struct AssistantRequestContext: Sendable {
    public let id: UUID
    public let prompts: PromptProfile
    public let dryRun: Bool
    public let onToolEvent: @Sendable (AssistantToolEvent) async throws -> Void
    public let onModelRequest: @Sendable (AssistantModelRequest) async throws -> Void
    public init(id: UUID = UUID(), prompts: PromptProfile = .defaultProfile, dryRun: Bool = false,
                onToolEvent: @escaping @Sendable (AssistantToolEvent) async throws -> Void = { _ in },
                onModelRequest: @escaping @Sendable (AssistantModelRequest) async throws -> Void = { _ in }) {
        self.id = id; self.prompts = prompts; self.dryRun = dryRun; self.onToolEvent = onToolEvent
        self.onModelRequest = onModelRequest
    }
}

public struct AssistantModelRequest: Codable, Sendable {
    public let requestID: UUID
    public let turn: Int
    public let bodyJSON: String
    public init(requestID: UUID, turn: Int, bodyJSON: String) {
        self.requestID = requestID; self.turn = turn; self.bodyJSON = bodyJSON
    }
}
