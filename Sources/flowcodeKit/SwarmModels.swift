//
//  SwarmModels.swift
//  flowcodeKit — Phase 8 (orchestration / swarm visualization). DEFAULT OFF.
//
//  The observable model behind the swarm constellation HUD. `SwarmState` consumes the
//  typed `SwarmEvent`s decoded by `SwarmJSONL` and maintains a capped set of `AgentNode`s
//  plus an aggregated "done" arc count for runs that blow past the visible cap.
//
//  Honesty boundary (plan §5/§8): this is READ-ONLY observation built on the file-tail
//  truth. Tokens/cost are only authoritative on completion (`agentDone`), so a working
//  node carries no trustworthy cost — we leave `tokens`/`cost` nil until the parent
//  `toolUseResult` lands. We never claim to read a mid-run token stream.
//
//  The update functions (`applyAgentSpawn` / `applyToolUse` / `applyAgentDone` / `collapse`)
//  are PURE in effect: same event sequence -> same state. They take decoded values (not
//  files), which is what makes the whole model unit-testable from the selftest harness
//  without FSEvents, AppKit, or disk access.
//

import Foundation
import Observation

// MARK: - AgentNode

/// One subagent in the constellation. `id` is the Claude `agentId` (stable across the
/// agent's lifetime); `slug`/`agentType` is the human label when known.
public struct AgentNode: Sendable, Identifiable, Equatable {

    /// Lifecycle state of a single agent node.
    public enum State: String, Sendable, Equatable {
        case spawning   // node just appeared; no tool activity yet
        case working    // at least one tool_use seen
        case done       // parent toolUseResult reported success
        case failed     // parent toolUseResult reported a non-success status
    }

    /// Claude `agentId` — the stable identity key.
    public let id: String
    /// Human-readable label: the agent's `slug` (spawn) or `agentType` (completion).
    public var slug: String?
    /// Current lifecycle state.
    public var state: State
    /// Name of the most recently used tool (e.g. "Bash", "Read"). Nil until first tool_use.
    public var lastTool: String?
    /// Total tokens — only known (authoritative) once the agent is done.
    public var tokens: Int?
    /// Cost in USD — only ever derived on completion; left nil otherwise (we do not
    /// estimate mid-run). Reserved for when a cost figure is available authoritatively.
    public var cost: Double?
    /// Wall-clock duration in milliseconds, known on completion.
    public var durationMs: Int?
    /// Monotonic spawn order index, used by the renderer for staggered fade-in and for
    /// approximating phases via spawn-burst clustering.
    public var spawnOrder: Int

    public init(
        id: String,
        slug: String? = nil,
        state: State = .spawning,
        lastTool: String? = nil,
        tokens: Int? = nil,
        cost: Double? = nil,
        durationMs: Int? = nil,
        spawnOrder: Int = 0
    ) {
        self.id = id
        self.slug = slug
        self.state = state
        self.lastTool = lastTool
        self.tokens = tokens
        self.cost = cost
        self.durationMs = durationMs
        self.spawnOrder = spawnOrder
    }
}

// MARK: - SwarmPhase

/// A spawn-burst cluster, used to approximate "phases" (Claude emits no phase event).
/// Agents that spawn within `phaseGapSeconds` of each other are grouped into one ring.
public struct SwarmPhase: Sendable, Equatable {
    /// 0-based phase index in spawn order.
    public let index: Int
    /// Agent ids that belong to this phase, in spawn order.
    public var agentIds: [String]

    public init(index: Int, agentIds: [String]) {
        self.index = index
        self.agentIds = agentIds
    }
}

// MARK: - SwarmState

/// Observable model of the live swarm. Capped at `maxVisibleNodes` visible nodes; any
/// completions beyond the cap are folded into `aggregatedDoneArc` so 1000-agent runs still
/// render as a single core + a "done" progress arc rather than thousands of nodes.
///
/// `@MainActor` because it drives the HUD; mutation happens on the main thread via the
/// observer. The `apply*` methods are the only mutators and are pure in effect.
@MainActor
@Observable
public final class SwarmState {

    // MARK: Tuning constants

    /// Hard cap on visible nodes (plan §8). Beyond this, completed agents are aggregated.
    public static let maxVisibleNodes = 16

    /// Spawn-burst clustering gap: agents spawning within this many seconds form one phase.
    public static let phaseGapSeconds: TimeInterval = 2.5

    // MARK: Observable state

    /// Visible nodes, in spawn order, capped at `maxVisibleNodes`.
    public private(set) var nodes: [AgentNode] = []

    /// Count of completed agents that never had (or no longer have) a visible node — the
    /// "done" arc for >16-agent runs. Renderer shows this as an aggregated progress arc.
    public private(set) var aggregatedDoneArc: Int = 0

    /// Approximated phases (spawn-burst clusters) over the currently visible nodes.
    public private(set) var phases: [SwarmPhase] = []

    /// True once a `stop`/collapse has been applied; the HUD plays the inward collapse.
    public private(set) var collapsed: Bool = false

    /// Total agents ever spawned this turn (visible + evicted). Drives the "N of M" read-out.
    public private(set) var totalSpawned: Int = 0

    /// Total agents that have completed (done or failed), visible or aggregated.
    public private(set) var totalCompleted: Int = 0

    // MARK: Internal bookkeeping

    /// Monotonic spawn counter (never reset except by `collapse`).
    private var nextSpawnOrder = 0
    /// Spawn timestamps by agentId, for phase clustering. Uses an injectable clock so the
    /// clustering is deterministic in tests.
    private var spawnStamps: [String: TimeInterval] = [:]
    /// Ids that were spawned this turn (so a `toolUse`/`done` for an unknown id can be
    /// distinguished from a duplicate). Includes evicted ids.
    private var knownIds: Set<String> = []

    /// Monotonic clock for phase clustering. Injectable for deterministic tests.
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    // MARK: - Pure update functions

    /// A new subagent appeared. Adds a `spawning` node (capped) and records spawn timing
    /// for phase clustering. Duplicate spawns (same id) are idempotent.
    public func applyAgentSpawn(agentId: String, slug: String?) {
        guard !agentId.isEmpty else { return }
        // Re-spawn of an existing/known id: just refresh the label if we learned one.
        if let idx = nodes.firstIndex(where: { $0.id == agentId }) {
            if let slug, nodes[idx].slug == nil { nodes[idx].slug = slug }
            return
        }
        if knownIds.contains(agentId) {
            // Already seen and evicted; don't re-add a visible node, but keep counts sane.
            return
        }

        knownIds.insert(agentId)
        totalSpawned += 1
        spawnStamps[agentId] = now()

        let node = AgentNode(
            id: agentId,
            slug: slug,
            state: .spawning,
            spawnOrder: nextSpawnOrder
        )
        nextSpawnOrder += 1

        nodes.append(node)
        evictIfNeeded()
        recomputePhases()
    }

    /// A subagent invoked a tool. Promotes the node to `working` and records the tool name.
    /// A tool_use for an unknown id lazily spawns a node (tolerant to missing spawn line).
    public func applyToolUse(agentId: String, tool: String) {
        guard !agentId.isEmpty else { return }
        guard let idx = nodes.firstIndex(where: { $0.id == agentId }) else {
            // Unknown id: if we never saw a spawn (file race), create one so the tool shows.
            if !knownIds.contains(agentId) {
                applyAgentSpawn(agentId: agentId, slug: nil)
                applyToolUse(agentId: agentId, tool: tool)
            }
            return
        }
        nodes[idx].lastTool = tool.isEmpty ? nodes[idx].lastTool : tool
        if nodes[idx].state == .spawning {
            nodes[idx].state = .working
        }
    }

    /// A subagent finished, per the authoritative parent `toolUseResult`. Sets the terminal
    /// state and stamps the (now trustworthy) tokens/duration. Idempotent per id.
    public func applyAgentDone(
        agentId: String,
        status: SwarmAgentResultStatus,
        tokens: Int? = nil,
        durationMs: Int? = nil,
        toolUseCount: Int? = nil,
        slug: String? = nil
    ) {
        guard !agentId.isEmpty else { return }
        let terminal: AgentNode.State = (status == .completed) ? .done : .failed

        if let idx = nodes.firstIndex(where: { $0.id == agentId }) {
            // Already terminal? idempotent no-op (avoid double-counting completion).
            if nodes[idx].state == .done || nodes[idx].state == .failed { return }
            nodes[idx].state = terminal
            if let tokens { nodes[idx].tokens = tokens }
            if let durationMs { nodes[idx].durationMs = durationMs }
            if let slug, nodes[idx].slug == nil { nodes[idx].slug = slug }
            totalCompleted += 1
            return
        }

        // Completion for an evicted/aggregated node: bump the aggregated arc, not a node.
        if knownIds.contains(agentId) {
            aggregatedDoneArc += 1
            totalCompleted += 1
        } else {
            // Completion for an id we never saw spawn (we may have missed the spawn line
            // due to the cap or a race). Count it as a completed aggregated agent.
            knownIds.insert(agentId)
            totalSpawned += 1
            aggregatedDoneArc += 1
            totalCompleted += 1
        }
    }

    /// The turn ended: mark collapsed. The renderer plays the inward collapse animation,
    /// then the HUD typically calls `reset()` once the read-back finishes.
    public func collapse() {
        collapsed = true
    }

    /// Clears all swarm state back to empty (e.g. when starting a fresh turn or turning
    /// swarm mode off). Pure: leaves the model identical to a freshly constructed one.
    public func reset() {
        nodes.removeAll()
        phases.removeAll()
        aggregatedDoneArc = 0
        totalSpawned = 0
        totalCompleted = 0
        collapsed = false
        nextSpawnOrder = 0
        spawnStamps.removeAll()
        knownIds.removeAll()
    }

    /// Convenience dispatcher so the observer can feed decoded events directly.
    public func apply(_ event: SwarmEvent) {
        switch event {
        case let .agentSpawn(agentId, slug):
            applyAgentSpawn(agentId: agentId, slug: slug)
        case let .toolUse(agentId, tool):
            applyToolUse(agentId: agentId, tool: tool)
        case let .agentDone(agentId, status, tokens, durationMs, toolUseCount):
            applyAgentDone(agentId: agentId, status: status, tokens: tokens, durationMs: durationMs, toolUseCount: toolUseCount)
        case .stop:
            collapse()
        }
    }

    // MARK: - Derived read-outs

    /// Number of currently visible nodes that are in a terminal state.
    public var visibleDoneCount: Int {
        nodes.reduce(0) { $0 + (($1.state == .done || $1.state == .failed) ? 1 : 0) }
    }

    /// Total done count across visible + aggregated (for "N of M done" read-back).
    public var doneCount: Int { visibleDoneCount + aggregatedDoneArc }

    // MARK: - Internals

    /// Enforce the visible-node cap. When over the cap, evict the *oldest already-terminal*
    /// node into the aggregated arc (so we never drop an in-flight node in favour of a
    /// finished one). If everything visible is still in-flight, the newest spawn is held
    /// back into the aggregate instead.
    private func evictIfNeeded() {
        while nodes.count > Self.maxVisibleNodes {
            if let termIdx = nodes.firstIndex(where: { $0.state == .done || $0.state == .failed }) {
                nodes.remove(at: termIdx)
                aggregatedDoneArc += 1
            } else {
                // No terminal node to evict: drop the most recent spawn from the visible
                // set (it stays in knownIds/totalSpawned; its eventual completion will
                // land in the aggregate via applyAgentDone's evicted path).
                nodes.removeLast()
            }
        }
    }

    /// Recompute spawn-burst phases over the visible nodes. Agents whose spawn timestamps
    /// are within `phaseGapSeconds` of the previous agent's join the same phase.
    private func recomputePhases() {
        var result: [SwarmPhase] = []
        var lastStamp: TimeInterval?
        let ordered = nodes.sorted { $0.spawnOrder < $1.spawnOrder }
        for node in ordered {
            let stamp = spawnStamps[node.id] ?? 0
            if let last = lastStamp, stamp - last <= Self.phaseGapSeconds, var phase = result.last {
                phase.agentIds.append(node.id)
                result[result.count - 1] = phase
            } else {
                result.append(SwarmPhase(index: result.count, agentIds: [node.id]))
            }
            lastStamp = stamp
        }
        phases = result
    }
}
