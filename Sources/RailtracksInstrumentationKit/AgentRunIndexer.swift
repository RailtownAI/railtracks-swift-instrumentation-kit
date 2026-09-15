//
//  AgentRunIndexer.swift
//  RailtracksInstrumentationKit
//
//  Assigns the two counters that order the Agent Runs lane in Instruments.
//
//  The lane creates one swimlane per distinct `name` and orders swimlanes
//  lexically by that string, so the SDK prefixes each agent's name with a
//  sortable key. A per-run index alone is not enough: every run restarts
//  at 000, so a recording that contains several flows shows all the
//  "000 …" lanes first, then all the "001 …", and so on. Prefixing the
//  run's own start-order ordinal first ("01-000 Name") makes the lexical
//  order equal "flows in the order they started, agents in the order they
//  started within each flow".
//
//  Kept as an instance type (rather than static state on RailtracksSignposts)
//  so tests can drive a private instance deterministically.
//

import Synchronization

final class AgentRunIndexer: Sendable {

    /// The pair of counters assigned to one `begin(_:)` call.
    struct Slot: Equatable, Sendable {
        /// 0-based position of this run among all runs this process has
        /// started an agent for, in first-seen order.
        let runOrdinal: Int
        /// 0-based start order of this agent within its run.
        let index: Int
    }

    private struct State {
        var runOrdinals: [String: Int] = [:]
        var agentCounters: [String: Int] = [:]
    }

    private let state = Mutex(State())

    /// Assign the next slot for `runId`. The first call for a given run
    /// also assigns that run's ordinal. Safe to call concurrently.
    func next(forRun runId: String) -> Slot {
        state.withLock { s in
            let ordinal: Int
            if let existing = s.runOrdinals[runId] {
                ordinal = existing
            } else {
                ordinal = s.runOrdinals.count
                s.runOrdinals[runId] = ordinal
            }
            let index = s.agentCounters[runId, default: 0]
            s.agentCounters[runId] = index + 1
            return Slot(runOrdinal: ordinal, index: index)
        }
    }

    /// The swimlane label: `"<run>-<index> <name>"`, e.g. `"01-000 Orchestrator"`.
    ///
    /// Both numbers are zero-padded because Instruments orders swimlanes by
    /// plain string comparison — without padding "10-…" would sort before
    /// "2-…". The SDK assigns numbers incrementally and cannot know the final
    /// count, so fixed widths are used: 2 digits for the run ordinal (clean
    /// ordering up to 100 runs per process) and 3 for the agent index (up to
    /// 1000 agents per run). Larger values still work, they just stop
    /// sorting cleanly past the width.
    static func laneName(_ slot: Slot, name: String) -> String {
        String(format: "%02d-%03d ", slot.runOrdinal, slot.index) + name
    }
}
