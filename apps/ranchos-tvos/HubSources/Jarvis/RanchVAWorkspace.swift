#if !os(tvOS)
import SwiftUI
import RealityKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor public struct RanchVAWorkspace: View {
    @State private var session = FixtureSession()
    @State private var question = ""
    @State private var detailRecord: FixtureRecord?
    @State private var voice = VoiceInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsGraph = true
    @State private var availableWidth: CGFloat = 800
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    public init() {}
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("RanchOS · Jarvis", systemImage: "sparkle").font(.title2.bold())
                    Spacer()
                    Text("DEV · SAMPLE DATA").font(.caption.bold()).foregroundStyle(.mint)
                }
                let wide = availableWidth >= 780
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                                  : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                layout {
                    workspace.frame(maxWidth: .infinity)
                    inspector.frame(width: wide ? 290 : nil)
                }
                Divider()
                Text(session.answer).accessibilityLabel("Assistant: \(session.answer)")
                HStack {
                    TextField("Try a sample question", text: $question)
                        .textFieldStyle(.roundedBorder).onSubmit(submit)
                    Button("Send", action: submit).buttonStyle(.borderedProminent)
                }
                voiceControls
                #if os(macOS)
                LogitechCamera()
                #endif
                ViewThatFits(in: .horizontal) {
                    HStack { suggestions }
                    VStack(alignment: .leading) { suggestions }
                }
                Text("Speech and camera preview stay on this device. Live records and calling are disconnected.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Apple Intelligence readiness") {
                    Text(Self.modelReadiness).font(.footnote)
                    Text("Availability check only. No model session, prompts or remote fallback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
        .background(colorScheme == .dark ? Color(red: 0.035, green: 0.07, blue: 0.09) : Color.white)
        .tint(colorScheme == .dark ? .mint : .teal)
        .sheet(item: $detailRecord) { record in
            FixtureDetailBrowser(root: record, onSelect: session.select)
        }
        .onDisappear { voice.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { voice.cancel() }
        }
    }
    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if voice.phase == .listening {
                    Button("Stop listening", systemImage: "stop.circle") { voice.stop() }
                } else {
                    Button("Start listening", systemImage: "mic") { Task { await voice.start() } }
                        .disabled(voice.isActive)
                }
                if voice.isActive { Button("Cancel") { voice.cancel() } }
                if !voice.isActive && !voice.draft.text.isEmpty {
                    Button("Use transcript") { question = voice.draft.text; voice.cancel() }
                }
            }
            Text(voice.status).font(.caption).foregroundStyle(.secondary)
            if !voice.draft.text.isEmpty {
                Text(voice.draft.text).accessibilityLabel("Speech draft: \(voice.draft.text)")
            }
        }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Workspace", selection: $showsGraph) {
                Text("3D relationships").tag(true)
                Text("Record list").tag(false)
            }.pickerStyle(.segmented)
            if showsGraph {
                // Give RealityKit a finite render surface, including during layout measurement.
                GeometryReader { geometry in
                    NativeRelationshipGraph(selection: session.selection, reduceMotion: reduceMotion, onSelect: session.select)
                        .frame(width: max(1, geometry.size.width), height: 330)
                }.frame(height: 330)
                    .background(Color(red: 0.035, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("3D sample graph centered on the X300. Click a node or use the record buttons to open details.")
                Text("Drag to rotate · Click a node or label for details").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading) {
                ForEach(FixtureRecord.allCases) { record in
                    Button { session.select(record) } label: {
                        Label(record.title, systemImage: session.selection == record ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered)
                    .accessibilityAddTraits(session.selection == record ? .isSelected : [])
                }
            }
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle().stroke(.mint.opacity(0.3), lineWidth: 1)
                Circle().inset(by: 9).stroke(.mint, style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                Text("JARVIS").font(.caption).tracking(3)
            }.frame(width: 105, height: 105).accessibilityHidden(true)
            Text("Ready · Fixture").font(.caption).foregroundStyle(.mint)
            Text(session.showsExpenses ? "John Deere X300" : session.selection.title).font(.title3.bold())
            if session.showsExpenses {
                Text(FixtureExpense.total).font(.largeTitle.monospacedDigit())
                Text("USD · Jan–Sep 2026 · Sample ledger").font(.caption)
                ForEach(FixtureExpense.samples) { expense in
                    HStack { Text(expense.record.title); Spacer(); Text(expense.amount).monospacedDigit() }
                }
                DisclosureGroup("Source transactions") {
                    ForEach(FixtureExpense.samples) { expense in
                        Button("\(expense.id) · \(expense.date) · \(expense.amount)") {
                            openDetails(expense.record)
                        }.font(.caption)
                    }
                    Text("Uncategorized $0.00 · Fixture revision 1").font(.caption)
                }
            } else if session.showsCallDraft {
                Text("Ask the sample dealer about warranty coverage for the April 18 spindle repair.")
                Label("Recipient not verified", systemImage: "exclamationmark.circle")
                Text("May share model, repair date and description. No payment or repair authorization.").font(.footnote)
                Text("Preview only · No call placed").foregroundStyle(.mint)
            } else if let expense = FixtureExpense.samples.first(where: { $0.record == session.selection }) {
                Text(expense.amount).font(.title.monospacedDigit())
                Text("\(expense.id) · \(expense.date)").font(.caption)
            } else {
                Text("Sample relationship · No live source connected").foregroundStyle(.secondary)
            }
            Button("Open record details", systemImage: "doc.text.magnifyingglass") {
                openDetails(session.showsExpenses ? .mower : session.selection)
            }.buttonStyle(.borderedProminent)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    @ViewBuilder private var suggestions: some View {
        Button("Show me the X300") { session.ask("Show me the X300") }
        Button("What have we spent on it?") { session.ask("What have we spent on it?") }
        Button("Prepare a dealer call") { session.ask("Prepare a dealer call") }
    }
    private func openDetails(_ record: FixtureRecord) {
        voice.cancel()
        session.select(record)
        detailRecord = record
    }
    private func submit() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.ask(question)
        question = ""
    }
    private static var modelReadiness: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "On-device language model is available; not enabled for this fixture."
            case .unavailable: return "On-device language model is unavailable. Sample controls remain usable."
            @unknown default: return "Model availability is unknown. Sample controls remain usable."
            }
        }
        #endif
        return "On-device model integration requires a supported system. Sample controls remain usable."
    }
}

@MainActor private struct NativeRelationshipGraph: View {
    let selection: FixtureRecord
    let reduceMotion: Bool
    let onSelect: (FixtureRecord) -> Void
    private static let positions: [SIMD3<Float>] = [
        [0,0,0], [0.48,0.2,0.1], [-0.45,0.16,0.2], [-0.3,-0.3,0.1],
        [0.35,-0.3,-0.1], [-0.55,-0.15,-0.15], [-0.3,0.36,-0.2], [0.55,-0.1,-0.3],
    ]
    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let graph = Entity()
            graph.name = "graph"
            for (index, record) in FixtureRecord.allCases.enumerated() {
                let sphere = ModelEntity(mesh: .generateSphere(radius: index == 0 ? 0.075 : 0.04),
                                         materials: [UnlitMaterial(color: .cyan)])
                sphere.name = record.rawValue
                sphere.components.set(InputTargetComponent())
                sphere.generateCollisionShapes(recursive: false)
                sphere.position = Self.positions[index]
                graph.addChild(sphere)
                let label = ModelEntity(
                    mesh: .generateText(record.title, extrusionDepth: 0.0002,
                                        font: .systemFont(ofSize: 0.075)),
                    materials: [UnlitMaterial(color: .white)])
                label.name = record.rawValue
                label.components.set(InputTargetComponent())
                label.generateCollisionShapes(recursive: false)
                let labelAnchor = Entity()
                labelAnchor.position = Self.positions[index] + SIMD3<Float>(0, index == 0 ? -0.17 : 0.07, 0)
                label.position.x = -label.visualBounds(relativeTo: label).extents.x / 2
                labelAnchor.components.set(BillboardComponent())
                labelAnchor.addChild(label)
                graph.addChild(labelAnchor)

                if index > 0 {
                    let position = Self.positions[index]
                    let beam = ModelEntity(mesh: .generateBox(width: 0.003, height: simd_length(position), depth: 0.003),
                                           materials: [UnlitMaterial(color: .gray)])
                    beam.position = position / 2
                    beam.orientation = simd_quatf(from: SIMD3<Float>(0,1,0), to: simd_normalize(position))
                    graph.addChild(beam)
                }
            }
            content.add(graph)
            content.cameraTarget = graph
        } update: { content in
            guard let graph = content.entities.first(where: { $0.name == "graph" }) else { return }
            for record in FixtureRecord.allCases {
                guard let sphere = graph.findEntity(named: record.rawValue) as? ModelEntity else { continue }
                sphere.model?.materials = [UnlitMaterial(color: record == selection ? .white : .cyan)]
                sphere.scale = SIMD3<Float>(repeating: record == selection ? 1.25 : 1)
            }
        }
        .realityViewCameraControls(.orbit)
        .simultaneousGesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            guard let record = FixtureRecord(rawValue: value.entity.name) else { return }
            onSelect(record)
        })
    }
}

#endif
