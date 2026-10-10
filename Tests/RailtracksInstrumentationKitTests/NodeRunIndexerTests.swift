//
//  NodeRunIndexerTests.swift
//  RailtracksInstrumentationKitTests
//
//  The Node Runs (containment) graph makes one lane per `run` and nests
//  bars by `depth`, and the per-type lanes split overlapping calls by
//  `typeSlot`, so these tests assert on the exact values the kit assigns.
//  Each test drives its own NodeRunIndexer, so results do not depend on
//  process-wide state or on test ordering.
//

import Foundation
import Testing
@testable import RailtracksInstrumentationKit

@Suite("NodeRunIndexer")
struct NodeRunIndexerTests {

    /// Begins a call on `indexer`. `parent` defaults to a root call.
    private func begin(
        _ indexer: NodeRunIndexer,
        _ type: NodeType,
        id: String,
        parent: String = "",
        run: String = "run-A"
    ) -> NodeRunIndexer.Assignment {
        indexer.begin(nodeId: id, parentNodeId: parent, runId: run, nodeType: type.rawValue)
    }

    private func end(_ indexer: NodeRunIndexer, _ a: NodeRunIndexer.Assignment, id: String) {
        indexer.end(nodeId: id, typeBucket: a.typeBucket, typeSlot: a.typeSlot, token: a.token)
    }

    @Test("run ordinals follow first-seen order of runId, sent as two digits")
    func runOrdinalsAcrossRuns() {
        let indexer = NodeRunIndexer()
        let a0 = begin(indexer, .custom("Function"), id: "a0", run: "A")
        let a1 = begin(indexer, .agent, id: "a1", parent: "a0", run: "A")
        let b0 = begin(indexer, .custom("Function"), id: "b0", run: "B")
        let a2 = begin(indexer, .tool, id: "a2", run: "A")
        let c0 = begin(indexer, .agent, id: "c0", run: "C")
        #expect([a0, a1, b0, a2, c0].map(\.runOrdinal) == [0, 0, 1, 0, 2])
        #expect([a0, a1, b0, a2, c0].map(\.run) == ["00", "00", "01", "00", "02"])
    }

    @Test("a run past 99 keeps every digit")
    func runOrdinalPastTwoDigits() {
        let indexer = NodeRunIndexer()
        var last: NodeRunIndexer.Assignment?
        for i in 0...100 {
            last = begin(indexer, .tool, id: "t\(i)", run: "run-\(i)")
        }
        #expect(last?.run == "100")
    }

    @Test("depth is 0 for a root, 1 for its child, 2 for a grandchild")
    func depthFollowsNesting() {
        let indexer = NodeRunIndexer()
        let workflow = begin(indexer, .custom("Function"), id: "wf")
        let agent = begin(indexer, .agent, id: "ag", parent: "wf")
        let add = begin(indexer, .tool, id: "t1", parent: "ag")
        end(indexer, add, id: "t1")
        // A sibling after the first child ended sits at the same depth.
        let multiply = begin(indexer, .tool, id: "t2", parent: "ag")
        let sub = begin(indexer, .agent, id: "sub", parent: "ag")
        let lookup = begin(indexer, .tool, id: "lk", parent: "sub")
        #expect(workflow.depth == 0)
        #expect(agent.depth == 1)
        #expect(add.depth == 2)
        #expect(multiply.depth == 2)
        #expect(sub.depth == 2)
        #expect(lookup.depth == 3)
    }

    @Test("an empty, unknown or already-ended parentNodeId falls back to depth 0")
    func missingParentFallsBackToRoot() {
        let indexer = NodeRunIndexer()
        let root = begin(indexer, .agent, id: "ag")
        let child = begin(indexer, .tool, id: "c", parent: "ag")
        end(indexer, child, id: "c")
        end(indexer, root, id: "ag")
        let afterEnd = begin(indexer, .tool, id: "t1", parent: "ag")
        let unknown = begin(indexer, .tool, id: "t2", parent: "never-began")
        let empty = begin(indexer, .tool, id: "t3", parent: "")
        #expect(child.depth == 1)
        #expect(afterEnd.depth == 0)
        #expect(unknown.depth == 0)
        #expect(empty.depth == 0)
    }

    @Test("an empty nodeId is never recorded as a parent")
    func emptyNodeIdIsNotAParent() {
        let indexer = NodeRunIndexer()
        _ = begin(indexer, .agent, id: "")
        let child = begin(indexer, .tool, id: "t", parent: "")
        #expect(child.depth == 0)
    }

    @Test("ending a call does not evict a later live call that reused its nodeId")
    func endKeepsLaterCallWithSameNodeId() {
        let indexer = NodeRunIndexer()
        _ = begin(indexer, .custom("Function"), id: "wf")
        let first = begin(indexer, .agent, id: "dup")
        // The second "dup" is a child of wf, so it sits at depth 1.
        let second = begin(indexer, .agent, id: "dup", parent: "wf")
        end(indexer, first, id: "dup")
        let child = begin(indexer, .tool, id: "t", parent: "dup")
        #expect(second.depth == 1)
        #expect(child.depth == 2)
        end(indexer, second, id: "dup")
        let orphan = begin(indexer, .tool, id: "t2", parent: "dup")
        #expect(orphan.depth == 0)
    }

    // MARK: Type slots

    @Test("overlapping agents in different runs get type slots 0 and 1; a tool starts at 0")
    func typeSlotsPerBucket() {
        let indexer = NodeRunIndexer()
        let solver = begin(indexer, .agent, id: "solver", run: "A")
        let verifier = begin(indexer, .agent, id: "verifier", run: "B")
        let tool = begin(indexer, .tool, id: "t", parent: "solver", run: "A")
        #expect(solver.typeBucket == "Agent")
        #expect([solver, verifier].map(\.typeSlot) == [0, 1])
        #expect(tool.typeBucket == "Tool")
        #expect(tool.typeSlot == 0)
    }

    @Test("Function and other custom types share the 'Other' bucket")
    func customTypesGoToOther() {
        let indexer = NodeRunIndexer()
        let function = begin(indexer, .custom("Function"), id: "f")
        let custom = begin(indexer, .custom("Retriever"), id: "r", parent: "f")
        let agent = begin(indexer, .agent, id: "a", parent: "f")
        #expect(function.typeBucket == "Other")
        #expect(custom.typeBucket == "Other")
        #expect([function, custom].map(\.typeSlot) == [0, 1])
        #expect(agent.typeSlot == 0)
    }

    @Test("end releases the type slot, so slot 0 is reused")
    func typeSlotReleasedOnEnd() {
        let indexer = NodeRunIndexer()
        let first = begin(indexer, .agent, id: "solver")
        let second = begin(indexer, .agent, id: "verifier")
        end(indexer, first, id: "solver")
        let third = begin(indexer, .agent, id: "planner")
        #expect(second.typeSlot == 1)
        #expect(third.typeSlot == 0)
    }
}

@Suite("RailtracksSignposts.sanitizeNodeRunInput")
struct NodeRunInputSanitizerTests {

    private let cap = RailtracksSignposts.nodeRunInputByteCap

    @Test("the cap is 4096 UTF-8 bytes")
    func capIs4096() {
        #expect(cap == 4096)
    }

    @Test("newlines, tabs and space runs collapse to one space, and the ends are trimmed")
    func collapsesAndTrims() {
        let raw = "  \n\tPlan a trip\n\nto  Lisbon\t\tin May \r\n "
        #expect(RailtracksSignposts.sanitizeNodeRunInput(raw) == "Plan a trip to Lisbon in May")
    }

    @Test("empty and whitespace-only input stays empty")
    func emptyInput() {
        #expect(RailtracksSignposts.sanitizeNodeRunInput("") == "")
        #expect(RailtracksSignposts.sanitizeNodeRunInput(" \n\t ") == "")
    }

    @Test("input at the cap is unchanged")
    func atCapUnchanged() {
        let exact = String(repeating: "a", count: cap)
        #expect(RailtracksSignposts.sanitizeNodeRunInput(exact) == exact)
    }

    @Test("ASCII over the cap is cut to exactly the cap, ending in '…'")
    func asciiTruncation() {
        let result = RailtracksSignposts.sanitizeNodeRunInput(String(repeating: "a", count: cap + 50))
        #expect(result.utf8.count == cap)
        #expect(result.hasSuffix("…"))
        #expect(result.dropLast().allSatisfy { $0 == "a" })
    }

    @Test("multibyte truncation never splits a character and stays within the cap",
          arguments: ["é", "😀", "👩‍👩‍👧", "aé😀"])
    func multibyteTruncation(unit: String) {
        let raw = String(repeating: unit, count: cap)
        let result = RailtracksSignposts.sanitizeNodeRunInput(raw)
        #expect(result.utf8.count <= cap)
        #expect(result.hasSuffix("…"))
        // Every kept character is a whole one from the source, in order.
        let kept = String(result.dropLast())
        #expect(raw.hasPrefix(kept))
        #expect(kept.allSatisfy { unit.contains($0) })
        // The cut wasted fewer bytes than one more source unit would take.
        #expect(cap - result.utf8.count < unit.utf8.count)
    }

    @Test("a 4 KB prompt with multibyte text past the cap is cut to at most 4096 bytes")
    func multibyteAtFourKilobytes() {
        // 2-byte accents and 4-byte emoji, separated by newlines that
        // collapse to single spaces.
        let line = "Olá café ação 😀 naïve 🚆\n"
        let raw = String(repeating: line, count: 200)
        #expect(raw.utf8.count > cap)
        let result = RailtracksSignposts.sanitizeNodeRunInput(raw)
        #expect(result.utf8.count <= cap)
        // At most 3 bytes of an emoji that did not fit plus 1 dropped space.
        #expect(result.utf8.count >= cap - 4)
        #expect(result.hasSuffix("…"))
        #expect(!result.contains("\n"))
        #expect(!result.dropLast().hasSuffix(" "))
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(collapsed.hasPrefix(String(result.dropLast())))
    }

    @Test("multibyte text that fits in 4096 bytes passes through unchanged")
    func multibyteUnderCapUnchanged() {
        let unit = "Olá 😀 "
        var text = String(repeating: unit, count: cap / unit.utf8.count)
        text = String(text.dropLast())  // no trailing space
        #expect(text.utf8.count <= cap)
        #expect(RailtracksSignposts.sanitizeNodeRunInput(text) == text)
    }
}

@Suite("NodeInstructions interval")
struct NodeInstructionsIntervalTests {

    @Test("the decision helper opens an interval only for non-empty text")
    func helperDecision() {
        #expect(!RailtracksSignposts.opensInstructionsInterval(sanitizedInstructions: ""))
        #expect(RailtracksSignposts.opensInstructionsInterval(sanitizedInstructions: "Be concise"))
    }

    @Test("begin opens a NodeInstructions interval only when the sanitized instructions are non-empty",
          arguments: [("", false), ("  \n\t ", false), ("Be concise.", true),
                      (String(repeating: "Réponds en français 😀. ", count: 300), true)])
    func beginOpensInterval(instructions: String, expected: Bool) {
        let runId = UUID().uuidString
        let handle = RailtracksSignposts.begin(NodeRun(
            name: "Planner", nodeType: .agent, nodeId: "\(runId)-ag",
            runId: runId, input: "Plan a trip", instructions: instructions
        ))
        defer { RailtracksSignposts.end(handle) }
        #expect(handle.hasInstructionsInterval == expected)
    }

    @Test("instructions default to empty and open no interval")
    func defaultIsEmpty() {
        let runId = UUID().uuidString
        let run = NodeRun(name: "add", nodeType: .tool, nodeId: "\(runId)-t", runId: runId)
        #expect(run.instructions == "")
        let handle = RailtracksSignposts.begin(run)
        RailtracksSignposts.end(handle, error: true)
        #expect(!handle.hasInstructionsInterval)
    }
}

/// End-to-end through the public API. Uses a fresh run id, so the outcome is
/// independent of whatever other tests or the host process have already begun.
@Suite("RailtracksSignposts.begin(NodeRun)")
struct RailtracksSignpostsNodeRunTests {

    @Test("handles carry the run and the depth under the caller")
    func beginAssignsRunAndDepth() {
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

        #expect(agent.depth == 0)
        #expect(first.depth == 1)
        #expect(second.depth == 1)
        // Run ordinals are process-wide, so only their shape and equality
        // within one run are stable here.
        #expect(agent.run.count >= 2)
        #expect(agent.run.allSatisfy { $0.isNumber })
        #expect(first.run == agent.run)
        #expect(second.run == agent.run)
        // Type slots are process-wide too, so only their relation is stable.
        #expect(second.typeSlot != first.typeSlot)
    }
}
