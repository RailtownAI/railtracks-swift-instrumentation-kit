//
//  AgentRun.swift
//  RailtracksInstrumentationKit
//
//  Interval event representing one agent's run from start to finish.
//  Rendered in Instruments as a duration bar on the Agent Runs lane,
//  one swimlane per agent name. Use `RailtracksSignposts.begin(_:)` to
//  start the interval and keep the returned `AgentRunHandle`; pass it
//  back to `RailtracksSignposts.end(_:error:)` when the agent finishes.
//

import Foundation
import os.signpost

/// Metadata captured when an agent run begins. `name` is the agent's
/// display name (and the lane key in Instruments); the rest are
/// correlation identifiers that surface as columns on the interval row.
public struct AgentRun: Sendable, Codable, Equatable {
    public var name: String
    public var nodeId: String
    public var sessionId: String
    public var runId: String
    public var parentName: String

    public init(
        name: String,
        nodeId: String = "",
        sessionId: String = "",
        runId: String = "",
        parentName: String = ""
    ) {
        self.name = name
        self.nodeId = nodeId
        self.sessionId = sessionId
        self.runId = runId
        self.parentName = parentName
    }
}

/// Opaque handle returned by `RailtracksSignposts.begin(_:)`. Carries the
/// `OSSignpostIntervalState` that pairs the end event with its begin, plus
/// the agent `name` since the end-pattern needs it to populate the same
/// column the begin event set.
public struct AgentRunHandle: Sendable {
    let id: OSSignpostID
    let state: OSSignpostIntervalState
    let name: String
    /// The 0-based start-order index the SDK assigned within this run.
    /// Exposed for callers that want to log or correlate it.
    public let index: Int
    /// The 0-based ordinal of this run among all runs the process has
    /// begun an agent for, in first-seen order. Together with `index` it
    /// forms the lane-name prefix (`"<runOrdinal>-<index> name"`).
    public let runOrdinal: Int
}
