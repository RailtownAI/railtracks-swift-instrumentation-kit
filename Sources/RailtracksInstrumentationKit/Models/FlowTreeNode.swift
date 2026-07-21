//
//  FlowTreeNode.swift
//  RailtracksInstrumentationKit
//
//  Created by Fabricio Sperotto Sffair on 27/05/26.
//

import Foundation

/// One point event per leaf node in the flow hierarchy (and per non-leaf
/// agent, since agents carry their own llm_details that wouldn't roll up
/// otherwise — see the schema header for skip rules).
///
/// `ancestors` is the chain of ancestor names from root down to the
/// immediate parent. The wire format's `a0`..`a4` slots are forward-filled
/// from `ancestors`: empty slots past `ancestors.count` get `name` so
/// partial-depth trees don't render anonymous "" sub-rows in the
/// aggregation. `depth` is derived from `ancestors.count`; `parentName`
/// from `ancestors.last`.
public struct FlowTreeNode: Sendable, Codable, Equatable {
    public var nodeId: String
    public var sessionId: String
    public var runId: String
    public var nodeType: NodeType
    public var model: String
    public var provider: String
    public var cost: Double
    public var latency: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var error: Bool
    public var ancestors: [String]
    public var name: String
    /// When this node actually started running. Producer-supplied so rows
    /// can be ordered chronologically in Instruments (the implicit signpost
    /// timestamp reflects emit time, useless when a whole run is replayed at
    /// once). Any monotonic scale works — epoch seconds or seconds-since-
    /// run-start; sorting only needs consistency.
    public var startTime: TimeInterval

    public init(
        nodeId: String,
        sessionId: String,
        runId: String,
        nodeType: NodeType,
        model: String = "",
        provider: String = "",
        cost: Double = 0,
        latency: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        error: Bool = false,
        ancestors: [String] = [],
        name: String,
        startTime: TimeInterval = 0
    ) {
        self.nodeId = nodeId
        self.sessionId = sessionId
        self.runId = runId
        self.nodeType = nodeType
        self.model = model
        self.provider = provider
        self.cost = cost
        self.latency = latency
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.error = error
        self.ancestors = ancestors
        self.name = name
        self.startTime = startTime
    }
}
