//
//  NodeRunIndexer.swift
//  RailtracksInstrumentationKit
//
//  Assigns the run, depth and type slot for each NodeRun interval.
//
//  - Run: the run's ordinal in first-seen order of `runId` (the same rule
//    as AgentRunIndexer), sent as two digits, e.g. `"00"`. The Node Runs
//    (containment) graph makes one lane per run from it.
//  - Depth: 0 for a root call, else the live caller's depth + 1. An empty,
//    unknown or already-ended `parentNodeId` falls back to 0. The
//    containment graph nests each bar by it.
//  - Type slot: the lowest slot not held by another live call in the same
//    type bucket ("Agent", "Tool", or "Other" for every other node type),
//    for the fixed per-type lanes. Those lanes are global, so type slots
//    are shared across all runs.
//
//  Kept as an instance type (rather than static state on RailtracksSignposts)
//  so tests can drive a private instance deterministically.
//

import Foundation
import Synchronization

final class NodeRunIndexer: Sendable {

    /// What one `begin` call was assigned.
    struct Assignment: Equatable, Sendable {
        /// 0-based position of the call's run in first-seen order.
        let runOrdinal: Int
        /// `runOrdinal` as sent on the wire, `String(format: "%02d", runOrdinal)`.
        let run: String
        /// 0 for a root call, else the live caller's depth + 1.
        let depth: Int
        /// The type bucket the call's type slot belongs to.
        let typeBucket: String
        /// The lowest slot not held by another live call in `typeBucket`,
        /// across all runs.
        let typeSlot: Int
        /// Identifies this call in the live map; pass it back to `end`.
        let token: UInt64
    }

    /// The type-slot bucket for a `nodeType`: `"Agent"`, `"Tool"`, or
    /// `"Other"` for everything else (including `"Function"`).
    static func typeBucket(forNodeType nodeType: String) -> String {
        switch nodeType {
        case "Agent", "Tool": return nodeType
        default: return "Other"
        }
    }

    private struct LiveCall {
        let token: UInt64
        let depth: Int
    }

    private struct State {
        var runOrdinals: [String: Int] = [:]
        var liveCalls: [String: LiveCall] = [:]
        var heldTypeSlots: [String: Set<Int>] = [:]
        var nextToken: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Assign the run, depth and type slot for a call that is starting, and
    /// record it as live so calls naming it as their parent nest one level
    /// below it. Safe to call concurrently.
    func begin(
        nodeId: String,
        parentNodeId: String,
        runId: String,
        nodeType: String
    ) -> Assignment {
        state.withLock { s in
            let runOrdinal: Int
            if let existing = s.runOrdinals[runId] {
                runOrdinal = existing
            } else {
                runOrdinal = s.runOrdinals.count
                s.runOrdinals[runId] = runOrdinal
            }

            // One level below the caller while the caller is live; an
            // empty, unknown or already-ended parent falls back to the root.
            let depth: Int
            if !parentNodeId.isEmpty, let parent = s.liveCalls[parentNodeId] {
                depth = parent.depth + 1
            } else {
                depth = 0
            }

            let bucket = Self.typeBucket(forNodeType: nodeType)
            var heldTypes = s.heldTypeSlots[bucket, default: []]
            var typeSlot = 0
            while heldTypes.contains(typeSlot) { typeSlot += 1 }
            heldTypes.insert(typeSlot)
            s.heldTypeSlots[bucket] = heldTypes

            let token = s.nextToken
            s.nextToken += 1
            // An empty nodeId can never be named as a parent, so it is not
            // recorded; recording it would make every such call share one entry.
            if !nodeId.isEmpty {
                s.liveCalls[nodeId] = LiveCall(token: token, depth: depth)
            }

            return Assignment(
                runOrdinal: runOrdinal, run: String(format: "%02d", runOrdinal),
                depth: depth, typeBucket: bucket, typeSlot: typeSlot, token: token
            )
        }
    }

    /// Release the call's type slot and drop it from the live map. Run
    /// ordinals persist for the process.
    func end(
        nodeId: String,
        typeBucket: String,
        typeSlot: Int,
        token: UInt64
    ) {
        state.withLock { s in
            s.heldTypeSlots[typeBucket]?.remove(typeSlot)
            if s.heldTypeSlots[typeBucket]?.isEmpty == true {
                s.heldTypeSlots[typeBucket] = nil
            }
            // Only remove the entry this call created: a later call that
            // reused the nodeId owns it now.
            if let live = s.liveCalls[nodeId], live.token == token {
                s.liveCalls[nodeId] = nil
            }
        }
    }
}
