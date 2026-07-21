//
//  FlowTotals.swift
//  RailtracksInstrumentationKit
//
//  Created by Fabricio Sperotto Sffair on 27/05/26.
//

import Foundation

public struct FlowTotals: Equatable, Sendable {
    public var latency: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var cost: Double

    public init(latency: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0, cost: Double = 0) {
        self.latency = latency
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }
}
