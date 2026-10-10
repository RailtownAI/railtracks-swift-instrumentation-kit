//
//  NodeType.swift
//  RailtracksInstrumentationKit
//

/// The kind of a flow node.
///
/// `.agent` and `.tool` are the two types the Instruments schema styles
/// specially (Agent → purple/sparkles; everything else → blue/wrench).
/// `.custom` preserves any other `node_type` a producer emits, so the value
/// round-trips losslessly — though in Instruments a custom type renders like
/// a Tool, with its real string shown in the Type columns (the Node Runs
/// lane is the exception: it colors custom types green).
///
/// `rawValue` is the on-the-wire string ("Agent" / "Tool" / the custom name),
/// matching the schema's pattern literals verbatim — using the enum does not
/// change the signpost wire format.
public enum NodeType: Sendable, Equatable, Hashable {
    case agent
    case tool
    case custom(String)
}

extension NodeType: RawRepresentable {
    public init(rawValue: String) {
        switch rawValue {
        case "Agent": self = .agent
        case "Tool":  self = .tool
        default:      self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .agent:            return "Agent"
        case .tool:             return "Tool"
        case .custom(let name): return name
        }
    }
}

extension NodeType: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
