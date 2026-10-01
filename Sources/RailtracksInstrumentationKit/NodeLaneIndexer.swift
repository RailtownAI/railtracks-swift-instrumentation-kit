//
//  NodeLaneIndexer.swift
//  RailtracksInstrumentationKit
//
//  Assigns the lane, slot and type slot for each NodeRun interval.
//
//  The Node Runs lane creates one swimlane per distinct lane string and
//  orders swimlanes lexically, so the lane string carries a sortable,
//  hierarchical key: `"<run>-<root>"` for a root call and
//  `"<parent key>.<child>"` below it, e.g. `"00-000 MathWorkflow"`,
//  `"00-000.000 Math Agent"`, `"00-000.000.001 multiply"`. Sorting those
//  strings nests every lane directly under its caller's lane, in the order
//  the lanes first appeared.
//
//  A lane is identified by (caller lane key, or runId at the root;
//  nodeType; name), so every call of one node from one caller shares a
//  lane. Calls that overlap within a lane get distinct slots (the lowest
//  free one), which Instruments uses to put them on separate sub-rows.
//
//  Separately, each call takes a type slot for the fixed "Nodes / Agents /
//  Tools" lanes: the lowest slot not held by another live call in the same
//  type bucket ("Agent", "Tool", or "Other" for every other node type).
//  Those lanes are global, so type slots are shared across all runs and
//  lanes, not per lane.
//
//  Kept as an instance type (rather than static state on RailtracksSignposts)
//  so tests can drive a private instance deterministically.
//

import Synchronization

final class NodeLaneIndexer: Sendable {

    /// What one `begin` call was assigned.
    struct Assignment: Equatable, Sendable {
        /// The hierarchical lane key, e.g. `"00-000.001"`.
        let key: String
        /// The lane string, `"<key> <name>"`.
        let lane: String
        /// The lowest slot not held by another live call in this lane.
        let slot: Int
        /// The type bucket the call's type slot belongs to.
        let typeBucket: String
        /// The lowest slot not held by another live call in `typeBucket`,
        /// across all runs and lanes.
        let typeSlot: Int
        /// Identifies this call in the live map; pass it back to `end`.
        let token: UInt64
    }

    /// Where a lane hangs: at the root of a run, or under a caller's lane.
    /// The type-slot bucket for a `nodeType`: `"Agent"`, `"Tool"`, or
    /// `"Other"` for everything else (including `"Function"`).
    static func typeBucket(forNodeType nodeType: String) -> String {
        switch nodeType {
        case "Agent", "Tool": return nodeType
        default: return "Other"
        }
    }

    private enum Scope: Hashable {
        case root(runId: String)
        case child(parentKey: String)
    }

    private struct LaneIdentity: Hashable {
        let scope: Scope
        let nodeType: String
        let name: String
    }

    private struct LiveCall {
        let token: UInt64
        let laneKey: String
    }

    private struct State {
        var runOrdinals: [String: Int] = [:]
        var rootLaneCounters: [String: Int] = [:]
        var childLaneCounters: [String: Int] = [:]
        var laneKeys: [LaneIdentity: String] = [:]
        var liveCalls: [String: LiveCall] = [:]
        var heldSlots: [String: Set<Int>] = [:]
        var heldTypeSlots: [String: Set<Int>] = [:]
        var nextToken: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Assign the lane, slot and type slot for a call that is starting, and record it
    /// as live so calls naming it as their parent nest under its lane.
    /// Safe to call concurrently.
    func begin(
        nodeId: String,
        parentNodeId: String,
        runId: String,
        nodeType: String,
        name: String
    ) -> Assignment {
        state.withLock { s in
            // Ordinal of the run in first-seen order, the same rule as
            // AgentRunIndexer. Only root keys print it.
            let runOrdinal: Int
            if let existing = s.runOrdinals[runId] {
                runOrdinal = existing
            } else {
                runOrdinal = s.runOrdinals.count
                s.runOrdinals[runId] = runOrdinal
            }

            // Nest under the caller's lane while the caller is live; an
            // empty, unknown or already-ended parent falls back to the root.
            let scope: Scope
            if !parentNodeId.isEmpty, let parent = s.liveCalls[parentNodeId] {
                scope = .child(parentKey: parent.laneKey)
            } else {
                scope = .root(runId: runId)
            }

            let identity = LaneIdentity(scope: scope, nodeType: nodeType, name: name)
            let key: String
            if let existing = s.laneKeys[identity] {
                key = existing
            } else {
                switch scope {
                case .root(let runId):
                    let index = s.rootLaneCounters[runId, default: 0]
                    s.rootLaneCounters[runId] = index + 1
                    key = String(format: "%02d-%03d", runOrdinal, index)
                case .child(let parentKey):
                    let index = s.childLaneCounters[parentKey, default: 0]
                    s.childLaneCounters[parentKey] = index + 1
                    key = parentKey + String(format: ".%03d", index)
                }
                s.laneKeys[identity] = key
            }

            var held = s.heldSlots[key, default: []]
            var slot = 0
            while held.contains(slot) { slot += 1 }
            held.insert(slot)
            s.heldSlots[key] = held

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
                s.liveCalls[nodeId] = LiveCall(token: token, laneKey: key)
            }

            return Assignment(
                key: key, lane: key + " " + name, slot: slot,
                typeBucket: bucket, typeSlot: typeSlot, token: token
            )
        }
    }

    /// Release the call's slot and type slot, and drop it from the live map. Lane keys and
    /// counters persist, so a later call of the same node from the same
    /// caller lands in the same lane.
    func end(
        nodeId: String,
        laneKey: String,
        slot: Int,
        typeBucket: String,
        typeSlot: Int,
        token: UInt64
    ) {
        state.withLock { s in
            s.heldSlots[laneKey]?.remove(slot)
            if s.heldSlots[laneKey]?.isEmpty == true {
                s.heldSlots[laneKey] = nil
            }
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
