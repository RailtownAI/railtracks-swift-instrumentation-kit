# RailtracksInstrumentationKit

A Swift package that emits [`os_signpost`](https://developer.apple.com/documentation/os/ossignposter)
events which the **Railtracks Instrumentation** custom Instruments package
renders as agent/flow timelines, trees, and graphs.

You construct small value-type events (`FlowTreeNode`, `FlowGraphNode`,
`FlowIO`, `AgentRun`) and hand them to `RailtracksSignposts`.
The package owns the signpost wire format, so producers never touch the
`os_signpost` message strings or the schema's field layout.

There are two ways to use it:

- **Live emission** — your agent runtime emits events as it executes.
- **Turnkey replay** — you already have an `RTSFlowGraph` JSON document and
  want the whole thing visualized in one call (`FlowGraphMapper.emit(data:)`).

---

## Requirements

- macOS 15+
- Swift 6 toolchain (Xcode 16+)
- **Instruments** (ships with Xcode) plus the **Railtracks Instrumentation**
  `.instrpkg` installed — see [Companion Instruments package](#companion-instruments-package).

---

## Installation

### Swift Package Manager (remote)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/RailtownAI/railtracks-swift-instrumentation-kit.git", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["RailtracksInstrumentationKit"]
    )
]
```

### Xcode

File → Add Package Dependencies… → paste
`https://github.com/RailtownAI/railtracks-swift-instrumentation-kit.git`.

### Local path (while iterating)

```swift
.package(path: "../RailtracksInstrumentationKit")
```

Then in your code:

```swift
import RailtracksInstrumentationKit
```

---

## Quick start

```swift
import RailtracksInstrumentationKit

// One point event per agent/tool node in your flow.
RailtracksSignposts.emit(FlowTreeNode(
    nodeId: "node-123",
    sessionId: "session-abc",
    runId: "run-1",
    nodeType: .agent,           // .agent | .tool | .custom("…")
    model: "claude-opus-4-8",
    cost: 0.0423,
    latency: 12.4,
    inputTokens: 1840,
    outputTokens: 233,
    name: "Orchestrator",
    startTime: Date().timeIntervalSince1970
))
```

Profile your process with the **Railtracks Instrumentation** template and the
event shows up in the Flow Tree, Object Graph, and the other views.

---

## Usage — live emission

Emit events from your agent runtime as work happens. Each `emit` overload maps
to one view in the Instruments package.

### Point events

```swift
// Flow Tree — per agent/tool node, drives the aggregation + Call Tree.
RailtracksSignposts.emit(FlowTreeNode(
    nodeId: node.id, sessionId: session, runId: run,
    nodeType: .agent, model: "claude-opus-4-8",
    cost: 0.04, latency: 12.4, inputTokens: 1840, outputTokens: 233,
    error: false,
    ancestors: ["Root", "Orchestrator"],   // root → parent chain
    name: "draft_email",
    startTime: startedAt                    // epoch seconds
))

// Flow Object Graph — per node, with its parent so edges can be drawn.
RailtracksSignposts.emit(FlowGraphNode(
    nodeId: node.id, parentId: parent.id,
    sessionId: session, runId: run,
    nodeType: .agent, parentType: .agent,
    error: false, parentError: false,
    cost: 0.04, model: "claude-opus-4-8",
    parentName: "Orchestrator", name: "draft_email",
    startTime: startedAt
))

// Tool I/O — one event per logical input/output message.
RailtracksSignposts.emit(FlowIO(
    nodeId: node.id, sessionId: session, runId: run,
    messageId: "node-123-in-0",
    source: "llm",            // "llm" | "edge"
    direction: "Input",       // "Input" | "Output"
    role: "system",
    model: "claude-opus-4-8",
    displayRole: "01 system", // zero-padded order key for sorting
    toolName: "draft_email",
    content: messageText,
    startTime: startedAt
))
```

> **Source-jump backtraces.** `emit(FlowTreeNode:)` and `emit(FlowGraphNode:)`
> capture the *caller's* `#file`/`#line` and an 8-frame backtrace. Call them
> **directly** from the site you want recorded — wrapping them in a helper
> shifts the resolved frame into the wrapper.

### Interval events (agent durations)

`AgentRun` is an interval: `begin` returns a handle you must pass to `end`.
The handle pairs the two signposts so Instruments draws a duration bar on the
**Agent Runs** lane (one swimlane per agent name; red on error).

The lane orders swimlanes by plain string comparison of the name, so `begin`
prefixes the name with a sortable key: `"<run>-<index> Name"`, e.g.
`"00-000 Orchestrator"`, `"00-001 draft_email"`, `"01-000 Orchestrator"`.
`run` is the 0-based ordinal of the `runId` among all runs this process has
begun an agent for (first-seen order); `index` is the 0-based start order of
the agent within that run. A recording that contains several flows therefore
reads top-to-bottom as "flows in the order they started, agents in the order
they started within each flow", and two flows whose root agent shares a name
get separate lanes. Both numbers are exposed on the handle (`runOrdinal`,
`index`). Pass a `runId` that is stable for the whole flow and distinct
between flows, or every agent lands in one run.

```swift
let handle = RailtracksSignposts.begin(AgentRun(
    name: "Orchestrator",
    nodeId: node.id,
    sessionId: session,
    runId: run,
    parentName: ""            // "" for the root agent
))
defer { RailtracksSignposts.end(handle, error: didFail) }

// ... run the agent ...
```

Dropping the handle leaves the interval open and the bar runs forever — always
`end` it (a `defer` is the safest pattern).

`AgentRun` remains for older SDK versions. SDKs that emit one interval per node
call use `NodeRun` below.

### Interval events (node durations)

`NodeRun` is one interval per node call — agent, tool, or function — nested
under its caller. Like `AgentRun`, `begin` returns a handle you must pass to
`end`; Instruments draws the bar on the **Node Runs** lane (red on error,
otherwise purple for agents, blue for tools, green for anything else).

Each call lands in a lane named `"<key> Name"`, where the key nests under the
caller's lane: `"00-000 MathWorkflow"`, `"00-000.000 Math Agent"`,
`"00-000.000.000 add"`, `"00-000.000.001 multiply"`. A root key is
`<run>-<root>` (the run's first-seen ordinal, then the root lane's order within
the run); a child appends `.<child>`, the lane's order under its caller. Sorted
as strings, the lanes read as the call tree.

- **Parent lookup.** A call nests under the lane of the *live* call whose
  `nodeId` equals its `parentNodeId`. Begin the caller before its children.
  An empty, unknown, or already-ended `parentNodeId` gets a root lane.
- **Shared lanes.** Every call of the same node (`nodeType` + `name`) under the
  same caller lane shares one lane, so repeated tool calls line up. The same
  node under a different caller gets its own lane there.
- **Slots.** Calls that overlap in one lane get distinct slots (the lowest
  free one, from 0), shown as sub-rows. `end` releases the slot.
- **Type slots.** Alongside the call tree, every call also lands in one of
  three fixed lanes: **Agents** (`.agent`), **Tools** (`.tool`), and **Nodes**
  (everything else, including `"Function"`). Those lanes are global, so the
  `typeSlot` is the lowest slot not held by another *live* call of the same
  type, across all runs and lanes. Parallel calls of one type get separate
  sub-rows; `end` releases the type slot too.
- **Input.** `input` is a short summary of what the node received — the prompt
  for an agent, the arguments for a tool — shown when you hover the bar. It is
  emitted as a **public** signpost string, so it is readable by anyone with
  the unified log; don't pass secrets. Whitespace runs collapse to one space,
  and it is capped at 512 UTF-8 bytes (cut on a character boundary, ending in
  "…"), which keeps the begin message under the unified log's ~1 KB limit.

```swift
let agent = RailtracksSignposts.begin(NodeRun(
    name: "Math Agent",
    nodeType: .agent,
    nodeId: agentNode.id,
    parentNodeId: "",         // "" for a root call
    sessionId: session,
    runId: run,
    input: prompt             // shown on hover; public in the unified log
))
defer { RailtracksSignposts.end(agent, error: didFail) }

let tool = RailtracksSignposts.begin(NodeRun(
    name: "add", nodeType: .tool,
    nodeId: toolNode.id, parentNodeId: agentNode.id,
    sessionId: session, runId: run, parentName: "Math Agent",
    input: #"{"a": 2, "b": 3}"#
))
// ... run the tool ...
RailtracksSignposts.end(tool)
```

The handle exposes the assigned `lane`, `slot` and `typeSlot`. An un-ended
handle leaves the bar open and keeps both slots held.

---

## Usage — turnkey replay from RTSFlowGraph JSON

If you already have an `RTSFlowGraph` JSON document, one call emits the full set
of events (`FlowTreeNode` + `FlowGraphNode` + `FlowIO`) with all the rendering
policy (skip rules, tree-walk ordering, displayRole numbering) applied for you:

```swift
let data = try Data(contentsOf: jsonURL)
let counts = try FlowGraphMapper.emit(data: data)
print("emitted \(counts.nodes) nodes, \(counts.edges) edges, \(counts.ioRows) I/O rows")
```

If you've already parsed the tree yourself:

```swift
let roots: [FlowNode] = try FlowNode.from(data: data)
let counts = FlowGraphMapper.emit(nodes: roots)   // FlowTreeNode + FlowGraphNode only (no Tool I/O)
let totals = roots.totals                          // aggregate latency / tokens / cost
```

`FlowNode` is the parsed tree (one node per JSON node, children wired from
`edges[].source → target`). Use this path when your producer speaks RTSFlowGraph
JSON; use live emission when you control the agent code directly.

---

## Event reference

| Type            | View it drives        | Required to emit                                                                |
| --------------- | --------------------- | ------------------------------------------------------------------------------- |
| `FlowTreeNode`  | Flow Tree, Call Tree  | `nodeId`, `sessionId`, `runId`, `nodeType`, `name`                               |
| `FlowGraphNode` | Flow Object Graph     | `nodeId`, `sessionId`, `runId`, `nodeType`, `name`                              |
| `FlowIO`        | Tool I/O              | `nodeId`, `sessionId`, `runId`, `messageId`, `source`, `direction`, `role`, `displayRole`, `toolName`, `content` |
| `NodeRun`       | Node Runs (timeline)  | `name`, `nodeType`; `nodeId`/`parentNodeId` for nesting (plus `sessionId`/`runId`/`parentName`/`input`) |
| `AgentRun`      | Agent Runs (timeline) | `name` (plus `nodeId`/`sessionId`/`runId`/`parentName` for correlation); older SDK versions |

All other fields have defaults. Every event type is `Sendable` + `Codable`, so
you can build them on background tasks, serialize, queue, or replay.

> **"Required to emit" ≠ "required to build the tree."** The fields above are
> the minimum for an event to *appear*. To get a connected **hierarchy** you
> must also supply the structural fields below — see
> [Building the tree and graph](#building-the-tree-and-graph).

### `nodeType`

`nodeType` is a `NodeType` enum, not a string:

```swift
public enum NodeType { case agent, tool, custom(String) }
```

`.agent` and `.tool` are the types the Instruments schema styles specially
(`.agent` → purple/sparkles; everything else → blue/wrench). `.custom("…")`
preserves any other type losslessly — it renders like a Tool but keeps its real
name in the Type columns (on the Node Runs lane it is colored green). The on-the-wire value is `nodeType.rawValue`
(`"Agent"` / `"Tool"` / the custom string), so the enum doesn't change the
signpost format. `FlowGraphNode.parentType` is an optional `NodeType?` — `nil`
for a root, otherwise it must equal the parent's `nodeType` (see above).

### `startTime`

`FlowTreeNode`, `FlowGraphNode`, and `FlowIO` carry a `startTime: TimeInterval`.
Send **absolute Unix-epoch seconds** (`Date().timeIntervalSince1970`); the
Instruments column date-formats it (date + `hh:mm:ss`) and rows sort
chronologically. This matters because the implicit signpost timestamp reflects
*emit* time — useless when a whole run is replayed at once. Any monotonic scale
sorts correctly, but only epoch seconds date-format meaningfully.

---

## Building the tree and graph

Emitting nodes is not enough to get a connected **hierarchy** — you have to
tell each node where it sits. The two structural views are built differently:

### Flow Tree — built from `ancestors`

`FlowTreeNode.ancestors` is the chain of **ancestor names**, root first, down
to (but not including) the node itself. The aggregation nests rows by walking
that chain, so the tree is only as deep as the chain you provide.

```swift
// Root agent
RailtracksSignposts.emit(FlowTreeNode(..., name: "Orchestrator",  ancestors: []))
// Child of Orchestrator
RailtracksSignposts.emit(FlowTreeNode(..., name: "draft_email",   ancestors: ["Orchestrator"]))
// Grandchild
RailtracksSignposts.emit(FlowTreeNode(..., name: "web_search",    ancestors: ["Orchestrator", "draft_email"]))
```

Omit `ancestors` and every node lands flat at the top level. The chain is
capped at 5 levels (`a0`…`a4`) in the current schema.

### Flow Object Graph — built from `parentId` **and** the parent twins

The object graph has no separate node table: **each event describes both its
own node and its parent.** Instruments draws one box per node by *merging* the
rows where that node appears — once where it's the child, and once in each of
*its* children's events where it's the parent. For the merge to hold, a node's
identity must be **identical** in both places. That means a child's parent
fields must exactly equal the parent node's own fields:

| Child supplies… | must equal the parent's own… |
| --------------- | ---------------------------- |
| `parentId`      | `nodeId`                     |
| `parentName`    | `name`                       |
| `parentType`    | `nodeType`                   |
| `parentError`   | `error`                      |

```swift
// Parent
RailtracksSignposts.emit(FlowGraphNode(
    nodeId: "orch-1", parentId: "",          // root → empty parentId
    sessionId: s, runId: r,
    nodeType: .agent, name: "Orchestrator", error: false
))

// Child — its parent* fields mirror the parent above exactly
RailtracksSignposts.emit(FlowGraphNode(
    nodeId: "draft-1", parentId: "orch-1",
    sessionId: s, runId: r,
    nodeType: .tool,  name: "draft_email",  error: false,
    parentType: .agent, parentName: "Orchestrator", parentError: false
))
```

Rules of thumb:

- **Roots** pass `parentId: ""` — Instruments treats the unresolved edge as a
  graph root.
- If a child's `parent*` fields disagree with the parent's own fields (even one
  of them), the node **won't merge** and the graph fragments — the parent
  shows up as two disconnected boxes.
- `nodeId` is the merge key, so it must be **stable and unique** per node across
  every event that references it (the node's own event and all its children's).

> Building from `RTSFlowGraph` JSON? `FlowGraphMapper.emit(data:)` derives all
> of this for you (`parentId` from `edges[].source → target`, the twins from the
> resolved parent, `ancestors` from the tree walk). You only need these rules
> when emitting live.

---

## Companion Instruments package

This kit only emits signposts; the rendering lives in the
**Railtracks Instrumentation** `.instrpkg` (in the `VisualizerInstruments`
Xcode project). The two must agree on:

- **Subsystem:** `io.railtown.visualizer.observability` (`RailtracksSignposts.subsystem`)
- **Category:** `Observation` (`RailtracksSignposts.category`)

To install the Instruments package: build its `RailtracksInstrumentation`
scheme once (Xcode copies the built `.instrdst` into Instruments' Packages
folder), or copy the built product into
`~/Library/Application Support/Instruments/Packages/` and relaunch Instruments.
Then start a recording with the **Railtracks Instrumentation** template.

### Views

| View                | Source events                | What it shows                                          |
| ------------------- | ---------------------------- | ----------------------------------------------------- |
| Flow Tree           | `FlowTreeNode`               | 5-level aggregation of agents/tools with cost/tokens  |
| Flow Object Graph   | `FlowGraphNode`              | directed parent→child node graph                      |
| Tool I/O            | `FlowIO`                     | per-tool input/output messages                        |
| Call Tree           | `FlowTreeNode`               | backtraces with source-jump to the emit site          |
| Node Runs           | `NodeRun`                    | per-node-call duration bars, nested by caller         |
| Agent Runs          | `AgentRun`                   | per-agent duration bars (older SDK versions)          |

---

## Logging

The library emits diagnostic logs via [`apple/swift-log`](https://github.com/apple/swift-log),
following the [Swift library log-level guidance](https://www.swift.org/documentation/server/guides/libraries/log-levels.html):

- **`.trace`** — one line per emitted event (`FlowTreeNode`/`FlowGraphNode`/
  `FlowIO`, `NodeRun`/`AgentRun` begin/end) and per benign skip (tool nodes with no
  `llm_details`, deduplicated edges).
- **`.debug`** — per-call summaries (`emit(data:)` node/edge/IO counts, parsed
  run/root counts).
- **`.warning`** — only when data is silently dropped or malformed: input JSON
  missing a top-level `runs` key, or a value that can't be serialized to JSON
  (falls back to its description).

The logger is `internal` (label `railtracks.instrumentation.log`), so it never
collides with your app's own `log`. **The library never calls
`LoggingSystem.bootstrap`** — that's your job, and it controls the backend and
level. swift-log's default level is `.info`, so all `.trace`/`.debug` lines stay
silent until you lower it; `.warning` always shows. Messages use `@autoclosure`,
so per-event `.trace` interpolation costs ~nothing when the level filters it out.

```swift
import Logging

// Once, at app startup:
LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }

// To see the library's trace/debug output, lower the level on its label:
var log = Logger(label: "railtracks.instrumentation.log")
log.logLevel = .trace
```

> Tip: if a flow renders empty in Instruments, run with the level at `.trace`
> and watch for the `warning "input JSON missing top-level 'runs'"` line — the
> most common cause of an empty visualization.

---

## Notes

- **Profiling a replay tool?** Instruments must be able to locate your binary to
  symbolicate the Call Tree / source-jump backtraces (File → Symbols…). Debug
  builds embed DWARF; for automatic symbolication set
  `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`.
- The signposter is stateless and safe to call from any thread/task.
