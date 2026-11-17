// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ASRAudioInputMode: Sendable {
    case realtime, buffered
    public var bufferLimitSeconds: Int {
        switch self { case .realtime: return 15; case .buffered: return 60 }
    }
    public var bufferLimitBytes: Int { 32000 * bufferLimitSeconds }
    public var drainTimeoutSeconds: Int {
        switch self { case .realtime: return 15; case .buffered: return 30 }
    }
    public var maximumFinishWaitSeconds: Int { drainTimeoutSeconds + 16 }
}

public struct ASRAudioStatistics: Encodable, Sendable {
    public let roundID: String
    public let receivedPCMBytes: Int
    public let sentPCMBytes: Int
    public let peakPendingPCMBytes: Int
    public let bufferLimitSeconds: Int
    public let finishSent: Bool
}

public struct Sentence: Codable, Sendable {
    public let id: String
    public let text: String
    public let roundID: String
    public let beginMS: Int?
    public let endMS: Int?
    public var sourceChannel: Int?
    public var identityBasis: String?
    public var personId: String?
    public var speaker: String?
    public var speakerTurns: [SpeakerAttribution]?
    public init(id: String, text: String, roundID: String, beginMS: Int? = nil, endMS: Int? = nil,
                sourceChannel: Int? = nil, identityBasis: String? = nil, personId: String? = nil, speaker: String? = nil,
                speakerTurns: [SpeakerAttribution]? = nil) {
        self.id = id; self.text = text; self.roundID = roundID; self.beginMS = beginMS; self.endMS = endMS
        self.sourceChannel = sourceChannel; self.identityBasis = identityBasis; self.personId = personId
        self.speaker = speaker; self.speakerTurns = speakerTurns
    }
}

public struct SpeakerAttribution: Codable, Sendable {
    public let beginMS: Int64
    public let endMS: Int64
    public let sourceChannel: Int
    public let personId: String?
    public let speaker: String
    public let identityBasis: String
    public let mixed: Bool
    public init(beginMS: Int64, endMS: Int64, sourceChannel: Int, personId: String?, speaker: String, identityBasis: String, mixed: Bool) {
        self.beginMS = beginMS; self.endMS = endMS; self.sourceChannel = sourceChannel; self.personId = personId
        self.speaker = speaker; self.identityBasis = identityBasis; self.mixed = mixed
    }
}

public struct DecisionInput: Codable, Sendable {
    public let previousSuccessfulSentences: [String]
    public let currentSentences: [String]
    public init(previous: [String], current: [String]) {
        previousSuccessfulSentences = previous; currentSentences = current
    }
    enum CodingKeys: String, CodingKey {
        case previousSuccessfulSentences = "previous_successful_sentences"
        case currentSentences = "current_sentences"
    }
}

public struct ChoiceResult: Codable, Sendable {
    public let choice: String
    public let probabilities: [String: Double]
    public let confidence: Double
    public let rawResponse: String
    public init(choice: String, probabilities: [String: Double], confidence: Double, rawResponse: String = "") {
        self.choice = choice; self.probabilities = probabilities; self.confidence = confidence; self.rawResponse = rawResponse
    }
}

public enum AssistantRoute: String, Codable, Sendable { case ignore, glassesHint = "glasses_hint", agentTask = "agent_task" }

public struct GeneratedReply: Codable, Sendable {
    public let text: String
    public let model: String
    public let rawResponse: String
    public init(text: String, model: String, rawResponse: String = "") {
        self.text = text; self.model = model; self.rawResponse = rawResponse
    }
}

public protocol DecisionProvider: Sendable {
    func completeness(_ input: DecisionInput) async throws -> ChoiceResult
    func route(_ input: DecisionInput) async throws -> ChoiceResult
    func completeness(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult
    func route(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult
}
public extension DecisionProvider {
    func completeness(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult { try await completeness(input) }
    func route(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult { try await route(input) }
}
public protocol ReplyProvider: Sendable {
    func reply(to input: DecisionInput, route: AssistantRoute) async throws -> GeneratedReply
    func reply(to input: DecisionInput, route: AssistantRoute, context: AssistantRequestContext) async throws -> GeneratedReply
}
public extension ReplyProvider {
    func reply(to input: DecisionInput, route: AssistantRoute, context: AssistantRequestContext) async throws -> GeneratedReply {
        try await reply(to: input, route: route)
    }
}

public struct AssistantThresholds: Sendable, Codable {
    public var completeProbability: Double
    public var completeConfidence: Double
    public var routeProbability: Double
    public var routeConfidence: Double
    public init(completeProbability: Double = 0.85, completeConfidence: Double = 0.8,
                routeProbability: Double = 0.7, routeConfidence: Double = 0.7) {
        self.completeProbability = completeProbability; self.completeConfidence = completeConfidence
        self.routeProbability = routeProbability; self.routeConfidence = routeConfidence
    }
}

public struct AssistantState: Sendable {
    public var running = false
    public var current: [String] = []
    public var previous: [String] = []
    public var phase = "尚未开始"
    public var completeness: ChoiceResult?
    public var routing: ChoiceResult?
    public var output = ""
    public var outputID: UUID?
    public var outputRoute: AssistantRoute?
    public var outputRoundID: String?
    public var outputPromptVersion: String?
    public var replyPending = false
    public var replyError: String?
    public var promptVersion = ""
    public var toolEvents: [AssistantToolEvent] = []
    public var error: String?
    public var logPath = ""
    public var pendingRequests = 0
    public init() {}
}

public struct AssistantFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
