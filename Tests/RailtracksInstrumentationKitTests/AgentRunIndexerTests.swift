//
//  AgentRunIndexerTests.swift
//  RailtracksInstrumentationKitTests
//
//  The Agent Runs lane in Instruments orders swimlanes by plain string
//  comparison of the lane name, so these tests assert on the exact prefix
//  the SDK produces and on how a set of such names sorts. Each test drives
//  its own AgentRunIndexer, so results do not depend on process-wide state
//  or on test ordering.
//

import Foundation
import Testing
@testable import RailtracksInstrumentationKit

@Suite("AgentRunIndexer")
struct AgentRunIndexerTests {

    @Test("agents within one run are numbered in begin order, run ordinal stays fixed")
    func indexesWithinOneRun() {
        let indexer = AgentRunIndexer()
        let slots = (0..<3).map { _ in indexer.next(forRun: "run-A") }
        #expect(slots.map(\.index) == [0, 1, 2])
        #expect(slots.map(\.runOrdinal) == [0, 0, 0])
    }

    @Test("a new run gets the next ordinal and its own index restarting at 0")
    func secondRunRestartsIndex() {
        let indexer = AgentRunIndexer()
        _ = indexer.next(forRun: "run-A")
        _ = indexer.next(forRun: "run-A")
        let first = indexer.next(forRun: "run-B")
        #expect(first == .init(runOrdinal: 1, index: 0))
    }

    @Test("interleaved runs keep independent counters, ordinal is first-seen order")
    func interleavedRuns() {
        let indexer = AgentRunIndexer()
        let a0 = indexer.next(forRun: "A")
        let b0 = indexer.next(forRun: "B")
        let a1 = indexer.next(forRun: "A")
        let c0 = indexer.next(forRun: "C")
        let b1 = indexer.next(forRun: "B")
        #expect(a0 == .init(runOrdinal: 0, index: 0))
        #expect(a1 == .init(runOrdinal: 0, index: 1))
        #expect(b0 == .init(runOrdinal: 1, index: 0))
        #expect(b1 == .init(runOrdinal: 1, index: 1))
        #expect(c0 == .init(runOrdinal: 2, index: 0))
    }

    @Test("lane name is zero-padded '<run>-<index> name'")
    func laneNameFormat() {
        #expect(AgentRunIndexer.laneName(.init(runOrdinal: 0, index: 0), name: "Agent") == "00-000 Agent")
        #expect(AgentRunIndexer.laneName(.init(runOrdinal: 3, index: 12), name: "Math Agent A") == "03-012 Math Agent A")
        #expect(AgentRunIndexer.laneName(.init(runOrdinal: 11, index: 999), name: "X") == "11-999 X")
    }

    /// Reproduces the reported bug: several flows in one recording, each with
    /// its own agents. The lexically sorted lane names must equal the order in
    /// which agents began, grouped by flow, not "all first agents, then all
    /// second agents".
    @Test("lane names of sequential flows sort into begin order")
    func sequentialFlowsSortIntoBeginOrder() {
        let indexer = AgentRunIndexer()
        let flows: [(run: String, agents: [String])] = [
            ("math",    ["Math Agent A", "Math Agent C", "Math Agent B"]),
            ("simple",  ["Agent"]),
            ("apple",   ["AppleAI Math Assistant Agent"]),
            ("simple2", ["Agent"]),
            ("vision",  ["Image Summarizer"]),
            ("guard",   ["Safe Support Assistant ⛨"]),
            ("verify",  ["MathSolver", "MathVerifier", "MathStepCalculator"]),
        ]
        var beginOrder: [String] = []
        for flow in flows {
            for agent in flow.agents {
                beginOrder.append(AgentRunIndexer.laneName(indexer.next(forRun: flow.run), name: agent))
            }
        }

        #expect(beginOrder.sorted() == beginOrder)
        #expect(beginOrder.first == "00-000 Math Agent A")
        #expect(beginOrder.last == "06-002 MathStepCalculator")
        // Two flows whose root agent shares a name no longer collapse into one lane.
        #expect(Set(beginOrder).count == beginOrder.count)
    }

    @Test("lane names of concurrently running flows sort grouped by flow, then by begin order")
    func concurrentFlowsGroupByFlow() {
        let indexer = AgentRunIndexer()
        var names: [String] = []
        names.append(AgentRunIndexer.laneName(indexer.next(forRun: "A"), name: "a-root"))
        names.append(AgentRunIndexer.laneName(indexer.next(forRun: "B"), name: "b-root"))
        names.append(AgentRunIndexer.laneName(indexer.next(forRun: "A"), name: "a-child"))
        names.append(AgentRunIndexer.laneName(indexer.next(forRun: "B"), name: "b-child"))

        #expect(names.sorted() == [
            "00-000 a-root", "00-001 a-child",
            "01-000 b-root", "01-001 b-child",
        ])
    }

    @Test("concurrent begins on one run hand out each index exactly once")
    func concurrentBeginsAreUnique() async {
        let indexer = AgentRunIndexer()
        let count = 200
        let indices = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<count {
                group.addTask { indexer.next(forRun: "shared").index }
            }
            var collected: [Int] = []
            for await index in group { collected.append(index) }
            return collected
        }
        #expect(Set(indices) == Set(0..<count))
    }
}

/// End-to-end through the public API. Uses a fresh run id, so the outcome is
/// independent of whatever other tests or the host process have already begun.
@Suite("RailtracksSignposts.begin")
struct RailtracksSignpostsBeginTests {

    @Test("handles carry the assigned index, a shared run ordinal, and the prefixed lane name")
    func beginAssignsSlots() {
        let runId = UUID().uuidString
        let first = RailtracksSignposts.begin(AgentRun(name: "Orchestrator", runId: runId))
        let second = RailtracksSignposts.begin(AgentRun(name: "draft_email", runId: runId))
        defer {
            RailtracksSignposts.end(second)
            RailtracksSignposts.end(first)
        }

        #expect(first.index == 0)
        #expect(second.index == 1)
        #expect(first.runOrdinal == second.runOrdinal)
        let expectedPrefix = String(format: "%02d-", first.runOrdinal)
        #expect(first.name == expectedPrefix + "000 Orchestrator")
        #expect(second.name == expectedPrefix + "001 draft_email")
    }

    @Test("a different run id gets a later ordinal")
    func distinctRunsGetDistinctOrdinals() {
        let a = RailtracksSignposts.begin(AgentRun(name: "A", runId: UUID().uuidString))
        let b = RailtracksSignposts.begin(AgentRun(name: "B", runId: UUID().uuidString))
        defer {
            RailtracksSignposts.end(b)
            RailtracksSignposts.end(a)
        }
        #expect(b.runOrdinal > a.runOrdinal)
        #expect(a.index == 0 && b.index == 0)
    }
}
