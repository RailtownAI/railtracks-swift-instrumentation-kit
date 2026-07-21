//
//  FlowGraphNode.swift
//  RailtracksInstrumentationKit
//
//  Created by Fabricio Sperotto Sffair on 27/05/26.
//

import Foundation

/// One point event per node in the directed object graph. Root nodes pass
/// `parentId == ""` so Instruments treats the inbound edge as unresolvable
/// and surfaces the row as a graph root.
public struct FlowGraphNode: Sendable, Codable, Equatable {
    public var nodeId: String
    public var parentId: String
    public var sessionId: String
    public var runId: String
    public var nodeType: NodeType
    /// The parent's type, or `nil` for a root (no parent). Must equal the
    /// parent node's own `nodeType` so the object graph merges the node
    /// across the rows where it appears — see the README's "Building the
    /// tree and graph".
    public var parentType: NodeType?
    public var error: Bool
    public var parentError: Bool
    public var cost: Double
    public var model: String
    public var parentName: String
    public var name: String
    /// When this node actually started running. Producer-supplied so the
    /// object graph's detail/list can be ordered chronologically. Any
    /// monotonic scale works (epoch seconds or seconds-since-run-start).
    public var startTime: TimeInterval

    public init(
        nodeId: String,
        parentId: String = "",
        sessionId: String,
        runId: String,
        nodeType: NodeType,
        parentType: NodeType? = nil,
        error: Bool = false,
        parentError: Bool = false,
        cost: Double = 0,
        model: String = "",
        parentName: String = "",
        name: String,
        startTime: TimeInterval = 0
    ) {
        self.nodeId = nodeId
        self.parentId = parentId
        self.sessionId = sessionId
        self.runId = runId
        self.nodeType = nodeType
        self.parentType = parentType
        self.error = error
        self.parentError = parentError
        self.cost = cost
        self.model = model
        self.parentName = parentName
        self.name = name
        self.startTime = startTime
    }
}
