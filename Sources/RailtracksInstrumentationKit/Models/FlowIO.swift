//
//  Events.swift
//  RailtracksInstrumentationKit
//
//  Value-type events the producer constructs and hands to
//  `RailtracksSignposts.emit(_:)`. Each event mirrors the field list of
//  one `<os-signpost-point-schema>` in the Instruments package — the
//  schema's pattern matcher is what dictates the property names and types.
//

import Foundation

/// One point event per logical input/output message attributed to a tool
/// or agent. `content` may contain newlines/tabs/backslashes — the
/// emitter sanitizes them so the signpost message stays single-line.
public struct FlowIO: Sendable, Codable, Equatable {
    public var nodeId: String
    public var sessionId: String
    public var runId: String
    public var messageId: String
    public var source: String
    public var direction: String
    public var role: String
    public var model: String
    public var provider: String
    public var cost: Double
    public var latency: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var displayRole: String
    public var toolName: String
    public var content: String
    /// When the owning node started running. Producer-supplied so Tool I/O
    /// rows can be ordered chronologically. Any monotonic scale works
    /// (epoch seconds or seconds-since-run-start).
    public var startTime: TimeInterval

    public init(
        nodeId: String,
        sessionId: String,
        runId: String,
        messageId: String,
        source: String,
        direction: String,
        role: String,
        model: String = "",
        provider: String = "",
        cost: Double = 0,
        latency: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        displayRole: String,
        toolName: String,
        content: String,
        startTime: TimeInterval = 0
    ) {
        self.nodeId = nodeId
        self.sessionId = sessionId
        self.runId = runId
        self.messageId = messageId
        self.source = source
        self.direction = direction
        self.role = role
        self.model = model
        self.provider = provider
        self.cost = cost
        self.latency = latency
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.displayRole = displayRole
        self.toolName = toolName
        self.content = content
        self.startTime = startTime
    }
}
