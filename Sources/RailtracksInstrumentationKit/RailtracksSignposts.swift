//
//  RailtracksSignposts.swift
//  RailtracksInstrumentationKit
//
//  Public emission API for the Railtracks Instrumentation Instruments
//  package. Construct a `FlowTreeNode` / `FlowGraphNode` /
//  `FlowIO` value and hand it to `RailtracksSignposts.emit(_:)` — each
//  overload wraps `OSSignposter.emitEvent` with the field layout the
//  schema's CLIPS pattern expects, so producers never touch the wire
//  format directly. Subsystem and category match the schema's tags.
//

import Foundation
import os.signpost
import Synchronization

public enum RailtracksSignposts {

    public static let subsystem = "io.railtown.visualizer.observability"
    public static let category = "Observation"

    /// Placeholder for `a0`…`a4` hierarchy slots deeper than a node's actual
    /// depth. A node's own name sits at exactly its depth; deeper slots get
    /// this subtle marker instead of repeating the name, so the aggregation
    /// reads as "no further nesting" rather than `name › name › name`.
    static let trailingFill = "·"

    /// Shared signposter. Stateless; safe to reuse across threads.
    static let signposter = OSSignposter(subsystem: subsystem, category: category)

    // MARK: - FlowTreeNode

    /// Captures `#fileID` / `#filePath` / `#line` / `#function` of the
    /// caller via default args, plus an 8-frame return-address backtrace
    /// from `Thread.callStackReturnAddresses`. Together they drive the
    /// Call Tree view's source-jump arrow, which lands on the call site
    /// that invoked this overload. Producers should call `emit(_:)`
    /// directly from the site they want recorded — wrapping in another
    /// helper shifts the resolved frame off by one.
    public static func emit(
        _ event: FlowTreeNode,
        function: String = #function,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line
    ) {
        let depth = event.ancestors.count
        let parentName = event.ancestors.last ?? ""
        log.trace("emit FlowTreeNode name=\(event.name) depth=\(depth) error=\(event.error)")
        // a0…a4: ancestor names fill slots below the node's depth, the node's
        // own name sits at exactly `depth`, and deeper slots get the subtle
        // `trailingFill` placeholder — avoiding both anonymous "" sub-rows
        // and the old `name › name › name` self-repetition.
        func a(_ i: Int) -> String {
            if i < depth { return event.ancestors[i] }
            if i == depth { return event.name }
            return trailingFill
        }
        // 8-frame backtrace, inlined (NOT extracted into a helper) so the
        // first kept frame is this function's caller — extracting would
        // shift everything down by one and the source-jump arrow would
        // land here instead of at the producer's call site.
        let stack = Thread.callStackReturnAddresses.dropFirst()
        let captured = stack.prefix(8).map { $0.uintValue &- 1 }
        let addrs = captured + Array(repeating: UInt(0), count: 8 - captured.count)

        signposter.emitEvent(
            "FlowTreeNode",
            id: .exclusive,
            """
            nodeId=\(event.nodeId, privacy: .public) \
            sessionId=\(event.sessionId, privacy: .public) \
            runId=\(event.runId, privacy: .public) \
            nodeType=\(event.nodeType.rawValue, privacy: .public) \
            model=\(event.model, privacy: .public) \
            provider=\(event.provider, privacy: .public) \
            cost=\(event.cost, privacy: .public) \
            latency=\(event.latency, privacy: .public) \
            inputTokens=\(event.inputTokens, privacy: .public) \
            outputTokens=\(event.outputTokens, privacy: .public) \
            depth=\(depth, privacy: .public) \
            error=\(event.error ? 1 : 0, privacy: .public) \
            fileID=\(fileID, privacy: .public) \
            filePath=\(filePath, privacy: .public) \
            line=\(line) \
            function=\(function, privacy: .public) \
            addr0=\(addrs[0]) \
            addr1=\(addrs[1]) \
            addr2=\(addrs[2]) \
            addr3=\(addrs[3]) \
            addr4=\(addrs[4]) \
            addr5=\(addrs[5]) \
            addr6=\(addrs[6]) \
            addr7=\(addrs[7]) \
            startTime=\(event.startTime, privacy: .public) \
            parentName=\(parentName, privacy: .public) \
            a0=\(a(0), privacy: .public) \
            a1=\(a(1), privacy: .public) \
            a2=\(a(2), privacy: .public) \
            a3=\(a(3), privacy: .public) \
            a4=\(a(4), privacy: .public) \
            name=\(event.name, privacy: .public)
            """
        )
    }

    // MARK: - FlowGraphNode

    /// Like the FlowTreeNode overload, captures the caller's source
    /// location and an 8-frame backtrace. These drive the Flow Object
    /// Graph's Extended Detail source-jump: the schema exposes them as a
    /// `backtrace` annotation column, so selecting a node in the graph
    /// shows the emitting call site with a click-to-source arrow. Call
    /// `emit(_:)` directly from the producer's site (no wrapper) so the
    /// resolved frame is meaningful.
    public static func emit(
        _ event: FlowGraphNode,
        function: String = #function,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line
    ) {
        log.trace("emit FlowGraphNode name=\(event.name) parent=\(event.parentName)")
        // 8-frame backtrace, inlined (NOT extracted) so the first kept
        // frame is this function's caller.
        let stack = Thread.callStackReturnAddresses.dropFirst()
        let captured = stack.prefix(8).map { $0.uintValue &- 1 }
        let addrs = captured + Array(repeating: UInt(0), count: 8 - captured.count)

        signposter.emitEvent(
            "FlowGraphNode",
            id: .exclusive,
            """
            nodeId=\(event.nodeId, privacy: .public) \
            parentId=\(event.parentId, privacy: .public) \
            sessionId=\(event.sessionId, privacy: .public) \
            runId=\(event.runId, privacy: .public) \
            nodeType=\(event.nodeType.rawValue, privacy: .public) \
            parentType=\(event.parentType?.rawValue ?? "", privacy: .public) \
            error=\(event.error ? 1 : 0, privacy: .public) \
            parentError=\(event.parentError ? 1 : 0, privacy: .public) \
            cost=\(event.cost, privacy: .public) \
            model=\(event.model, privacy: .public) \
            fileID=\(fileID, privacy: .public) \
            filePath=\(filePath, privacy: .public) \
            line=\(line) \
            function=\(function, privacy: .public) \
            addr0=\(addrs[0]) \
            addr1=\(addrs[1]) \
            addr2=\(addrs[2]) \
            addr3=\(addrs[3]) \
            addr4=\(addrs[4]) \
            addr5=\(addrs[5]) \
            addr6=\(addrs[6]) \
            addr7=\(addrs[7]) \
            startTime=\(event.startTime, privacy: .public) \
            parentName=\(event.parentName, privacy: .public) \
            name=\(event.name, privacy: .public)
            """
        )
    }

    // MARK: - FlowIO

    /// Empty-string fallbacks ("-" / "unknown" / "<empty>") and content
    /// sanitization (newline/tab/backslash escaping) happen here so the
    /// schema's wire-format invariants stay with the schema, not at every
    /// call site.
    public static func emit(_ event: FlowIO) {
        log.trace("emit FlowIO tool=\(event.toolName) dir=\(event.direction) role=\(event.role)")
        let safeContent = sanitize(event.content.isEmpty ? "<empty>" : event.content)
        let safeRole = event.role.isEmpty ? "unknown" : event.role
        let safeModel = event.model.isEmpty ? "-" : event.model
        let safeProvider = event.provider.isEmpty ? "-" : event.provider

        signposter.emitEvent(
            "FlowIO",
            id: .exclusive,
            """
            nodeId=\(event.nodeId, privacy: .public) \
            sessionId=\(event.sessionId, privacy: .public) \
            runId=\(event.runId, privacy: .public) \
            messageId=\(event.messageId, privacy: .public) \
            source=\(event.source, privacy: .public) \
            direction=\(event.direction, privacy: .public) \
            role=\(safeRole, privacy: .public) \
            model=\(safeModel, privacy: .public) \
            provider=\(safeProvider, privacy: .public) \
            cost=\(event.cost, privacy: .public) \
            latency=\(event.latency, privacy: .public) \
            inputTokens=\(event.inputTokens, privacy: .public) \
            outputTokens=\(event.outputTokens, privacy: .public) \
            startTime=\(event.startTime, privacy: .public) \
            displayRole=\(event.displayRole, privacy: .public) \
            toolName=\(event.toolName, privacy: .public) \
            content=\(safeContent, privacy: .public)
            """
        )
    }

    // MARK: - AgentRun (interval)

    /// Start an interval signpost for one agent's run. Returns a handle the
    /// caller MUST pass to `end(_:error:)` when the agent finishes —
    /// dropping the handle silently leaves the interval open and the bar
    /// extends forever on the timeline.
    public static func begin(_ event: AgentRun) -> AgentRunHandle {
        // Prefix the name with "<run ordinal>-<start index>" so the Agent
        // Runs lane, which orders swimlanes lexically by name, reads as
        // "flows in start order, agents in start order within each flow".
        // See AgentRunIndexer for the format and its rationale.
        let slot = agentRunIndexer.next(forRun: event.runId)
        let index = slot.index
        let displayName = AgentRunIndexer.laneName(slot, name: event.name)
        log.trace("begin AgentRun name=\(event.name) run=\(slot.runOrdinal) index=\(index)")
        let id = signposter.makeSignpostID()
        // Seed error=0 at begin so the AgentRun "error" column has a defined value
        // while the interval is open. Instruments parses that column as an unsigned
        // integer and renders an unset value as UInt64.max (18446744073709551615)
        // for the duration of a live recording; emitting 0 here keeps in-flight runs
        // showing 0, and end(_:error:) overwrites it with the real outcome (0/1).
        let state = signposter.beginInterval(
            "AgentRun",
            id: id,
            """
            error=\(0, privacy: .public) \ 
            nodeId=\(event.nodeId, privacy: .public) \
            sessionId=\(event.sessionId, privacy: .public) \
            runId=\(event.runId, privacy: .public) \
            index=\(index, privacy: .public) \
            parentName=\(event.parentName, privacy: .public) \
            name=\(displayName, privacy: .public)
            """
        )
        return AgentRunHandle(
            id: id, state: state, name: displayName,
            index: index, runOrdinal: slot.runOrdinal
        )
    }

    /// Close an interval previously opened with `begin(_:)`. `error: true`
    /// flips the row color to red in the Agent Runs lane.
    public static func end(_ handle: AgentRunHandle, error: Bool = false) {
        log.trace("end AgentRun name=\(handle.name) error=\(error)")
        signposter.endInterval(
            "AgentRun",
            handle.state,
            """
            error=\(error ? 1 : 0, privacy: .public) \
            name=\(handle.name, privacy: .public)
            """
        )
    }

    // MARK: - Internal

    /// Process-wide counters behind `begin(_:)`: a first-seen ordinal per
    /// `runId` and a per-run agent start index. For a live producer, start
    /// order is begin order.
    private static let agentRunIndexer = AgentRunIndexer()

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
