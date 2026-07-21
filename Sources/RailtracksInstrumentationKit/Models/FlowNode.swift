//
//  FlowNode.swift
//  RailtracksInstrumentationKit
//
//  Opt-in helper: parses an RTSFlowGraph JSON document into a typed
//  parent→child tree. Consumers with RTSFlowGraph JSON can use this +
//  FlowGraphMapper.emit(data:) as a turnkey pipeline. Consumers
//  building events live in their own code use RailtracksSignposts.emit
//  directly and can ignore the walker entirely.
//

import Foundation

public struct FlowNode: Identifiable {
    public var id: String { nodeId }
    public let nodeId: String
    public let name: String
    public let nodeType: NodeType
    public let parentId: String      // "" for roots; derived from edges, not node.parent
    public let runId: String
    public let sessionId: String     // top-level session_id (shared across runs in the JSON)
    public let model: String
    public let provider: String
    public let cost: Double
    public let latency: Double
    public let inputTokens: Int
    public let outputTokens: Int
    /// Absolute Unix-epoch time (seconds) when this node started running,
    /// derived from `stamp.time − latency`. Surfaced via the time-since-epoch
    /// engineering type so Instruments date-formats it (date + hh:mm:ss) and
    /// rows sort chronologically. 0 when the JSON omits a stamp.
    public let startTime: TimeInterval

    public let error: Bool
    public var children: [FlowNode]

    public init(nodeId: String, name: String, nodeType: NodeType, parentId: String, runId: String, sessionId: String, model: String, provider: String, cost: Double, latency: Double, inputTokens: Int, outputTokens: Int, startTime: TimeInterval = 0, error: Bool, children: [FlowNode]) {
        self.nodeId = nodeId
        self.name = name
        self.nodeType = nodeType
        self.parentId = parentId
        self.runId = runId
        self.sessionId = sessionId
        self.model = model
        self.provider = provider
        self.cost = cost
        self.latency = latency
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.startTime = startTime
        self.error = error
        self.children = children
    }
    
    // MARK: - Build tree from raw RTSFlowGraph JSON
    public static func from(data: Data) throws -> [FlowNode] {
        let raw = try JSONSerialization.jsonObject(with: data)
        return from(json: raw)
    }

    public static func from(json: Any) -> [FlowNode] {
        guard let root = json as? [String: Any],
              let runs = root["runs"] as? [[String: Any]] else {
            log.warning("input JSON missing top-level 'runs'; returning no nodes")
            return []
        }
        let sessionId = root["session_id"] as? String ?? ""
        let roots = runs.flatMap { buildTree(from: $0, sessionId: sessionId) }
        log.debug("parsed \(runs.count) run(s), \(roots.count) root node(s)")
        return roots
    }

    // MARK: - Private
    // Nodes use a self-referencing `parent` field (creation snapshot, not actual parent).
    // The real parent→child relationship is encoded in `edges[].source → target`.
    private static func buildTree(from run: [String: Any], sessionId: String) -> [FlowNode] {
        let runId    = run["run_id"] as? String ?? ""
        let rawNodes = run["nodes"]  as? [[String: Any]] ?? []
        let rawEdges = run["edges"]  as? [[String: Any]] ?? []

        // Pass 1: flat node map (parentId empty — will be filled by edges)
        var nodeMap: [String: FlowNode] = [:]
        for raw in rawNodes {
            let node = parseNode(raw, runId: runId, sessionId: sessionId)
            nodeMap[node.nodeId] = node
        }

        // Pass 2: build parent→child from edges (deduplicate to avoid repeated subtrees).
        // Also flag each target node whose inbound edge reports a "Failed" status —
        // RTSFlowGraph only carries status on the edge, not the node itself, so the
        // node's error state is its inbound edge's status. First inbound edge wins
        // for nodes with multiple inbound edges (shouldn't happen in a tree).
        var childIds: [String: [String]] = [:]
        var allTargets: Set<String> = []
        var seenEdges: Set<String> = []
        var errorByTarget: [String: Bool] = [:]
        for raw in rawEdges {
            guard let source = raw["source"] as? String, !source.isEmpty,
                  let target = raw["target"] as? String else {
                log.trace("skipping edge with missing source/target")
                continue
            }
            guard seenEdges.insert("\(source)→\(target)").inserted else { continue }
            childIds[source, default: []].append(target)
            allTargets.insert(target)
            let status = (raw["details"] as? [String: Any])?["status"] as? String
            if errorByTarget[target] == nil { errorByTarget[target] = (status == "Failed") }
        }

        let rootIds = nodeMap.keys.filter { !allTargets.contains($0) }

        func buildSubtree(id: String, parentId: String) -> FlowNode? {
            guard let base = nodeMap[id] else { return nil }
            let kids = childIds[id]?.compactMap { buildSubtree(id: $0, parentId: id) } ?? []

            return FlowNode(
                nodeId: base.nodeId,
                name: base.name,
                nodeType: base.nodeType,
                parentId: parentId,
                runId: base.runId,
                sessionId: base.sessionId,
                model: base.model,
                provider: base.provider,
                cost: base.cost,
                latency: base.latency,
                inputTokens: base.inputTokens,
                outputTokens: base.outputTokens,
                startTime: base.startTime,
                error: errorByTarget[id] ?? false,
                children: kids
            )
        }

        return rootIds.compactMap { buildSubtree(id: $0, parentId: "") }
    }

    private static func parseNode(_ raw: [String: Any], runId: String, sessionId: String) -> FlowNode {
        let nodeId: String
        if let id = raw["identifier"] as? String {
            nodeId = id
        } else {
            nodeId = UUID().uuidString
            log.debug("node missing 'identifier'; generated \(nodeId)")
        }
        let nodeType = NodeType(rawValue: raw["node_type"] as? String ?? "Tool")
        let name     = raw["name"]       as? String ?? nodeId

        let internals  = (raw["details"] as? [String: Any])?["internals"] as? [String: Any]
        let llms       = (internals?["llm_details"] as? [[String: Any]]) ?? []
        let latency = (internals?["latency"] as? [String: Any])?["total_time"] as? Double ?? 0

        // The stamp records when the node FINISHED ("Finished executing X");
        // subtract latency to approximate when it started. Kept as absolute
        // epoch seconds so the time-since-epoch column date-formats it.
        // Producers with a real start time should send it directly instead.
        let stampTime = (raw["stamp"] as? [String: Any])?["time"] as? Double ?? 0
        let startTime: TimeInterval = stampTime > 0 ? stampTime - latency : 0

        // Model/provider are stable across an agent's calls; sum metrics across
        // all calls so an agent with N llm_details reports its full consumption.
        let model    = llms.first?["model_name"]     as? String ?? ""
        let provider = llms.first?["model_provider"] as? String ?? ""
        let cost      = llms.reduce(0.0) { $0 + (($1["total_cost"]    as? Double) ?? 0) }
        let inputTok  = llms.reduce(0)   { $0 + (($1["input_tokens"]  as? Int)    ?? 0) }
        let outputTok = llms.reduce(0)   { $0 + (($1["output_tokens"] as? Int)    ?? 0) }

        return FlowNode(
            nodeId: nodeId,
            name: name,
            nodeType: nodeType,
            parentId: "",
            runId: runId,
            sessionId: sessionId,
            model: model,
            provider: provider,
            cost: cost,
            latency: latency,
            inputTokens: inputTok,
            outputTokens: outputTok,
            startTime: startTime,
            error: false,
            children: []
        )
    }
}

extension Array where Element == FlowNode {
    /// Run totals:
    /// - latency: wall-clock total_time of the root nodes — the only
    ///   non-overlapping duration. Per-node total_times nest inside each
    ///   other; summing them would multi-count the same elapsed seconds.
    /// - tokens/cost: summed across every Agent in the tree. Each agent's
    ///   llm_details capture its own LLM API calls, which are billed
    ///   independently of any parent agent's calls — so they genuinely
    ///   add up to the run's real LLM consumption.
    public var totals: FlowTotals {
        var t = FlowTotals()
        for root in self {
            t.latency += root.latency
            root.walkAgents { agent in
                t.inputTokens  += agent.inputTokens
                t.outputTokens += agent.outputTokens
                t.cost         += agent.cost
            }
        }
        return t
    }
}

private extension FlowNode {
    func walkAgents(_ visit: (FlowNode) -> Void) {
        if nodeType == .agent { visit(self) }
        for child in children { child.walkAgents(visit) }
    }
}

