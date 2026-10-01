//
//  NodeRun.swift
//  RailtracksInstrumentationKit
//
//  Interval event representing one node call (agent, tool, function) from
//  start to finish. Rendered in Instruments as a duration bar on the Node
//  Runs lane, one swimlane per node under its calling lane, so the lanes
//  nest the way the calls do. Use `RailtracksSignposts.begin(_:)` to start
//  the interval and keep the returned `NodeRunHandle`; pass it back to
//  `RailtracksSignposts.end(_:error:)` when the call finishes.
//
//  Supersedes `AgentRun` for SDK versions that emit one interval per node
//  call. `AgentRun` stays for older SDK versions.
//

import Foundation
import os.signpost

/// Metadata captured when a node call begins. `name` and `nodeType` pick
/// the lane together with the caller; `nodeId` / `parentNodeId` link the
/// call to its caller's live interval. The rest are correlation
/// identifiers that surface as columns on the interval row.
public struct NodeRun: Sendable, Codable, Equatable {
    public var name: String
    public var nodeType: NodeType
    public var nodeId: String
    /// The `nodeId` of the calling node's live interval, or `""` for a
    /// root call. An id with no live call behind it also yields a root lane.
    public var parentNodeId: String
    public var sessionId: String
    public var runId: String
    public var parentName: String
    /// A short summary of what the node received: the prompt for an agent,
    /// the arguments for a tool. Published as a public signpost string, so
    /// it is readable in the unified log (do not pass secrets). Whitespace
    /// runs collapse to one space and the text is capped at
    /// `RailtracksSignposts.nodeRunInputByteCap` UTF-8 bytes (with a
    /// trailing "…" when cut) before it is emitted.
    public var input: String

    public init(
        name: String,
        nodeType: NodeType,
        nodeId: String = "",
        parentNodeId: String = "",
        sessionId: String = "",
        runId: String = "",
        parentName: String = "",
        input: String = ""
    ) {
        self.name = name
        self.nodeType = nodeType
        self.nodeId = nodeId
        self.parentNodeId = parentNodeId
        self.sessionId = sessionId
        self.runId = runId
        self.parentName = parentName
        self.input = input
    }
}

/// Opaque handle returned by `RailtracksSignposts.begin(_:)`. Carries the
/// `OSSignpostIntervalState` that pairs the end event with its begin, the
/// lane string the end-pattern repeats, and what `end` needs to release
/// the call's slot in its lane and its type slot.
public struct NodeRunHandle: Sendable {
    let id: OSSignpostID
    let state: OSSignpostIntervalState
    let nodeId: String
    let laneKey: String
    /// Identifies this call in the indexer's live map, so ending it never
    /// evicts a different live call that reused the same `nodeId`.
    let token: UInt64
    /// The type-slot bucket (`"Agent"`, `"Tool"` or `"Other"`) `typeSlot`
    /// was taken from, so `end` releases it there.
    let typeBucket: String
    /// The full lane string, `"<key> <name>"`, e.g. `"00-000.001 add"`.
    public let lane: String
    /// The 0-based sub-row within the lane. 0 unless calls in the same
    /// lane overlap in time.
    public let slot: Int
    /// The 0-based sub-row in the fixed per-type lane (Agents, Tools, or
    /// Nodes for everything else). Process-wide: the lowest slot not held
    /// by another live call of the same type bucket, across all runs and
    /// lanes. 0 unless calls of that type overlap in time.
    public let typeSlot: Int
}
