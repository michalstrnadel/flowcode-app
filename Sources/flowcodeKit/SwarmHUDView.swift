//
//  SwarmHUDView.swift
//  flowcodeKit — Phase 8 (orchestration / swarm visualization). DEFAULT OFF.
//
//  The constellation render for the swarm. A persistent luminous core that BLOOMS into
//  concentric phase-rings as agents spawn, with nodes fading in staggered, settling to a
//  flare on `done`, desaturating to a muted red on `failed`, and collapsing inward on Stop.
//
//  Render stack per plan §8: `TimelineView(.animation)` + `Canvas` + `.drawingGroup()` so
//  the whole constellation is GPU-composited as one layer. Deterministic radial layout:
//  phase index -> ring radius, position within phase -> angle. Capped at
//  `SwarmState.maxVisibleNodes` nodes + an aggregated "done" arc for >16-agent runs.
//
//  Accessibility: Reduce Motion swaps the animated canvas for a STATIC list of phases /
//  agents plus a progress arc (no continuous motion, no time-driven animation).
//
//  This view is intentionally self-contained SwiftUI; it reads a `SwarmState` (@Observable)
//  and recomputes the deterministic layout each frame. It does no IO and starts no work.
//

import SwiftUI

@MainActor
public struct SwarmHUDView: View {

    private let state: SwarmState

    /// Diameter of the square canvas in points.
    private let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: SwarmState, side: CGFloat = 320) {
        self.state = state
        self.side = side
    }

    public var body: some View {
        Group {
            if reduceMotion {
                reducedView
            } else {
                animatedView
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: - Animated constellation

    private var animatedView: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                SwarmConstellationRenderer.draw(
                    into: &context,
                    size: size,
                    state: SwarmRenderSnapshot(state: state),
                    time: t
                )
            }
            .drawingGroup() // composite the whole constellation as one GPU layer
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SwarmRenderSnapshot(state: state).accessibilityLabel))
    }

    // MARK: - Reduce-Motion fallback (static)

    private var reducedView: some View {
        let snap = SwarmRenderSnapshot(state: state)
        return VStack(alignment: .leading, spacing: 8) {
            // Static progress arc as a determinate ring (no continuous animation).
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: snap.progressFraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(snap.doneCount)/\(snap.totalCount)")
                    .font(.system(.title3, design: .rounded)).bold()
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 4)

            ForEach(snap.phases, id: \.index) { phase in
                Text("Phase \(phase.index + 1)")
                    .font(.caption).bold().foregroundStyle(.secondary)
                ForEach(phase.nodes, id: \.id) { node in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SwarmPalette.swiftUIColor(for: node.state))
                            .frame(width: 8, height: 8)
                        Text(node.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let tool = node.lastTool {
                            Text(tool).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if snap.aggregatedDoneArc > 0 {
                Text("+\(snap.aggregatedDoneArc) more done")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(snap.accessibilityLabel))
    }
}

// MARK: - Render snapshot (pure, testable)

/// A pure, value-type snapshot of `SwarmState` for rendering. Reading the @MainActor model
/// once per frame into a Sendable value keeps the renderer pure and unit-testable (the
/// deterministic layout math takes the snapshot, not the live model).
public struct SwarmRenderSnapshot: Sendable, Equatable {

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let state: AgentNode.State
        public let lastTool: String?
        public let spawnOrder: Int
    }

    public struct Phase: Sendable, Equatable {
        public let index: Int
        public let nodes: [Node]
    }

    public let phases: [Phase]
    public let aggregatedDoneArc: Int
    public let collapsed: Bool
    public let doneCount: Int
    public let totalCount: Int

    @MainActor
    public init(state: SwarmState) {
        let byId = Dictionary(uniqueKeysWithValues: state.nodes.map { ($0.id, $0) })
        self.phases = state.phases.map { phase in
            Phase(
                index: phase.index,
                nodes: phase.agentIds.compactMap { id in
                    guard let n = byId[id] else { return nil }
                    return Node(
                        id: n.id,
                        label: n.slug ?? String(n.id.prefix(6)),
                        state: n.state,
                        lastTool: n.lastTool,
                        spawnOrder: n.spawnOrder
                    )
                }
            )
        }
        self.aggregatedDoneArc = state.aggregatedDoneArc
        self.collapsed = state.collapsed
        self.doneCount = state.doneCount
        self.totalCount = max(state.totalSpawned, 0)
    }

    /// Memberwise init for tests / synthetic snapshots.
    public init(phases: [Phase], aggregatedDoneArc: Int, collapsed: Bool, doneCount: Int, totalCount: Int) {
        self.phases = phases
        self.aggregatedDoneArc = aggregatedDoneArc
        self.collapsed = collapsed
        self.doneCount = doneCount
        self.totalCount = totalCount
    }

    /// 0...1 completion fraction for the progress arc. Defaults to 0 when nothing spawned.
    public var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, Double(doneCount) / Double(totalCount))
    }

    public var accessibilityLabel: String {
        if collapsed {
            return "Swarm complete: \(doneCount) of \(totalCount) agents done."
        }
        let agents = phases.reduce(0) { $0 + $1.nodes.count }
        return "Swarm running: \(agents) agents across \(phases.count) phases, \(doneCount) of \(totalCount) done."
    }
}

// MARK: - Palette

/// Constellation palette. State is encoded by motion/shape primarily; color secondarily,
/// matching the orb's cool cyan -> violet philosophy. Failed is the only desaturated red.
enum SwarmPalette {
    static func components(for state: AgentNode.State) -> (r: Double, g: Double, b: Double) {
        switch state {
        case .spawning: return (0.34, 0.52, 0.95)   // cyan-violet, dim
        case .working:  return (0.22, 0.78, 0.92)   // bright cyan
        case .done:     return (0.62, 0.86, 1.0)    // flare: bright cool white-cyan
        case .failed:   return (0.62, 0.30, 0.30)   // desaturated muted red
        }
    }

    static func swiftUIColor(for state: AgentNode.State) -> Color {
        let c = components(for: state)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1.0)
    }
}

// MARK: - Pure radial layout + renderer

/// Deterministic constellation geometry + Canvas drawing. The geometry math is pure and
/// static so it can be exercised in tests without a live `Canvas`.
public enum SwarmConstellationRenderer {

    /// Compute the center-relative position of a node given its phase ring and slot.
    /// - phaseIndex: 0-based ring index (0 = innermost ring around the core).
    /// - slot/slotCount: position within the phase (evenly distributed around the ring).
    /// - radius: half the canvas side (max usable radius).
    /// Returns an offset in points from the canvas center.
    public static func position(
        phaseIndex: Int,
        slot: Int,
        slotCount: Int,
        maxRadius: CGFloat,
        phaseCount: Int
    ) -> CGPoint {
        let rings = max(phaseCount, 1)
        // Reserve the inner ~22% for the persistent core; spread phases outward to the edge.
        let coreFrac: CGFloat = 0.22
        let span = maxRadius * (1 - coreFrac)
        let ringR = maxRadius * coreFrac + span * (CGFloat(phaseIndex) + 0.5) / CGFloat(rings)
        let count = max(slotCount, 1)
        // Stagger each ring's starting angle so rings don't line up radially.
        let phaseOffset = CGFloat(phaseIndex) * 0.6
        let angle = phaseOffset + (2 * .pi) * (CGFloat(slot) / CGFloat(count))
        return CGPoint(x: ringR * cos(angle), y: ringR * sin(angle))
    }

    /// Staggered fade-in opacity for a node based on its spawn order and current time.
    /// Earlier spawns reach full opacity sooner; under collapse, opacity drives inward fade.
    public static func nodeOpacity(spawnOrder: Int, time: TimeInterval, collapsed: Bool) -> Double {
        if collapsed { return 0.0 }
        // 80 ms stagger per spawn index, 250 ms fade.
        let appear = TimeInterval(spawnOrder) * 0.08
        let frac = (time.truncatingRemainder(dividingBy: 1_000_000) - appear) / 0.25
        return min(1.0, max(0.15, frac))
    }

    /// Draw the constellation into a SwiftUI `GraphicsContext`. Kept side-effect-light:
    /// reads only the snapshot + time. `collapsed` pulls nodes toward the core.
    @MainActor
    public static func draw(
        into context: inout GraphicsContext,
        size: CGSize,
        state snapshot: SwarmRenderSnapshot,
        time: TimeInterval
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 12
        let phaseCount = snapshot.phases.count

        // Collapse factor: 1 = full bloom, 0 = fully collapsed into the core.
        let collapse: CGFloat = snapshot.collapsed ? 0.18 : 1.0

        // 1) Persistent core (always present; pulses gently with time unless collapsed).
        let breathe = snapshot.collapsed ? 0.0 : 0.06 * sin(time * 1.2)
        let coreR = maxRadius * (0.16 + breathe)
        let corePath = Path(ellipseIn: CGRect(
            x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2))
        context.fill(corePath, with: .color(Color(.sRGB, red: 0.30, green: 0.72, blue: 0.95, opacity: 0.9)))

        // 2) Concentric phase rings + nodes.
        for phase in snapshot.phases {
            // Faint ring guide.
            let ringR = phaseRingRadius(phaseIndex: phase.index, maxRadius: maxRadius, phaseCount: phaseCount) * collapse
            let ringRect = CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2)
            context.stroke(Path(ellipseIn: ringRect),
                           with: .color(Color.white.opacity(0.06)), lineWidth: 1)

            for (slot, node) in phase.nodes.enumerated() {
                let rel = position(
                    phaseIndex: phase.index,
                    slot: slot,
                    slotCount: phase.nodes.count,
                    maxRadius: maxRadius,
                    phaseCount: phaseCount
                )
                let pos = CGPoint(x: center.x + rel.x * collapse, y: center.y + rel.y * collapse)

                // Tether: core -> node.
                var tether = Path()
                tether.move(to: center)
                tether.addLine(to: pos)
                context.stroke(tether, with: .color(Color.white.opacity(0.05)), lineWidth: 1)

                let comps = SwarmPalette.components(for: node.state)
                let color = Color(.sRGB, red: comps.r, green: comps.g, blue: comps.b, opacity: 1.0)
                let op = nodeOpacity(spawnOrder: node.spawnOrder, time: time, collapsed: snapshot.collapsed)

                // done = flare (bigger, brighter halo); failed = small desaturated dot.
                let baseR: CGFloat = (node.state == .done) ? 9 : (node.state == .failed ? 5 : 7)
                let pulse: CGFloat = (node.state == .working) ? 1 + 0.18 * CGFloat(sin(time * 4 + Double(node.spawnOrder))) : 1
                let r = baseR * pulse

                if node.state == .done {
                    let haloRect = CGRect(x: pos.x - r * 2.4, y: pos.y - r * 2.4, width: r * 4.8, height: r * 4.8)
                    context.fill(Path(ellipseIn: haloRect), with: .color(color.opacity(0.18 * op)))
                }
                let dotRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(color.opacity(op)))
            }
        }

        // 3) Aggregated "done" arc for >16-agent runs (outer progress ring).
        if snapshot.aggregatedDoneArc > 0 || snapshot.totalCount > SwarmState.maxVisibleNodes {
            let arcR = maxRadius - 4
            let frac = snapshot.progressFraction
            var arc = Path()
            arc.addArc(
                center: center,
                radius: arcR,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * frac),
                clockwise: false
            )
            context.stroke(arc, with: .color(Color(.sRGB, red: 0.62, green: 0.86, blue: 1.0, opacity: 0.7)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// Ring radius for a phase index (matches the radial used by `position`).
    public static func phaseRingRadius(phaseIndex: Int, maxRadius: CGFloat, phaseCount: Int) -> CGFloat {
        let rings = max(phaseCount, 1)
        let coreFrac: CGFloat = 0.22
        let span = maxRadius * (1 - coreFrac)
        return maxRadius * coreFrac + span * (CGFloat(phaseIndex) + 0.5) / CGFloat(rings)
    }
}
