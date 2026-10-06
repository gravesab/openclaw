#if !os(tvOS)
import SwiftUI
import RealityKit

@MainActor struct RanchVADEVWorkspace: View {
    let propertyStore: RanchOSPropertyLiveStore
    @State private var showsSamples = false
    @State private var filter: RanchVADEVFilter = .all
    @State private var selection: String?
    @State private var focusedAssetID: UUID?
    @State private var expandedGraph = false
    @State private var question = ""
    @State private var response = "Ask to show active tasks, or use Find followed by a title, area or record ID."
    @State private var showsGraph = true
    @State private var voice = VoiceInput()
    @State private var speaker = RanchVASpeaker()
    @State private var weather = RanchVAWeatherStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expandedGraph {
                expandedGraphWorkspace
            } else if let asset = focusedAsset {
                assetWorkspace(asset)
            } else {
            Picker("Data source", selection: $showsSamples) {
                Text("Real DEV · read only").tag(false)
                Text("Sample demo").tag(true)
            }.pickerStyle(.segmented).padding()
            if showsSamples { RanchVAWorkspace() }
            else { liveWorkspace }
            }
        }
        .onChange(of: propertyStore.state) { _, _ in
            selection = nil
            response = "The DEV connection updated. Run a query against the displayed feed."
        }
        .onChange(of: showsSamples) { _, _ in voice.cancel() }
        .onChange(of: scenePhase) { _, value in if value != .active { voice.cancel() } }
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            ScrollView { detailContent.padding() }.frame(minWidth: 360, idealWidth: 600, minHeight: 320)
        }
        .onDisappear { voice.cancel(); speaker.stop() }
        .task {
            if propertyStore.assetsState == .idle { await propertyStore.refreshAssets() }
            if case .unavailable = propertyStore.state { await propertyStore.refresh() }
        }
    }
    private var liveWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Jarvis · Property Manager DEV", systemImage: "sparkle").font(.title2.bold())
                Text("Authenticated assets and task feed · Read only").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh DEV data") {
                        selection = nil
                        response = "Refreshing the DEV task feed…"
                        Task { await propertyStore.refresh(); await propertyStore.refreshAssets() }
                    }.disabled(isLoading)
                    Spacer()
                    Picker("View", selection: $showsGraph) {
                        Text("3D graph").tag(true)
                        Text("Asset list").tag(false)
                    }.pickerStyle(.segmented).frame(maxWidth: 240)
                }
                Divider()
                Text(response)
                HStack {
                    TextField("Show active tasks, or Find …", text: $question).textFieldStyle(.roundedBorder).onSubmit(submit)
                    Button("Send", action: submit)
                }
                HStack {
                    Button("All tasks") { question = "Show all tasks"; submit() }
                    Button("Active tasks") { question = "Show active tasks"; submit() }
                    if voice.phase == .listening {
                        Button("Stop listening") { voice.stop() }
                    } else {
                        Button("Start listening", systemImage: "mic") { speaker.stop(); Task { await voice.start() } }
                            .disabled(voice.isActive)
                    }
                    if voice.isActive { Button("Cancel") { voice.cancel() } }
                    if speaker.isSpeaking { Button("Stop") { speaker.stop() } }
                }
                Text(voice.status).font(.caption).foregroundStyle(.secondary)
                if !voice.draft.text.isEmpty {
                    Text(voice.draft.text)
                    Button("Use transcript") { question = voice.draft.text; voice.cancel() }.disabled(voice.isActive)
                }
                #if os(macOS)
                LogitechCamera()
                #endif
                RanchVAWeatherCard(store: weather)
                switch propertyStore.state {
                case .loading:
                    ProgressView("Loading DEV tasks…")
                case .unavailable(let message):
                    ContentUnavailableView("DEV data unavailable", systemImage: "network.slash", description: Text(message))
                case .ready(let dashboard):
                    records(dashboard.tasks)
                }
                Text("Finance, Livestock, asset documents and calling are not connected to live data here. Tasks are not expense records; Jarvis cannot calculate live spending from this feed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private var isLoading: Bool {
        if case .loading = propertyStore.state { return true }
        return false
    }
    @ViewBuilder private func records(_ tasks: [RanchOSPropertyLiveTask]) -> some View {
        let visible = filter.apply(to: tasks)
        Text("\(visible.count) matching · \(tasks.count) tasks in the returned feed").font(.headline)
        switch propertyStore.assetsState {
        case .idle, .loading: ProgressView("Loading DEV assets…")
        case .unavailable(let message):
            Text("Assets unavailable: " + message).foregroundStyle(.secondary)
        case .ready(let assets):
            let hierarchy = RanchVAAssetHierarchy(assets: assets, tasks: visible)
            Text("\(assets.count) active assets · \(visible.count - hierarchy.unlinked.count) linked tasks · \(hierarchy.unlinked.count) unlinked tasks").font(.headline)
            Text("All assets returned by DEV are included, even with no matching tasks. Archived assets are not supplied by this endpoint.").font(.caption).foregroundStyle(.secondary)
            if showsGraph && !assets.isEmpty {
                Button("Expand 3D view", systemImage: "arrow.up.left.and.arrow.down.right") { expandedGraph = true }
                GeometryReader { geometry in
                    RanchVAAssetGraph(hierarchy: hierarchy, selection: selection, onSelect: selectNode)
                        .frame(width: max(1, geometry.size.width), height: 680)
                }.frame(height: 680)
                    .background(Color(red: 0.035, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                Text("Large cyan dot = asset · Small orange dot = task · Drag to rotate · Click any dot or asset label to drill down").font(.caption)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(hierarchy.groups) { group in
                    Button { focusedAssetID = group.id; voice.cancel() } label: {
                        HStack {
                            Circle().fill(.cyan).frame(width: 16, height: 16)
                            Text(group.asset.name).font(.headline)
                            Spacer()
                            Text("\(group.tasks.count) tasks").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                        }.padding(8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if !hierarchy.unlinked.isEmpty {
                    DisclosureGroup("Unlinked tasks (\(hierarchy.unlinked.count))") {
                        Text("No asset ID, invalid ID, or the linked asset is absent from the active asset feed. No relationship is guessed.").font(.caption)
                        ForEach(hierarchy.unlinked) { task in taskRow(task) }
                    }
                }
            }
        }
        if case .unavailable = propertyStore.assetsState {
            ForEach(visible) { task in taskRow(task) }
        }
    }
    @ViewBuilder private var expandedGraphWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Back to details", systemImage: "arrow.left") { expandedGraph = false }
                Text(focusedAsset?.name ?? "All active assets").font(.headline)
                Spacer()
            }.padding(.horizontal)
            if case .ready(let assets) = propertyStore.assetsState,
               case .ready(let dashboard) = propertyStore.state {
                let shownAssets = focusedAsset.map { [$0] } ?? assets
                let shownTasks = focusedAsset == nil ? filter.apply(to: dashboard.tasks) : dashboard.tasks
                GeometryReader { geometry in
                    RanchVAAssetGraph(hierarchy: RanchVAAssetHierarchy(assets: shownAssets, tasks: shownTasks), selection: selection) { id in
                        if id.hasPrefix("asset:"), focusedAsset != nil { return }
                        selectNode(id)
                    }
                    .frame(width: max(1, min(1600, geometry.size.width)), height: max(1, min(1100, geometry.size.height)))
                    .background(Color(red: 0.035, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.padding(.vertical)
    }
    private var focusedAsset: RanchOSPropertyLiveAsset? {
        guard case .ready(let assets) = propertyStore.assetsState else { return nil }
        return assets.first { $0.id == focusedAssetID }
    }
    private func selectNode(_ id: String) {
        if id.hasPrefix("asset:"), let assetID = UUID(uuidString: String(id.dropFirst(6))) {
            focusedAssetID = assetID
            expandedGraph = false
            selection = nil
            voice.cancel()
        } else { selection = id }
    }
    private func assetWorkspace(_ asset: RanchOSPropertyLiveAsset) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Back to all assets", systemImage: "arrow.left") { focusedAssetID = nil; selection = nil }
                Spacer()
                Text("Property Manager DEV · Read only").font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(asset.name).font(.largeTitle.bold())
                    if case .ready(let dashboard) = propertyStore.state {
                        let linked = dashboard.tasks.filter { $0.assetID == asset.id }
                        Button("Expand 3D view", systemImage: "arrow.up.left.and.arrow.down.right") { expandedGraph = true }
                        GeometryReader { geometry in
                            RanchVAAssetGraph(hierarchy: RanchVAAssetHierarchy(assets: [asset], tasks: linked), selection: selection) { id in
                                if !id.hasPrefix("asset:") { selection = id }
                            }.frame(width: max(1, geometry.size.width), height: 680)
                        }.frame(height: 680)
                            .background(Color(red: 0.035, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                        Text("Only this asset and its \(linked.count) tasks · Click a small orange dot to open a task").font(.caption)
                        GroupBox("Asset details") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Category", value: asset.category ?? "Not supplied")
                                LabeledContent("Location", value: asset.location ?? "Not supplied")
                                LabeledContent("Manufacturer", value: asset.manufacturer ?? "Not supplied")
                                LabeledContent("Model", value: asset.model ?? "Not supplied")
                            }.padding(8).textSelection(.enabled)
                        }
                        GroupBox("Tasks (\(linked.count))") {
                            VStack(alignment: .leading) {
                                if linked.isEmpty { Text("No tasks linked to this asset in the returned feed.") }
                                ForEach(linked) { task in taskRow(task) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GroupBox("Parts and supplies") {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Parts recorded on this asset’s tasks. Quantities are per task, not inventory stock.").font(.caption).foregroundStyle(.secondary)
                                if linked.isEmpty { Text("No task parts supplied for this asset.") }
                                ForEach(linked) { task in
                                    if !(task.parts ?? []).isEmpty || task.legacyPart != nil || task.supplies?.isEmpty == false {
                                        Text(task.title).font(.headline)
                                        taskParts(task)
                                        optionalDetail("Supplies", task.supplies)
                                    }
                                }
                                if !linked.isEmpty && linked.allSatisfy({ ($0.parts ?? []).isEmpty && $0.legacyPart == nil && $0.supplies?.isEmpty != false }) {
                                    Text("No parts or supplies listed in the returned task records.")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    } else { Text("Task data is unavailable. Return to the board to refresh.") }
                }.padding()
            }.id(asset.id)
        }
    }
    @ViewBuilder private func optionalDetail(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder private func taskParts(_ task: RanchOSPropertyLiveTask) -> some View {
        if let parts = task.parts {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in partDetails(part) }
        } else { Text("Detailed parts data was not supplied.").font(.caption) }
        if let legacy = task.legacyPart {
            Text("Task-level part reference").font(.caption)
            partDetails(legacy)
        }
    }
    private func partDetails(_ part: RanchOSPropertyLivePart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(part.name ?? part.number ?? part.oemNumber ?? "Part").font(.headline)
            optionalDetail("Part number", part.number)
            optionalDetail("OEM number", part.oemNumber)
            optionalDetail("Vendor", part.vendor)
            optionalDetail("Quantity", part.quantity)
            optionalDetail("Recorded cost", part.cost)
            optionalDetail("Purchase reference", part.buyURL)
            optionalDetail("Notes", part.notes)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var detailContent: some View {
        if case .ready(let dashboard) = propertyStore.state {
            let tasks = dashboard.tasks
            let visible = tasks
        if let selected = visible.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selected.title).font(.title3.bold())
                LabeledContent("Source", value: "Property Manager DEV · tasks")
                LabeledContent("Area", value: selected.area)
                LabeledContent("Active", value: selected.isActive ? "Yes" : "No")
                LabeledContent("Next due (source)", value: selected.nextDue ?? "Not supplied")
                LabeledContent("Priority", value: selected.priority ?? "Not supplied")
                optionalDetail("Frequency", selected.frequency)
                optionalDetail("Last done (source)", selected.lastDone)
                optionalDetail("Description", selected.taskDescription)
                optionalDetail("Instructions", selected.instructions)
                optionalDetail("Supplies", selected.supplies)
                optionalDetail("Notes", selected.notes)
                optionalDetail("Source manual", selected.sourceManual)
                taskParts(selected)
                Button(focusedAssetID == nil ? "Back to all assets" : "Back to asset") { selection = nil }
            }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        }
    }
    private func taskRow(_ task: RanchOSPropertyLiveTask) -> some View {
        Button { selection = task.id } label: {
            HStack {
                Circle().fill(.orange).frame(width: 8, height: 8)
                VStack(alignment: .leading) {
                    Text(task.title).font(.headline)
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func respond(_ text: String) {
        response = text
        speaker.speak(text)
    }

    private func submit() {
        speaker.stop()
        let weatherQuery = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        if ["weather", "show weather", "what is the weather", "what's the weather"].contains(weatherQuery) {
            question = ""
            Task { await weather.refresh(); respond(weather.answer) }
            return
        }
        guard case .ready(let dashboard) = propertyStore.state else {
            respond("DEV tasks are unavailable. Refresh the connection before asking about them.")
            return
        }
        guard let next = RanchVADEVFilter.parse(question) else {
            respond("Supported: Show all tasks, Show active tasks, or Find followed by text. No action was taken.")
            return
        }
        filter = next
        selection = nil
        respond("Found \(next.apply(to: dashboard.tasks).count) matching records in the current Property Manager DEV feed.")
        question = ""
    }
}

#endif
