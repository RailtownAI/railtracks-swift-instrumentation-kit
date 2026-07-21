//
//  FlowGraphMapper.swift
//  RailtracksInstrumentationKit
//
//  Opt-in helper: walks a parsed RTSFlowGraph tree and emits the full set
//  of FlowTreeNode / FlowGraphNode / FlowIO signposts so the
//  Railtracks Instrumentation tool can render the run. Bakes in JSONTools'
//  rendering choices (skip rules, display prefixes, displayRole numbering).
//  Consumers who want different choices should use RailtracksSignposts
//  directly and write their own walk.
//

import Foundation

public enum FlowGraphMapper {

    public struct EmitCounts: Sendable, Equatable {
        public let nodes: Int
        public let edges: Int
        public let ioRows: Int

        public init(nodes: Int, edges: Int, ioRows: Int) {
            self.nodes = nodes
            self.edges = edges
            self.ioRows = ioRows
        }
    }

    // MARK: - Public entry points

    /// Parse the JSON once, then run two independent passes: the FlowNode
    /// tree walk (emits FlowGraphNode/FlowTreeNode) and the
    /// FlowIOMapper pass (emits one FlowIO event per prompt/tool-call/arg/
    /// transcript line). The prefix map derived from a preorder traversal
    /// feeds FlowIOMapper so each toolName carries a zero-padded sort index
    /// plus a depth indent — the aggregation list then renders rows in
    /// tree-walk order regardless of the active sort column.
    public static func emit(data: Data) throws -> EmitCounts {
        let json = try JSONSerialization.jsonObject(with: data)
        let roots = FlowNode.from(json: json)
        let (nodeCount, edgeCount) = walkAll(nodes: roots)
        let ioCount = FlowIOMapper.emit(json: json, prefixById: displayPrefixesByNodeId(roots: roots))
        log.debug("emit(data:) parsed \(roots.count) root(s) → nodes=\(nodeCount) edges=\(edgeCount) ioRows=\(ioCount)")
        return EmitCounts(nodes: nodeCount, edges: edgeCount, ioRows: ioCount)
    }

    public static func emit(nodes: [FlowNode]) -> EmitCounts {
        let (nodeCount, edgeCount) = walkAll(nodes: nodes)
        log.debug("emit(nodes:) \(nodes.count) root(s) → nodes=\(nodeCount) edges=\(edgeCount)")
        return EmitCounts(nodes: nodeCount, edges: edgeCount, ioRows: 0)
    }

    // MARK: - Tree walk

    private static func walkAll(nodes: [FlowNode]) -> (nodes: Int, edges: Int) {
        var nodeCount = 0
        var edgeCount = 0
        for root in nodes {
            walk(root, ancestors: [], counts: &nodeCount, edges: &edgeCount)
        }
        return (nodeCount, edgeCount)
    }

    /// Preorder-walk the tree to produce a display prefix per node:
    /// "<zero-padded order> <indent>" — e.g. "03     " for the 3rd visited
    /// node at depth 2. Sorts lexically into tree-walk order. First-seen wins
    /// for nodes that re-appear (defensive against multi-parent attachment).
    private static func displayPrefixesByNodeId(roots: [FlowNode]) -> [String: String] {
        var visits: [(id: String, depth: Int)] = []
        func visit(_ node: FlowNode, depth: Int) {
            visits.append((node.nodeId, depth))
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }

        let width = max(2, String(visits.count).count)
        var prefixes: [String: String] = [:]
        for (i, item) in visits.enumerated() where prefixes[item.id] == nil {
            let order = String(format: "%0\(width)d", i + 1)
            let indent = String(repeating: "\t", count: item.depth)
            prefixes[item.id] = "\(order) \(indent)"
        }
        return prefixes
    }
    
    // MARK: - Private
    
    /// Each emitted node carries its own pre-summed metrics. The Flow Tree
    /// aggregation uses <max> (not <sum>) so parent rows surface the
    /// dominating node's value rather than re-summing children that are
    /// already counted in their ancestor's totals.
    ///
    /// EVERY node emits exactly one FlowTreeNode — no skip rules. Earlier
    /// versions skipped roots and non-leaf tools to avoid junk sub-rows
    /// under the old repeat-the-name forward fill, but that broke
    /// single-node flows (zero events → empty Flow Tree), dropped a root
    /// agent's llm_details from the rollup, and lost per-node fields the
    /// aggregation can't synthesize from descendants (a non-leaf node's
    /// own startTime and error). With the trailing-fill placeholder the
    /// only cost is one filler sub-row per non-leaf node, and the mapper
    /// renders identically to a direct emitter.
    private static func walk(
        _ node: FlowNode,
        parent: FlowNode? = nil,
        ancestors: [String],
        counts: inout Int,
        edges: inout Int
    ) {
        RailtracksSignposts.emit(FlowGraphNode(
            nodeId: node.nodeId,
            parentId: parent?.nodeId ?? "",
            sessionId: node.sessionId,
            runId: node.runId,
            nodeType: node.nodeType,
            parentType: parent?.nodeType,
            error: node.error,
            parentError: parent?.error ?? false,
            cost: node.cost,
            model: node.model,
            parentName: parent?.name ?? "",
            name: node.name,
            startTime: node.startTime
        ))

        // Call emit inline (NOT through a wrapper) so the first frame
        // in the captured backtrace is this walk() call site — wrapping
        // would shift the source-jump arrow into the wrapper instead.
        RailtracksSignposts.emit(FlowTreeNode(
            nodeId: node.nodeId,
            sessionId: node.sessionId,
            runId: node.runId,
            nodeType: node.nodeType,
            model: node.model,
            provider: node.provider,
            cost: node.cost,
            latency: node.latency,
            inputTokens: node.inputTokens,
            outputTokens: node.outputTokens,
            error: node.error,
            ancestors: ancestors,
            name: node.name,
            startTime: node.startTime
        ))
        counts += 1

        // The object graph draws edges from FlowGraphNode.parentId, so no
        // separate edge event is emitted — `edges` just counts parent→child
        // links for EmitCounts.
        let childAncestors = ancestors + [node.name]
        for child in node.children {
            edges += 1
            walk(child, parent: node, ancestors: childAncestors,
                 counts: &counts, edges: &edges)
        }
    }
}

