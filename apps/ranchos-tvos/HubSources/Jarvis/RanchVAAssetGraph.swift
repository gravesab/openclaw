#if !os(tvOS)
import SwiftUI
import RealityKit

struct RanchVAAssetHierarchy {
    struct Group: Identifiable {
        let asset: RanchOSPropertyLiveAsset
        let tasks: [RanchOSPropertyLiveTask]
        var id: UUID { asset.id }
    }
    let groups: [Group]
    let unlinked: [RanchOSPropertyLiveTask]

    init(assets: [RanchOSPropertyLiveAsset], tasks: [RanchOSPropertyLiveTask]) {
        let ids = Set(assets.map(\.id))
        let byAsset = Dictionary(grouping: tasks.compactMap { task in task.assetID.map { ($0, task) } }, by: { $0.0 })
        groups = assets.map { asset in
            Group(asset: asset, tasks: (byAsset[asset.id] ?? []).map(\.1).sorted { $0.id < $1.id })
        }
        unlinked = tasks.filter { $0.assetID.map { !ids.contains($0) } ?? true }
    }
}

struct RanchVAGraphLabels {
    static func wrapped(_ text: String, width: Int = 30) -> String {
        var lines = [String]()
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !line.isEmpty && line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

@MainActor struct RanchVAAssetGraph: View {
    let hierarchy: RanchVAAssetHierarchy
    let selection: String?
    let onSelect: (String) -> Void
    @State private var showTaskLabels: Bool
    init(hierarchy: RanchVAAssetHierarchy, selection: String?, onSelect: @escaping (String) -> Void) {
        self.hierarchy = hierarchy
        self.selection = selection
        self.onSelect = onSelect
        _showTaskLabels = State(initialValue: hierarchy.groups.count == 1)
    }
    @State private var cameraMode = 0
    @State private var resetCamera = 0
    private var controls: CameraControls {
        switch cameraMode { case 1: .pan; case 2: .dolly; default: .orbit }
    }

    private var identity: [String] {
        hierarchy.groups.flatMap { [$0.asset.id.uuidString + $0.asset.name] + $0.tasks.map { $0.id + $0.title } }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Drag action", selection: $cameraMode) {
                    Text("Rotate").tag(0)
                    Text("Pan").tag(1)
                    Text("Zoom").tag(2)
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Toggle("Task labels", isOn: $showTaskLabels).foregroundStyle(.white)
                Button("Fit all") { resetCamera += 1 }
            }.padding(.horizontal, 10).padding(.top, 8)
            Text("Choose Zoom, then drag to move closer. Choose Pan to read nearby labels. Click any dot or label for details.")
                .font(.caption).foregroundStyle(.white).padding(.horizontal, 10)
            graphView
        }
    }

    private var graphView: some View {
        RealityView { content in
            content.camera = .virtual
            let graph = Entity()
            let columns = max(1, Int(ceil(sqrt(Double(hierarchy.groups.count)))))
            let rows = max(1, Int(ceil(Double(hierarchy.groups.count) / Double(columns))))
            let maxTasks = hierarchy.groups.map { $0.tasks.count }.max() ?? 0
            let taskColumns = max(1, min(3, Int(ceil(sqrt(Double(maxTasks))))))
            let taskRows = max(1, Int(ceil(Double(maxTasks) / Double(taskColumns))))
            let maxLines = hierarchy.groups.flatMap(\.tasks).map {
                RanchVAGraphLabels.wrapped($0.title).split(separator: "\n").count
            }.max() ?? 1
            let rowHeight = max(0.9, Float(maxLines) * 0.18 + 0.3)
            let cellWidth: Float = showTaskLabels ? Float(taskColumns) * 3.8 + 2.5 : 1.7
            let cellHeight: Float = showTaskLabels ? Float(taskRows) * rowHeight + 1.5 : 1.6
            for (index, group) in hierarchy.groups.enumerated() {
                let center = SIMD3<Float>(
                    (Float(index % columns) - Float(columns - 1) / 2) * cellWidth,
                    (Float(rows - 1) / 2 - Float(index / columns)) * cellHeight, 0)
                let assetName = "asset:" + group.id.uuidString
                addNode(to: graph, id: assetName, position: center, radius: showTaskLabels ? 0.18 : 0.09, asset: true)
                addLabel(to: graph, id: assetName, text: RanchVAGraphLabels.wrapped(group.asset.name, width: 20), position: center + [0, 0.4, 0], centered: true)
                for (taskIndex, task) in group.tasks.enumerated() {
                    let ring = taskIndex / 12
                    let angle = Float(taskIndex % 12) * 2 * .pi / Float(min(12, group.tasks.count - ring * 12))
                    let radius: Float = 0.25 + Float(ring) * 0.08
                    let compactOffset = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius, 0)
                    let offset = showTaskLabels ? SIMD3<Float>(1.2 + Float(taskIndex % taskColumns) * 3.8,
                        (Float(taskRows - 1) / 2 - Float(taskIndex / taskColumns)) * rowHeight, 0) : compactOffset
                    addNode(to: graph, id: task.id, position: center + offset, radius: showTaskLabels ? 0.075 : 0.03, asset: false)
                    let title = task.title.hasPrefix(group.asset.name + ": ")
                        ? String(task.title.dropFirst(group.asset.name.count + 2)) : task.title
                    if showTaskLabels {
                        addLabel(to: graph, id: task.id, text: RanchVAGraphLabels.wrapped(title), position: center + offset + [0.14, 0, 0], centered: false)
                    }
                    let beam = ModelEntity(mesh: .generateBox(width: 0.004, height: simd_length(offset), depth: 0.004), materials: [UnlitMaterial(color: .gray)])
                    beam.position = center + offset / 2
                    beam.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(offset))
                    graph.addChild(beam)
                }
            }
            content.add(graph)
            content.cameraTarget = graph
        } update: { content in
            guard let graph = content.entities.first else { return }
            for entity in graph.children {
                guard let node = entity as? ModelEntity, node.components[InputTargetComponent.self] != nil else { continue }
                node.model?.materials = [UnlitMaterial(color: node.name == selection ? .white : (node.name.hasPrefix("asset:") ? .cyan : .orange))]
            }
        }
        .id(identity + [String(resetCamera), String(showTaskLabels)])
        .realityViewCameraControls(controls)
        .simultaneousGesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in onSelect(value.entity.name) })
        .accessibilityLabel("Asset hierarchy. Large cyan dots are assets; smaller orange dots are linked tasks. Use the asset list below for accessible details.")
    }

    private func addNode(to graph: Entity, id: String, position: SIMD3<Float>, radius: Float, asset: Bool) {
        let node = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: asset ? .cyan : .orange)])
        node.name = id
        node.position = position
        node.components.set(InputTargetComponent())
        node.generateCollisionShapes(recursive: false)
        graph.addChild(node)
    }

    private func addLabel(to graph: Entity, id: String, text: String, position: SIMD3<Float>, centered: Bool) {
        let label = ModelEntity(mesh: .generateText(text, extrusionDepth: 0.0001, font: .systemFont(ofSize: 0.16)), materials: [UnlitMaterial(color: .white)])
        label.name = id
        label.position.x = centered ? -label.visualBounds(relativeTo: label).extents.x / 2 : 0
        label.components.set(InputTargetComponent())
        label.generateCollisionShapes(recursive: false)
        let anchor = Entity()
        anchor.position = position
        anchor.components.set(BillboardComponent())
        anchor.addChild(label)
        graph.addChild(anchor)
    }
}
#endif
