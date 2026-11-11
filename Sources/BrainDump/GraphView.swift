import AppKit
import BrainDumpCore
import SwiftUI

/// Force-directed layout over a `NoteGraph`. A reference type stepped from the render loop; positions are in world units.
final class GraphLayout: @unchecked Sendable {
    let graph: NoteGraph
    let index: [String: Int]
    let edges: [(Int, Int)]
    let neighbors: [[Int]]
    let radius: [CGFloat]
    var x: [CGFloat], y: [CGFloat], vx: [CGFloat], vy: [CGFloat]
    var pinned: Int?
    /// Simulation heat: 1 is lively, below `settledAlpha` the layout is considered at rest.
    var alpha: CGFloat = 1
    static let settledAlpha: CGFloat = 0.02

    var isSettled: Bool { alpha < Self.settledAlpha && pinned == nil }

    static func radius(mentions: Int, journal: Bool) -> CGFloat {
        journal ? 3.5 : min(6 + 4 * CGFloat(Double(max(mentions, 1) - 1).squareRoot()), 22)
    }

    /// `seed` carries over positions from a previous layout so toggling layers doesn't scramble the picture.
    init(graph: NoteGraph, seed: [String: CGPoint] = [:]) {
        self.graph = graph
        var idx: [String: Int] = [:]
        for (i, n) in graph.nodes.enumerated() { idx[n.id] = i }
        index = idx
        edges = graph.edges.compactMap { e in
            guard let a = idx[e.from], let b = idx[e.to] else { return nil }
            return (a, b)
        }
        var nb = Array(repeating: [Int](), count: graph.nodes.count)
        for (a, b) in edges { nb[a].append(b); nb[b].append(a) }
        neighbors = nb
        radius = graph.nodes.map { Self.radius(mentions: $0.mentions, journal: $0.isJournal) }
        let count = graph.nodes.count
        var xs = [CGFloat](repeating: 0, count: count), ys = xs
        for (i, n) in graph.nodes.enumerated() {
            if let p = seed[n.id] { xs[i] = p.x; ys[i] = p.y; continue }
            // Golden-angle spiral: deterministic and evenly spread, so the first frame is already sensible.
            let r = 30 * CGFloat(i).squareRoot() + 20, a = CGFloat(i) * 2.399963
            xs[i] = r * cos(a); ys[i] = r * sin(a)
        }
        x = xs; y = ys
        vx = Array(repeating: 0, count: count)
        vy = Array(repeating: 0, count: count)
    }

    /// Runs `n` steps with a gentle cool-down, leaving the layout warm enough to keep drifting.
    func prewarm(_ n: Int = 300) {
        for _ in 0..<n { step(decay: 0.9965) }
    }

    /// One simulation step: pairwise repulsion, springs along edges, centering gravity, damping.
    func step(decay: CGFloat = 0.985) {
        let n = x.count
        guard n > 0 else { return }
        var fx = [CGFloat](repeating: 0, count: n), fy = fx
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = x[j] - x[i], dy = y[j] - y[i]
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = CGFloat(i % 7) - 3; dy = CGFloat(j % 5) - 2; d2 = dx * dx + dy * dy + 0.01 }
                let d = d2.squareRoot()
                var f = 1800 / d2
                let minD = radius[i] + radius[j] + 10
                if d < minD { f += (minD - d) * 0.05 }
                fx[i] -= f * dx / d; fy[i] -= f * dy / d
                fx[j] += f * dx / d; fy[j] += f * dy / d
            }
        }
        for (a, b) in edges {
            let dx = x[b] - x[a], dy = y[b] - y[a]
            let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let f = 0.03 * (d - 85)
            fx[a] += f * dx / d; fy[a] += f * dy / d
            fx[b] -= f * dx / d; fy[b] -= f * dy / d
        }
        for i in 0..<n {
            fx[i] -= 0.012 * x[i]; fy[i] -= 0.012 * y[i]
            if i == pinned { vx[i] = 0; vy[i] = 0; continue }
            vx[i] = (vx[i] + fx[i] * alpha) * 0.8
            vy[i] = (vy[i] + fy[i] * alpha) * 0.8
            // Cap speed so nothing ever flies off.
            let s = (vx[i] * vx[i] + vy[i] * vy[i]).squareRoot()
            if s > 12 { vx[i] *= 12 / s; vy[i] *= 12 / s }
            x[i] += vx[i]; y[i] += vy[i]
        }
        alpha *= decay
    }

    /// Re-heats the simulation after a drag or relayout.
    func wake(_ a: CGFloat = 0.3) { alpha = max(alpha, a) }

    /// Index of the topmost node within reach of a world point.
    func hit(_ p: CGPoint, slack: CGFloat) -> Int? {
        var best: Int?
        var bestD = CGFloat.infinity
        for i in 0..<x.count {
            let d = hypot(x[i] - p.x, y[i] - p.y)
            if d <= radius[i] + slack, d < bestD { best = i; bestD = d }
        }
        return best
    }
}

/// In-app graph of notes and their links, "nodes in a brain". Click a node to select the note.
struct GraphView: View {
    @Environment(AppModel.self) private var model

    @State private var graph: NoteGraph?
    @State private var layout: GraphLayout?
    @State private var includeJournal = false
    @State private var hiddenKinds: Set<String> = []
    @State private var hovered: Int?
    @State private var hoverPoint: CGPoint?
    @State private var dragNode: Int?
    @State private var dragMoved = false
    @State private var panStart: CGSize?
    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var running = true
    @State private var canvasSize: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var loadID = 0

    private var root: URL { Prefs.notesRoot }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ZStack {
                if let layout, !layout.graph.nodes.isEmpty {
                    canvas(layout)
                    zoomControls
                } else if graph != nil {
                    emptyState
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
                .background(Theme.paper)
        .task(id: includeJournal) { await reload() }
        .onAppear(perform: installScrollMonitor)
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }
    }

    // MARK: Top bar

    /// Kinds present in the graph, in the user's category order.
    private var legendKinds: [ItemKind] {
        let present = Set(layout?.graph.nodes.filter { !$0.isJournal }.map(\.kind) ?? [])
        let known = ItemCategory.defaults.enabled.map(\.kind).filter { present.contains($0) }
        return known + present.subtracting(known).sorted { $0.rawValue < $1.rawValue }
    }

    private var visibleIndices: [Int] {
        guard let layout else { return [] }
        return layout.graph.nodes.indices.filter { isVisible($0, layout) }
    }

    private func isVisible(_ i: Int, _ layout: GraphLayout) -> Bool {
        let n = layout.graph.nodes[i]
        return !hiddenKinds.contains(n.kind.rawValue)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            ForEach(legendKinds, id: \.self) { kind in
                let off = hiddenKinds.contains(kind.rawValue)
                Button {
                    if off { hiddenKinds.remove(kind.rawValue) } else { hiddenKinds.insert(kind.rawValue) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(kind.label).font(.system(size: 12))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(kind.color.opacity(off ? 0.04 : 0.14), in: Capsule())
                    .opacity(off ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .help(off ? "Show \(kind.label)" : "Hide \(kind.label)")
            }
            Spacer()
            if let layout {
                let shown = Set(visibleIndices)
                let notes = shown.filter { !layout.graph.nodes[$0].isJournal }.count
                let links = layout.edges.filter { shown.contains($0.0) && shown.contains($0.1) }.count
                Text("\(notes) notes · \(links) links").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("Journal days", isOn: $includeJournal).toggleStyle(.checkbox).font(.system(size: 12))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No notes yet").font(.system(size: 17, design: .serif))
            Text("Links between your notes appear here as you approve related suggestions while reviewing a dump.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
    }

    private var zoomControls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus") }
                    Button { pan = .zero; zoom = 1 } label: { Image(systemName: "scope") }.help("Reset view")
                    Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(14)
            }
        }
    }

    // MARK: Canvas

    private func toScreen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + pan.width + p.x * zoom, y: size.height / 2 + pan.height + p.y * zoom)
    }

    private func toWorld(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - pan.width) / zoom, y: (p.y - size.height / 2 - pan.height) / zoom)
    }

    private func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        let new = min(max(z, 0.25), 4)
        if let a = anchor {
            // Keep the world point under the cursor fixed.
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            pan = CGSize(width: (a.x - c.x) - (a.x - c.x - pan.width) * new / zoom,
                         height: (a.y - c.y) - (a.y - c.y - pan.height) * new / zoom)
        } else {
            pan = CGSize(width: pan.width * new / zoom, height: pan.height * new / zoom)
        }
        zoom = new
    }

    private func canvas(_ layout: GraphLayout) -> some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !running)) { _ in
                Canvas { ctx, size in
                    if running && (!layout.isSettled || dragNode != nil) { layout.step() }
                    draw(ctx, size, layout)
                    if layout.isSettled && running { DispatchQueue.main.async { running = false } }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layout, geo.size))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let base = zoomStart ?? zoom
                    zoomStart = base
                    setZoom(base * v.magnification)
                }
                .onEnded { _ in zoomStart = nil })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverPoint = p
                    let h = layout.hit(toWorld(p, geo.size), slack: 4 / zoom).flatMap { isVisible($0, layout) ? $0 : nil }
                    if h != hovered { hovered = h }
                case .ended:
                    hoverPoint = nil; hovered = nil
                }
            }
            .overlay { card(layout, geo.size) }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
    }

    private func dragGesture(_ layout: GraphLayout, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !dragMoved && dragNode == nil && panStart == nil {
                    if let h = layout.hit(toWorld(v.startLocation, size), slack: 4 / zoom), isVisible(h, layout) {
                        dragNode = h
                        layout.pinned = h
                    } else {
                        panStart = pan
                    }
                }
                if hypot(v.translation.width, v.translation.height) > 3 { dragMoved = true }
                if let h = dragNode, dragMoved {
                    let w = toWorld(v.location, size)
                    layout.x[h] = w.x; layout.y[h] = w.y
                    layout.wake(0.3)
                    running = true
                } else if let start = panStart {
                    pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                }
            }
            .onEnded { _ in
                if let h = dragNode {
                    layout.pinned = nil
                    if !dragMoved { open(layout.graph.nodes[h]) }
                    layout.wake(0.15)
                    running = true
                }
                dragNode = nil; panStart = nil; dragMoved = false
            }
    }

    private func open(_ node: NoteGraph.Node) {
        model.openNote(node.url)
    }

    /// Scroll wheel zooms around the cursor while the pointer is over the graph.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let p = hoverPoint else { return event }
            let dy = event.scrollingDeltaY
            if dy != 0 { setZoom(zoom * exp(dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)), anchor: p) }
            return nil
        }
    }

    private func reload() async {
        let folders = ItemCategory.defaults.noteFolders
        let root = root
        let journal = includeJournal
        let seed: [String: CGPoint] = layout.map { l in
            Dictionary(uniqueKeysWithValues: l.graph.nodes.indices.map { (l.graph.nodes[$0].id, CGPoint(x: l.x[$0], y: l.y[$0])) })
        } ?? [:]
        let hadLayout = !seed.isEmpty
        let built = await Task.detached(priority: .userInitiated) { () -> GraphLayout in
            let g = NoteGraph.load(root: root, folders: folders, includeJournal: journal)
            let l = GraphLayout(graph: g, seed: seed)
            // Fresh layouts get a full warm-up; relayouts only settle the newcomers.
            l.prewarm(hadLayout ? 120 : 300)
            if hadLayout { l.alpha = 0.35 }
            return l
        }.value
        graph = built.graph
        layout = built
        hovered = nil
        running = true
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ layout: GraphLayout) {
        let focus = hovered ?? dragNode
        let near: Set<Int> = focus.map { Set(layout.neighbors[$0] + [$0]) } ?? []
        let pts = (0..<layout.x.count).map { toScreen(CGPoint(x: layout.x[$0], y: layout.y[$0]), size) }
        let hidden = layout.graph.nodes.map { hiddenKinds.contains($0.kind.rawValue) }

        for (a, b) in layout.edges where !hidden[a] && !hidden[b] {
            var path = Path()
            path.move(to: pts[a]); path.addLine(to: pts[b])
            let lit = focus != nil && (a == focus || b == focus)
            let opacity = focus == nil ? 0.22 : (lit ? 0.7 : 0.05)
            ctx.stroke(path, with: .color(.primary.opacity(opacity)), lineWidth: lit ? 1.6 : 1)
        }

        var labels: [(Int, Bool)] = []
        for i in layout.x.indices where !hidden[i] {
            let node = layout.graph.nodes[i]
            let r = layout.radius[i] * min(max(zoom, 0.6), 1.6)
            let p = pts[i]
            let faded = focus != nil && !near.contains(i)
            let base: Color = node.isJournal ? .secondary : node.kind.color
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(base.opacity(faded ? 0.15 : (node.isJournal ? 0.5 : 0.9))))
            if i == focus {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(base.opacity(0.6)), lineWidth: 1.5)
            }
            let big = !node.isJournal && layout.radius[i] >= 10
            if (focus != nil && near.contains(i)) || (focus == nil && big) { labels.append((i, i == focus)) }
        }
        for (i, isFocus) in labels {
            let node = layout.graph.nodes[i]
            let r = layout.radius[i] * min(max(zoom, 0.6), 1.6)
            let text = Text(node.title).font(.system(size: isFocus ? 12 : 11, weight: isFocus ? .semibold : .regular))
            let resolved = ctx.resolve(text.foregroundStyle(Color.primary.opacity(isFocus || focus == nil ? 0.85 : 0.7)))
            ctx.draw(resolved, at: CGPoint(x: pts[i].x, y: pts[i].y + r + 9), anchor: .top)
        }
    }

    // MARK: Hover card

    @ViewBuilder private func card(_ layout: GraphLayout, _ size: CGSize) -> some View {
        if let h = hovered, dragNode == nil, h < layout.graph.nodes.count {
            let node = layout.graph.nodes[h]
            let reasons = layout.graph.edges.compactMap { e -> String? in
                guard e.from == node.id || e.to == node.id else { return nil }
                return e.reason
            }
            let p = toScreen(CGPoint(x: layout.x[h], y: layout.y[h]), size)
            let onRight = p.x < size.width - 280
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title).font(.system(size: 13, weight: .semibold, design: .serif)).lineLimit(2)
                Text(node.isJournal ? "Journal" : "\(node.kind.label) · \(node.mentions) \(node.mentions == 1 ? "mention" : "mentions")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(reasons.prefix(4).enumerated()), id: \.offset) { _, r in
                    Text("• " + r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
                if reasons.count > 4 { Text("+ \(reasons.count - 4) more").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .padding(10)
            .frame(width: 240, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .position(x: p.x + (onRight ? 140 + layout.radius[h] : -140 - layout.radius[h]), y: min(max(p.y, 70), size.height - 70))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
