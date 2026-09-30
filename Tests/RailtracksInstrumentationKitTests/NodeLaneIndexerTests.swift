//
//  NodeLaneIndexerTests.swift
//  RailtracksInstrumentationKitTests
//
//  The Node Runs lane in Instruments creates one swimlane per lane string
//  and orders them by plain string comparison, so these tests assert on the
//  exact lane strings and slots the kit assigns. Each test drives its own
//  NodeLaneIndexer, so results do not depend on process-wide state or on
//  test ordering.
//

import Foundation
import Testing
@testable import RailtracksInstrumentationKit

@Suite("NodeLaneIndexer")
struct NodeLaneIndexerTests {

    /// Begins a call on `indexer`. `parent` defaults to a root call.
    private func begin(
        _ indexer: NodeLaneIndexer,
        _ name: String,
        _ type: NodeType,
        id: String,
        parent: String = "",
        run: String = "run-A"
    ) -> NodeLaneIndexer.Assignment {
        indexer.begin(nodeId: id, parentNodeId: parent, runId: run, nodeType: type.rawValue, name: name)
    }

    private func end(_ indexer: NodeLaneIndexer, _ a: NodeLaneIndexer.Assignment, id: String) {
        indexer.end(nodeId: id, laneKey: a.key, slot: a.slot, token: a.token)
    }

    @Test("root lanes are '<run>-<root> name', counted per run, run ordinal is first-seen order")
    func rootLanesAcrossRuns() {
        let indexer = NodeLaneIndexer()
        let a0 = begin(indexer, "Workflow", .custom("Function"), id: "a0", run: "A")
        let a1 = begin(indexer, "Other", .agent, id: "a1", run: "A")
        let b0 = begin(indexer, "Workflow", .custom("Function"), id: "b0", run: "B")
        let a2 = begin(indexer, "Third", .tool, id: "a2", run: "A")
        #expect(a0.lane == "00-000 Workflow")
        #expect(a1.lane == "00-001 Other")
        #expect(b0.lane == "01-000 Workflow")
        #expect(a2.lane == "00-002 Third")
        #expect([a0, a1, b0, a2].map(\.slot) == [0, 0, 0, 0])
    }

    @Test("child lanes nest under the parent key (contract examples)")
    func childLanesNestUnderParent() {
        let indexer = NodeLaneIndexer()
        let workflow = begin(indexer, "MathWorkflow", .custom("Function"), id: "wf")
        let agent = begin(indexer, "Math Agent", .agent, id: "ag", parent: "wf")
        let add = begin(indexer, "add", .tool, id: "t1", parent: "ag")
        end(indexer, add, id: "t1")
        let multiply = begin(indexer, "multiply", .tool, id: "t2", parent: "ag")
        #expect(workflow.lane == "00-000 MathWorkflow")
        #expect(agent.lane == "00-000.000 Math Agent")
        #expect(add.lane == "00-000.000.000 add")
        #expect(multiply.lane == "00-000.000.001 multiply")
        #expect(agent.key == "00-000.000")
        // Lexical order equals the call tree.
        let lanes = [workflow, agent, add, multiply].map(\.lane)
        #expect(lanes.sorted() == lanes)
    }

    @Test("repeated calls of one node under one caller share a lane")
    func repeatedCallsShareLane() {
        let indexer = NodeLaneIndexer()
        _ = begin(indexer, "Math Agent", .agent, id: "ag")
        var lanes: [String] = []
        for i in 0..<3 {
            let call = begin(indexer, "add", .tool, id: "add-\(i)", parent: "ag")
            lanes.append(call.lane)
            #expect(call.slot == 0)
            end(indexer, call, id: "add-\(i)")
        }
        #expect(lanes == Array(repeating: "00-000.000 add", count: 3))
        // The next distinct child still gets the next index.
        let multiply = begin(indexer, "multiply", .tool, id: "mul", parent: "ag")
        #expect(multiply.lane == "00-000.001 multiply")
    }

    @Test("the same node under two different callers gets two lanes")
    func sameNodeUnderDifferentCallers() {
        let indexer = NodeLaneIndexer()
        _ = begin(indexer, "Solver", .agent, id: "solver")
        _ = begin(indexer, "Verifier", .agent, id: "verifier")
        let fromSolver = begin(indexer, "add", .tool, id: "t1", parent: "solver")
        let fromVerifier = begin(indexer, "add", .tool, id: "t2", parent: "verifier")
        #expect(fromSolver.lane == "00-000.000 add")
        #expect(fromVerifier.lane == "00-001.000 add")
    }

    @Test("the same name with a different node type gets its own lane")
    func sameNameDifferentType() {
        let indexer = NodeLaneIndexer()
        _ = begin(indexer, "Root", .agent, id: "root")
        let tool = begin(indexer, "lookup", .tool, id: "t", parent: "root")
        let agent = begin(indexer, "lookup", .agent, id: "a", parent: "root")
        let function = begin(indexer, "lookup", .custom("Function"), id: "f", parent: "root")
        #expect(tool.lane == "00-000.000 lookup")
        #expect(agent.lane == "00-000.001 lookup")
        #expect(function.lane == "00-000.002 lookup")
    }

    @Test("overlapping calls in one lane get slots 0 and 1")
    func overlappingCallsGetDistinctSlots() {
        let indexer = NodeLaneIndexer()
        _ = begin(indexer, "Agent", .agent, id: "ag")
        let first = begin(indexer, "search", .tool, id: "s1", parent: "ag")
        let second = begin(indexer, "search", .tool, id: "s2", parent: "ag")
        #expect(first.lane == second.lane)
        #expect(first.slot == 0)
        #expect(second.slot == 1)
    }

    @Test("end releases the slot, so a later call reuses the lowest free one")
    func slotReleasedOnEnd() {
        let indexer = NodeLaneIndexer()
        _ = begin(indexer, "Agent", .agent, id: "ag")
        let first = begin(indexer, "search", .tool, id: "s1", parent: "ag")
        let second = begin(indexer, "search", .tool, id: "s2", parent: "ag")
        end(indexer, first, id: "s1")
        // Slot 0 is free again while slot 1 is still held.
        let third = begin(indexer, "search", .tool, id: "s3", parent: "ag")
        #expect(third.slot == 0)
        end(indexer, second, id: "s2")
        end(indexer, third, id: "s3")
        let fourth = begin(indexer, "search", .tool, id: "s4", parent: "ag")
        #expect(fourth.slot == 0)
        #expect(fourth.lane == first.lane)
    }

    @Test("an unknown or already-ended parentNodeId falls back to a root lane")
    func missingParentFallsBackToRoot() {
        let indexer = NodeLaneIndexer()
        let root = begin(indexer, "Agent", .agent, id: "ag")
        end(indexer, root, id: "ag")
        let afterEnd = begin(indexer, "add", .tool, id: "t1", parent: "ag")
        let unknown = begin(indexer, "multiply", .tool, id: "t2", parent: "never-began")
        #expect(afterEnd.lane == "00-001 add")
        #expect(unknown.lane == "00-002 multiply")
    }

    @Test("ending a call does not evict a later live call that reused its nodeId")
    func endKeepsLaterCallWithSameNodeId() {
        let indexer = NodeLaneIndexer()
        let first = begin(indexer, "Agent", .agent, id: "dup")
        _ = begin(indexer, "Agent", .agent, id: "dup")
        end(indexer, first, id: "dup")
        let child = begin(indexer, "add", .tool, id: "t", parent: "dup")
        #expect(child.lane == "00-000.000 add")
    }
}

/// End-to-end through the public API. Uses a fresh run id, so the outcome is
/// independent of whatever other tests or the host process have already begun.
@Suite("RailtracksSignposts.begin(NodeRun)")
struct RailtracksSignpostsNodeRunTests {

    @Test("handles carry the nested lane string and slot")
    func beginAssignsNestedLanes() {
        let runId = UUID().uuidString
        let agent = RailtracksSignposts.begin(NodeRun(
            name: "Math Agent", nodeType: .agent, nodeId: "\(runId)-ag", runId: runId
        ))
        let first = RailtracksSignposts.begin(NodeRun(
            name: "add", nodeType: .tool, nodeId: "\(runId)-t1",
            parentNodeId: "\(runId)-ag", runId: runId, parentName: "Math Agent"
        ))
        let second = RailtracksSignposts.begin(NodeRun(
            name: "add", nodeType: .tool, nodeId: "\(runId)-t2",
            parentNodeId: "\(runId)-ag", runId: runId, parentName: "Math Agent"
        ))
        defer {
            RailtracksSignposts.end(second)
            RailtracksSignposts.end(first)
            RailtracksSignposts.end(agent)
        }

        #expect(agent.lane.hasSuffix("-000 Math Agent"))
        let agentKey = String(agent.lane.dropLast(" Math Agent".count))
        #expect(first.lane == agentKey + ".000 add")
        #expect(second.lane == first.lane)
        #expect(first.slot == 0)
        #expect(second.slot == 1)
    }
}
