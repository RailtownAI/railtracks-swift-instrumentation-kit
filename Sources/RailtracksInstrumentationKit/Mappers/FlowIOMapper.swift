//
//  FlowIOMapper.swift
//  RailtracksInstrumentationKit
//
//  Opt-in helper. Called by FlowGraphMapper.emit(data:). Not part of the
//  direct emission interface — consumers using RailtracksSignposts.emit
//  should construct FlowIO events themselves rather than reach into this.
//

import Foundation

enum FlowIOMapper {

    /// Walk the parsed RTSFlowGraph JSON and emit one FlowIO point event per
    /// logical input/output message. Returns the number of emitted rows.
    ///
    /// `prefixById` maps each node identifier to a display prefix produced by
    /// FlowGraphMapper.displayPrefixesByNodeId — a zero-padded preorder index
    /// plus a depth indent (e.g. "03     "). Concatenated with the raw name,
    /// it makes the I/O aggregation sort into tree-walk order while still
    /// showing visible nesting.
    ///
    /// Per-row displayRole ("0001 system", "0002 user", …) is computed in a
    /// second pass after all rows are collected — a single global emit-order
    /// index (never reset per node or direction) so the flat Tool I/O list
    /// reads in order.
    static func emit(json: Any, prefixById: [String: String] = [:]) -> Int {
        guard let root = json as? [String: Any],
              let runs = root["runs"] as? [[String: Any]] else {
            log.warning("FlowIO: JSON missing 'runs'; no I/O rows")
            return 0
        }
        let sessionId = root["session_id"] as? String ?? ""
        var rows: [PendingRow] = []
        for run in runs {
            rows.append(contentsOf: collect(run: run, sessionId: sessionId, prefixById: prefixById))
        }
        emitAll(rows: rows)
        log.debug("collected \(rows.count) I/O row(s) across \(runs.count) run(s)")
        return rows.count
    }

    private struct PendingRow {
        let nodeId: String
        let runId: String
        let sessionId: String
        let messageId: String
        let source: String
        let direction: String
        let role: String
        let model: String
        let provider: String
        let cost: Double
        let latency: Double
        let inTok: Int
        let outTok: Int
        let toolName: String
        let content: String
        let startTime: TimeInterval
    }

    // MARK: - Collection

    private static func collect(run: [String: Any], sessionId: String, prefixById: [String: String]) -> [PendingRow] {
        let runId = run["run_id"] as? String ?? ""
        let nodes = run["nodes"] as? [[String: Any]] ?? []
        let edges = run["edges"] as? [[String: Any]] ?? []

        var nameById: [String: String] = [:]
        // Per-node start time (absolute epoch seconds, finish − latency),
        // keyed by node id so both node-IO and edge-IO rows (edges attribute
        // to the target node) can attach the owning node's start.
        var startTimeById: [String: TimeInterval] = [:]
        for n in nodes {
            guard let id = n["identifier"] as? String else { continue }
            nameById[id] = (n["name"] as? String) ?? id
            let lat = ((n["details"] as? [String: Any])?["internals"] as? [String: Any])?["latency"] as? [String: Any]
            let latency = lat?["total_time"] as? Double ?? 0
            let stampTime = (n["stamp"] as? [String: Any])?["time"] as? Double ?? 0
            startTimeById[id] = stampTime > 0 ? stampTime - latency : 0
        }

        // Roots are nodes that never appear as a target with a real source.
        // The external-invocation edge has source="" so it doesn't disqualify.
        // For each root, capture wall-clock total_time so a single row can
        // surface it (parent wall-clocks subsume children's, so this is the
        // only latency that can be <sum>'d without double-counting).
        var targetsWithRealSource: Set<String> = []
        for e in edges {
            if let s = e["source"] as? String, !s.isEmpty,
               let t = e["target"] as? String {
                targetsWithRealSource.insert(t)
            }
        }
        var rootLatencyById: [String: Double] = [:]
        for n in nodes {
            guard let id = n["identifier"] as? String,
                  !targetsWithRealSource.contains(id) else { continue }
            let lat = ((n["details"] as? [String: Any])?["internals"] as? [String: Any])?["latency"] as? [String: Any]
            if let totalTime = lat?["total_time"] as? Double {
                rootLatencyById[id] = totalTime
            }
        }

        var rows: [PendingRow] = []
        for n in nodes {
            rows.append(contentsOf: collectNodeIO(
                n, runId: runId, sessionId: sessionId, prefixById: prefixById,
                startTimeById: startTimeById
            ))
        }
        for e in edges {
            rows.append(contentsOf: collectEdgeIO(
                e, runId: runId, sessionId: sessionId, nameById: nameById,
                prefixById: prefixById, rootLatencyById: rootLatencyById,
                startTimeById: startTimeById
            ))
        }
        return rows
    }

    /// Agent llm_details → Input rows (zero metrics) and Output rows.
    /// The FIRST output row of each llm_details call carries the call's
    /// tokens/cost; remaining tool-call rows carry zero so that <sum>
    /// aggregation does not fan-out over-count.
    ///
    /// Latency is intentionally NOT emitted here. Per-LLM-call latencies
    /// sum to "time inside the LLM API" (282.8s on this trace) which is
    /// a different quantity from the run's wall-clock (322.8s). Tool I/O
    /// reports the wall-clock instead — emitted as a single carrier row
    /// on the root in collectEdgeIO — so <sum> at any level gives the
    /// run's true duration.
    private static func collectNodeIO(
        _ raw: [String: Any], runId: String, sessionId: String, prefixById: [String: String],
        startTimeById: [String: TimeInterval]
    ) -> [PendingRow] {
        guard let nodeId = raw["identifier"] as? String,
              let rawName = raw["name"] as? String,
              let internals = (raw["details"] as? [String: Any])?["internals"] as? [String: Any],
              let llms = internals["llm_details"] as? [[String: Any]]
        else {
            // Normal: tool nodes carry no llm_details.
            log.trace("collectNodeIO: no llm_details for node \(raw["identifier"] as? String ?? "?")")
            return []
        }
        let toolName = (prefixById[nodeId] ?? "") + rawName
        let startTime = startTimeById[nodeId] ?? 0

        var rows: [PendingRow] = []
        for (llmIdx, llm) in llms.enumerated() {
            let model = llm["model_name"] as? String ?? ""
            let provider = llm["model_provider"] as? String ?? ""
            let cost = llm["total_cost"] as? Double ?? 0
            let inTok = llm["input_tokens"] as? Int ?? 0
            let outTok = llm["output_tokens"] as? Int ?? 0

            let inputs = llm["input"] as? [[String: Any]] ?? []
            for (i, msg) in inputs.enumerated() {
                rows.append(PendingRow(
                    nodeId: nodeId,
                    runId: runId,
                    sessionId: sessionId,
                    messageId: "\(nodeId)-llm\(llmIdx)-in\(i)",
                    source: "llm",
                    direction: "Input",
                    role: (msg["role"] as? String) ?? "user",
                    model: model,
                    provider: provider,
                    cost: 0,
                    latency: 0,
                    inTok: 0,
                    outTok: 0,
                    toolName: toolName,
                    content: (msg["content"] as? String) ?? "",
                    startTime: startTime
                ))
            }

            let output = llm["output"] as? [String: Any]
            let outRole = (output?["role"] as? String) ?? "assistant"
            let outContent = output?["content"]

            var outputs: [(role: String, content: String)] = []
            if let calls = outContent as? [[String: Any]] {
                for call in calls {
                    let name = call["name"] as? String ?? "?"
                    let argsJSON = compactJSON(call["arguments"]) ?? ""
                    outputs.append((
                        role: "tool_call",
                        content: "→ \(name)(\(argsJSON))"
                    ))
                }
            } else if let text = outContent as? String, !text.isEmpty {
                outputs.append((role: outRole, content: text))
            }
            if outputs.isEmpty {
                outputs.append((role: outRole, content: ""))
            }

            for (i, row) in outputs.enumerated() {
                rows.append(PendingRow(
                    nodeId: nodeId,
                    runId: runId,
                    sessionId: sessionId,
                    messageId: "\(nodeId)-llm\(llmIdx)-out\(i)",
                    source: "llm",
                    direction: "Output",
                    role: row.role,
                    model: model,
                    provider: provider,
                    cost: i == 0 ? cost : 0,
                    latency: 0,
                    inTok: i == 0 ? inTok : 0,
                    outTok: i == 0 ? outTok : 0,
                    toolName: toolName,
                    content: row.content,
                    startTime: startTime
                ))
            }
        }
        return rows
    }

    /// Edge I/O attributed to the TARGET node (the tool being invoked).
    /// Token/cost stay zero — those live on the agent's llm_details and
    /// counting them here would double-bill. Latency is also zero for
    /// normal edges, but the external-invocation edge (source == "")
    /// gets the target root's wall-clock total_time attached to its
    /// FIRST emitted row, so <sum> at any group level surfaces the
    /// run's true duration without overlap-multi-counting.
    private static func collectEdgeIO(
        _ raw: [String: Any],
        runId: String,
        sessionId: String,
        nameById: [String: String],
        prefixById: [String: String],
        rootLatencyById: [String: Double],
        startTimeById: [String: TimeInterval]
    ) -> [PendingRow] {
        guard let target = raw["target"] as? String,
              let rawName = nameById[target]
        else {
            log.trace("collectEdgeIO: edge target missing or unresolved")
            return []
        }
        let toolName = (prefixById[target] ?? "") + rawName
        let startTime = startTimeById[target] ?? 0
        let source = raw["source"] as? String ?? ""
        let edgeId = raw["identifier"] as? String ?? "\(source)-\(target)"
        let details = raw["details"] as? [String: Any]

        // Pop the root's wall-clock onto the first row of an external-
        // invocation edge; remaining rows carry 0.
        var pendingRootLatency: Double =
            source.isEmpty ? (rootLatencyById[target] ?? 0) : 0
        func takeLatency() -> Double {
            defer { pendingRootLatency = 0 }
            return pendingRootLatency
        }

        var rows: [PendingRow] = []

        if let args = details?["input_args"] as? [Any] {
            for (i, arg) in args.enumerated() {
                rows.append(PendingRow(
                    nodeId: target,
                    runId: runId,
                    sessionId: sessionId,
                    messageId: "\(edgeId)-arg\(i)",
                    source: "edge",
                    direction: "Input",
                    role: "arg\(i)",
                    model: "",
                    provider: "",
                    cost: 0,
                    latency: takeLatency(),
                    inTok: 0,
                    outTok: 0,
                    toolName: toolName,
                    content: stringify(arg),
                    startTime: startTime
                ))
            }
        }

        if let kwargs = details?["input_kwargs"] as? [String: Any] {
            // Sort keys for deterministic "first row" placement of the
            // root's wall-clock carrier (Swift dict iteration is unordered).
            for k in kwargs.keys.sorted() {
                let v = kwargs[k] as Any
                rows.append(PendingRow(
                    nodeId: target,
                    runId: runId,
                    sessionId: sessionId,
                    messageId: "\(edgeId)-kwarg-\(k)",
                    source: "edge",
                    direction: "Input",
                    role: "kwarg:\(k)",
                    model: "",
                    provider: "",
                    cost: 0,
                    latency: takeLatency(),
                    inTok: 0,
                    outTok: 0,
                    toolName: toolName,
                    content: stringify(v),
                    startTime: startTime
                ))
            }
        }

        for (i, item) in extractOutput(details?["output"]).enumerated() {
            rows.append(PendingRow(
                nodeId: target,
                runId: runId,
                sessionId: sessionId,
                messageId: "\(edgeId)-out\(i)",
                source: "edge",
                direction: "Output",
                role: item.role,
                model: "",
                provider: "",
                cost: 0,
                latency: takeLatency(),
                inTok: 0,
                outTok: 0,
                toolName: toolName,
                content: item.content,
                startTime: startTime
            ))
        }
        return rows
    }

    /// Normalize an edge output (which the schema declares loosely) into a
    /// list of (role, content) rows. Four real shapes observed in the
    /// sample data, plus null:
    ///   - dict with non-empty `message_history` → one row per transcript
    ///     message (user-chosen "Transcript only" behavior).
    ///   - dict without message_history (e.g. tune_resume's structured
    ///     result) → one row per top-level (key, value).
    ///   - list (e.g. web_search's array of result dicts) → one row per
    ///     element, role "result<i>".
    ///   - string (e.g. anonymize_resume, draft_email) → one row.
    ///   - null / missing → no rows (e.g. root call that has no return).
    private static func extractOutput(_ output: Any?) -> [(role: String, content: String)] {
        guard let output, !(output is NSNull) else { return [] }

        if let dict = output as? [String: Any] {
            if let history = dict["message_history"] as? [[String: Any]], !history.isEmpty {
                return history.map { msg in
                    (role: (msg["role"] as? String) ?? "assistant",
                     content: (msg["content"] as? String) ?? "")
                }
            }
            // Stable iteration order so identical inputs give identical signposts.
            return dict.keys.sorted().map { key in
                (role: key, content: stringify(dict[key] as Any))
            }
        }

        if let list = output as? [Any] {
            return list.enumerated().map { (i, v) in
                (role: "result\(i)", content: stringify(v))
            }
        }

        if let s = output as? String {
            return [(role: "result", content: s)]
        }

        return [(role: "result", content: stringify(output))]
    }

    // MARK: - Emission

    /// Assigns each row a single GLOBAL emit-order index — the counter never
    /// resets per node or per direction, so every FlowIO row gets a unique
    /// "0001 role", "0002 role", … across the whole run. This makes the flat
    /// Tool I/O list read top-to-bottom in emit order when sorted by Item.
    /// Width is the digit count of the total row count, floored at 2 so small
    /// runs still read as "01"/"02".
    private static func emitAll(rows: [PendingRow]) {
        let width = max(2, String(rows.count).count)
        for (i, r) in rows.enumerated() {
            let displayRole = "\(String(format: "%0\(width)d", i + 1)) \(r.role)"
            emitEvent(row: r, displayRole: displayRole)
        }
    }

    // Empty-string fallbacks ("-" / "unknown" / "<empty>") and content
    // sanitization (newline/tab/backslash escaping) are handled inside
    // RailtracksSignposts.emit(_:) so the schema's wire-format invariants
    // stay with the schema, not here.
    private static func emitEvent(row r: PendingRow, displayRole: String) {
        RailtracksSignposts.emit(FlowIO(
            nodeId: r.nodeId,
            sessionId: r.sessionId,
            runId: r.runId,
            messageId: r.messageId,
            source: r.source,
            direction: r.direction,
            role: r.role,
            model: r.model,
            provider: r.provider,
            cost: r.cost,
            latency: r.latency,
            inputTokens: r.inTok,
            outputTokens: r.outTok,
            displayRole: displayRole,
            toolName: r.toolName,
            content: r.content,
            startTime: r.startTime
        ))
    }

    // MARK: - Helpers

    private static func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: data, encoding: .utf8)
        } catch {
            // Caught and dropped — the caller falls back to a description.
            log.warning("failed to serialize value to JSON; falling back to description: \(error)")
            return nil
        }
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return compactJSON(value) ?? "\(value)"
    }
}
