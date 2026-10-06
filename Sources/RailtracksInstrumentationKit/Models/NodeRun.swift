//
//  NodeRun.swift
//  RailtracksInstrumentationKit
//
//  Interval event representing one node call (agent, tool, function) from
//  start to finish. Rendered in Instruments as a duration bar in the Node
//  Runs (containment) graph, one lane per run with each bar nested under
//  its caller's, and in the per-type Agents / Tools lanes. Use
//  `RailtracksSignposts.begin(_:)` to start the interval and keep the
//  returned `NodeRunHandle`; pass it back to
//  `RailtracksSignposts.end(_:error:)` when the call finishes.
//
//  Supersedes `AgentRun` for SDK versions that emit one interval per node
//  call. `AgentRun` stays for older SDK versions.
//

import Foundation
import os.signpost

/// Metadata captured when a node call begins. `name` labels the bar and
/// `nodeType` picks its color and per-type lane; `nodeId` / `parentNodeId`
/// link the call to its caller's live interval, which sets its depth. The
/// rest are correlation identifiers that surface as columns on the
/// interval row.
public struct NodeRun: Sendable, Codable, Equatable {
    public var name: String
    public var nodeType: NodeType
    public var nodeId: String
    /// The `nodeId` of the calling node's live interval, or `""` for a
    /// root call. An id with no live call behind it also yields depth 0.
    public var parentNodeId: String
    public var sessionId: String
    public var runId: String
    public var parentName: String
    /// What the node received: the prompt for an agent,
    /// the arguments for a tool. Published as a public signpost string, so
    /// it is readable in the unified log (do not pass secrets). Whitespace
    /// runs collapse to one space and the text is capped at
    /// `RailtracksSignposts.nodeRunInputByteCap` UTF-8 bytes (with a
    /// trailing "…" when cut) before it is emitted.
    public var input: String
    /// An agent's system instructions, or `""` for none. Sanitized and
    /// capped exactly like `input`, and also public in the unified log. When
    /// non-empty after sanitizing, `begin` opens a second interval,
    /// `NodeInstructions`, alongside the NodeRun so Instruments can show
    /// the full text; `end` closes both.
    public var instructions: String

    public init(
        name: String,
        nodeType: NodeType,
        nodeId: String = "",
        parentNodeId: String = "",
        sessionId: String = "",
        runId: String = "",
        parentName: String = "",
        input: String = "",
        instructions: String = ""
    ) {
        self.name = name
        self.nodeType = nodeType
        self.nodeId = nodeId
        self.parentNodeId = parentNodeId
        self.sessionId = sessionId
        self.runId = runId
        self.parentName = parentName
        self.input = input
        self.instructions = instructions
    }
}

/// Opaque handle returned by `RailtracksSignposts.begin(_:)`. Carries the
/// `OSSignpostIntervalState` that pairs the end event with its begin, the
/// node name the end pattern repeats, and what `end` needs to release the
/// call's type slot.
public struct NodeRunHandle: Sendable {
    let id: OSSignpostID
    let state: OSSignpostIntervalState
    /// The `NodeInstructions` interval opened next to the NodeRun, or nil
    /// when the call had no (non-empty) instructions.
    let instructionsState: OSSignpostIntervalState?
    /// The plain `NodeRun.name`, repeated in the end messages.
    let name: String
    let nodeId: String
    /// Identifies this call in the indexer's live map, so ending it never
    /// evicts a different live call that reused the same `nodeId`.
    let token: UInt64
    /// The type-slot bucket (`"Agent"`, `"Tool"` or `"Other"`) `typeSlot`
    /// was taken from, so `end` releases it there.
    let typeBucket: String
    /// The run's 0-based ordinal in first-seen order of `runId`, as two
    /// digits, e.g. `"00"`. The containment graph makes one lane per run.
    public let run: String
    /// 0 for a root call, else the live caller's depth + 1. An empty,
    /// unknown or already-ended `parentNodeId` gives 0.
    public let depth: Int
    /// The 0-based sub-row in the fixed per-type lane (Agents, Tools, or
    /// Nodes for everything else). Process-wide: the lowest slot not held
    /// by another live call of the same type bucket, across all runs. 0
    /// unless calls of that type overlap in time.
    public let typeSlot: Int
    /// Whether `begin` opened a `NodeInstructions` interval for this call
    /// (true when the sanitized `instructions` were non-empty). `end`
    /// closes it before the NodeRun interval.
    public var hasInstructionsInterval: Bool { instructionsState != nil }
}
