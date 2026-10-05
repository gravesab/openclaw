import SwiftUI

enum LivestockDestination: String, CaseIterable, Identifiable {
    case overview, createHerd, herdsInactive, liveStock, liveStockInactive, pets, petsInactive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Herd overview"
        case .createHerd: "Create herd"
        case .herdsInactive: "Herds that have been retired"
        case .liveStock: AnimalCategory.liveStock.label
        case .liveStockInactive: "Live stock that have been retired"
        case .petsInactive: "Pets that have been retired"
        case .pets: AnimalCategory.pets.label
        }
    }
    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .createHerd: "plus"
        case .herdsInactive: "archivebox"
        case .liveStock: "pawprint"
        case .liveStockInactive, .petsInactive: "archivebox"
        case .pets: "dog"
        }
    }
    var category: AnimalCategory? {
        switch self {
        case .overview, .createHerd, .herdsInactive: nil
        case .liveStock, .liveStockInactive: .liveStock
        case .pets, .petsInactive: .pets
        }
    }
    var showsInactive: Bool {
        switch self {
        case .liveStockInactive, .petsInactive: true
        case .overview, .createHerd, .herdsInactive, .liveStock, .pets: false
        }
    }

    func includesAnimal(_ animal: Animal) -> Bool {
        guard let category, category.includes(animal.species) else { return false }
        return showsInactive == animal.isRetired
    }
}

struct LivestockRootView: View {
    @Bindable var store: LivestockStore
    @State private var destination: LivestockDestination? = .overview
    @State private var presentingAddAnimal = false
    @State private var presentingCreateHerd = false
    @State private var addCategory: AnimalCategory = .liveStock
    @State private var appearance: AppearanceChoice = .system
    @State private var activeHerdID: UUID?
    @State private var retiredHerdID: UUID?
    @State private var herdPrompt: HerdSpeciesPrompt?
    @State private var herdStatus: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Livestock Management") {
                    Label(LivestockDestination.overview.label, systemImage: LivestockDestination.overview.icon)
                        .tag(LivestockDestination.overview)
                    if store.canEditStoredAnimal {
                        Button {
                            destination = .overview
                            presentingCreateHerd = true
                        } label: {
                            Label(LivestockDestination.createHerd.label, systemImage: LivestockDestination.createHerd.icon)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 18)
                        .accessibilityLabel("Create herd")
                    }
                    Label(LivestockDestination.herdsInactive.label, systemImage: LivestockDestination.herdsInactive.icon)
                        .padding(.leading, 18)
                        .tag(LivestockDestination.herdsInactive)
                        .accessibilityLabel("Herds that have been retired")
                    Label(LivestockDestination.liveStock.label, systemImage: LivestockDestination.liveStock.icon)
                        .tag(LivestockDestination.liveStock)
                    if store.session.isLive, store.canEditStoredAnimal {
                        addAnimalRow(.liveStock)
                    }
                    Label(LivestockDestination.liveStockInactive.label, systemImage: LivestockDestination.liveStockInactive.icon)
                        .padding(.leading, 18)
                        .tag(LivestockDestination.liveStockInactive)
                        .accessibilityLabel("Live stock that have been retired")
                    Label(LivestockDestination.pets.label, systemImage: LivestockDestination.pets.icon)
                        .tag(LivestockDestination.pets)
                    if store.session.isLive, store.canEditStoredAnimal {
                        addAnimalRow(.pets)
                    }
                    Label(LivestockDestination.petsInactive.label, systemImage: LivestockDestination.petsInactive.icon)
                        .padding(.leading, 18)
                        .tag(LivestockDestination.petsInactive)
                        .accessibilityLabel("Pets that have been retired")
                }
                Section("This herd") {
                    SessionStatusView(session: store.session)
                    fixtureSessionControl
                }
                Section("Appearance") {
                    Picker("Color mode", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Appearance color mode")
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                Text(store.session.statusFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        } content: {
            destinationContent
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                LivestockBuildHeader(stamp: .current)
            }
        }
        .sheet(isPresented: $presentingAddAnimal) {
            AddAnimalSheet(store: store, category: addCategory) {
                destination = addCategory == .pets ? .pets : .liveStock
            }
        }
        .sheet(isPresented: $presentingCreateHerd) {
            CreateHerdSheet(store: store) { createdID in
                activeHerdID = createdID
                destination = .overview
            }
        }
        .alert("Different species", isPresented: Binding(
            get: { herdPrompt != nil },
            set: { if !$0 { herdPrompt = nil } }
        )) {
            Button("Continue") {
                guard let prompt = herdPrompt else { return }
                herdPrompt = nil
                Task { await applyHerdChange(animalID: prompt.animalID, herdID: prompt.herdID) }
            }
            Button("Cancel", role: .cancel) { herdPrompt = nil }
        } message: {
            Text(herdPrompt?.message ?? "")
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private func requestHerdChange(_ animal: Animal, _ herdID: UUID?) {
        if herdID == animal.herdID { return }
        if let herdID,
           let others = HerdSpeciesWarning.otherSpecies(assigning: animal, to: herdID, among: store.animals),
           let herd = store.herds.first(where: { $0.id == herdID }) {
            herdPrompt = HerdSpeciesPrompt(
                animalID: animal.id,
                herdID: herdID,
                message: "\(animal.displayName) is \(animal.speciesDisplay). \(herd.name) already includes \(others). Do you want to continue, or do you want to cancel?"
            )
            return
        }
        let animalID = animal.id
        Task { await applyHerdChange(animalID: animalID, herdID: herdID) }
    }

    private func applyHerdChange(animalID: Animal.ID, herdID: UUID?) async {
        if let herdID {
            herdStatus = await store.assignHerd(animalID: animalID, herdID: herdID)
        } else {
            herdStatus = await store.clearHerd(animalID: animalID)
        }
    }

    @ViewBuilder
    private func addAnimalRow(_ category: AnimalCategory) -> some View {
        Button {
            addCategory = category
            destination = category == .pets ? .pets : .liveStock
            presentingAddAnimal = true
        } label: {
            Label(category.addLabel, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
        .accessibilityLabel(category.addLabel)
    }

    @ViewBuilder private var fixtureSessionControl: some View {
        if store.session.isLive {
            Text("Tags, lifecycle, care, feed, and cost save to the DEV database.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .fixture = store.session {
            Text("Edits in this sample stay until you quit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Open sample session") {
                Task { await store.loadFixtures() }
            }
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch destination ?? .overview {
        case .overview, .createHerd:
            HerdAnimalBrowser(store: store, status: herdStatus, onChange: requestHerdChange)
        case .herdsInactive: RetiredHerdsView(store: store, herdID: $retiredHerdID)
        case .liveStock: AnimalListView(store: store, destination: .liveStock)
        case .liveStockInactive: AnimalListView(store: store, destination: .liveStockInactive)
        case .pets: AnimalListView(store: store, destination: .pets)
        case .petsInactive: AnimalListView(store: store, destination: .petsInactive)
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch destination ?? .overview {
        case .overview, .createHerd:
            ActiveHerdPane(store: store, herdID: $activeHerdID, status: herdStatus, onChange: requestHerdChange)
        case .herdsInactive:
            RetiredHerdPane(store: store, herdID: retiredHerdID)
        case .liveStock, .liveStockInactive, .pets, .petsInactive:
            animalDetail
        }
    }

    @ViewBuilder private var animalDetail: some View {
        if let destination,
           let animal = store.animals.first(where: { $0.id == store.selectedAnimalID }),
           destination.includesAnimal(animal) {
            AnimalDetailView(store: store, animalID: animal.id)
        } else if let destination, destination.category != nil, !store.animals.contains(where: { destination.includesAnimal($0) }) {
            ContentUnavailableView(
                "No animals to select",
                systemImage: "pawprint",
                description: Text(
                    store.session.canOpenFixtureSession
                        ? "Open the sample session to choose an animal."
                        : store.session.banner
                )
            )
        } else {
            ContentUnavailableView(
                "Select an animal",
                systemImage: "pawprint",
                description: Text("Choose an animal from the list.")
            )
        }
    }
}

struct LivestockBuildHeader: View {
    let stamp: LivestockBuildStamp

    var body: some View {
        HStack(spacing: 0) {
            Text(stamp.name)
                .font(.headline)
                .padding(.horizontal, 14)
            headerDivider
            Text(stamp.environment)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
            headerDivider
            headerFact("Version", stamp.version)
            headerDivider
            headerFact("Build", stamp.build)
        }
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stamp.name), \(stamp.environment), \(stamp.headerDetail)")
    }

    private var headerDivider: some View {
        Divider().frame(height: 22)
    }

    private func headerFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 12)
    }
}

struct SessionStatusView: View {
    let session: LivestockReadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(session.statusTitle, systemImage: session.isLive ? "lock.fill" : "pawprint")
                .font(.subheadline.weight(.semibold))
            Text(session.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.statusTitle). \(session.statusDetail)")
    }
}

struct HerdSpeciesPrompt: Identifiable {
    let id = UUID()
    let animalID: Animal.ID
    let herdID: UUID
    let message: String
}

struct HerdSpeciesGroup: Identifiable {
    let id: String
    let animals: [Animal]
}

struct HerdAnimalBrowser: View {
    @Bindable var store: LivestockStore
    var status: String?
    var onChange: (Animal, UUID?) -> Void

    private var groups: [HerdSpeciesGroup] {
        let current = store.animals.filter { !$0.isRetired }
        let titles = Set(current.map(\.speciesDisplay)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return titles.map { title in
            HerdSpeciesGroup(
                id: title,
                animals: current
                    .filter { $0.speciesDisplay == title }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            )
        }
    }

    var body: some View {
        Group {
            if case .loaded = store.overviewState, let overview = store.overview {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], alignment: .leading, spacing: 12) {
                        OverviewCard(title: "Current livestock", value: "\(overview.currentLivestock)", detail: store.session.isLive ? "from the DEV database" : "sample session", icon: "pawprint")
                        OverviewCard(title: "Live stock that have been retired", value: "\(overview.retiredLivestock)", detail: store.session.isLive ? "from the DEV database" : "sample session", icon: "archivebox")
                        OverviewCard(title: "Current pets", value: "\(overview.currentPets)", detail: store.session.isLive ? "from the DEV database" : "sample session", icon: "dog")
                        OverviewCard(title: "Pets that have been retired", value: "\(overview.retiredPets)", detail: store.session.isLive ? "from the DEV database" : "sample session", icon: "archivebox")
                        OverviewCard(title: "Total cost", value: LivestockMoney.usd(overview.totalCost), detail: "cannot go below zero", icon: "dollarsign.circle")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    if let status, !status.isEmpty {
                        Text(status).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
                    }
                    if groups.isEmpty {
                        ContentUnavailableView("No current animals", systemImage: "pawprint", description: Text("Current livestock and pets appear here, grouped by species."))
                    } else {
                        List {
                            ForEach(groups) { group in
                                Section(group.id) {
                                    ForEach(group.animals) { animal in
                                        HerdChoiceRow(
                                            animal: animal,
                                            herds: store.herds.filter { !$0.isRetired },
                                            showsIdentity: false,
                                            canEdit: store.canEditStoredAnimal,
                                            onChange: onChange
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                FixtureStateView(
                    title: "Herd overview",
                    systemImage: "rectangle.3.group",
                    state: store.overviewState,
                    ownershipNote: FixturePresentationBoundary.tenantDisclosure,
                    actionTitle: store.session.canOpenFixtureSession ? "Open sample session" : nil,
                    action: store.session.canOpenFixtureSession ? { Task { await store.loadFixtures() } } : nil
                )
            }
        }
        .navigationTitle("Herd overview")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct ActiveHerdPane: View {
    @Bindable var store: LivestockStore
    @Binding var herdID: UUID?
    var status: String?
    var onChange: (Animal, UUID?) -> Void
    @State private var confirmingRetire = false

    private var activeHerds: [LivestockHerd] {
        store.herds.filter { !$0.isRetired }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedHerd: LivestockHerd? {
        activeHerds.first { $0.id == herdID }
    }

    private var members: [Animal] {
        guard let herdID else { return [] }
        return store.animals
            .filter { $0.herdID == herdID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List {
            Picker("Herd", selection: $herdID) {
                Text("Choose a herd").tag(nil as UUID?)
                ForEach(activeHerds) { herd in
                    Text(herd.name).tag(Optional(herd.id))
                }
            }
            if let selectedHerd {
                Section("Other information") {
                    Text(selectedHerd.notes.isEmpty ? "None" : selectedHerd.notes)
                        .foregroundStyle(selectedHerd.notes.isEmpty ? .secondary : .primary)
                }
                Section("Animals") {
                    if members.isEmpty {
                        Text("No animals are assigned.").foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { animal in
                            HerdChoiceRow(
                                animal: animal,
                                herds: activeHerds,
                                showsIdentity: true,
                                canEdit: store.canEditStoredAnimal,
                                onChange: onChange
                            )
                        }
                    }
                }
                if store.canEditStoredAnimal {
                    Section {
                        Button("Retire herd") { confirmingRetire = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!members.isEmpty)
                        if !members.isEmpty {
                            Text("Reassign or unassign every animal before retiring this herd.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if activeHerds.isEmpty {
                Text("Create a herd to assign animals.").foregroundStyle(.secondary)
            }
            if let status, !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Herd")
        .toolbarTitleDisplayMode(.inline)
        .alert("Retire this herd?", isPresented: $confirmingRetire) {
            Button("Proceed", role: .destructive) {
                guard let selected = herdID else { return }
                Task {
                    let result = await store.retireHerd(herdID: selected)
                    if result.hasPrefix("Herd retired") { herdID = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Retire \(selectedHerd?.name ?? "this herd"). It can no longer be chosen. This cannot be undone. Do you want to proceed, or do you want to cancel?")
        }
    }
}

struct RetiredHerdsView: View {
    @Bindable var store: LivestockStore
    @Binding var herdID: UUID?

    private var retired: [LivestockHerd] {
        store.herds.filter(\.isRetired).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if retired.isEmpty {
                ContentUnavailableView("Herds that have been retired", systemImage: "archivebox", description: Text("No herds have been retired."))
            } else {
                List(selection: $herdID) {
                    ForEach(retired) { herd in
                        Button {
                            herdID = herd.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(herd.name).font(.headline)
                                Text(herd.retiredAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date not recorded")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(herd.id as UUID?)
                    }
                }
            }
        }
        .navigationTitle("Herds that have been retired")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct RetiredHerdPane: View {
    let store: LivestockStore
    let herdID: UUID?

    private var herd: LivestockHerd? {
        store.herds.first { $0.id == herdID && $0.isRetired }
    }

    var body: some View {
        if let herd {
            List {
                LabeledContent("Retired", value: herd.retiredAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date not recorded")
                Section("Other information") {
                    Text(herd.notes.isEmpty ? "None" : herd.notes)
                }
            }
            .navigationTitle(herd.name)
            .toolbarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Herds that have been retired", systemImage: "archivebox", description: Text("Choose a herd."))
        }
    }
}

struct HerdChoiceRow: View {
    let animal: Animal
    let herds: [LivestockHerd]
    var showsIdentity: Bool
    var canEdit: Bool
    var onChange: (Animal, UUID?) -> Void

    private var choices: [LivestockHerd] {
        herds.filter { !$0.isRetired }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(animal.displayName)
                .frame(minWidth: 120, alignment: .leading)
            if showsIdentity {
                Text(animal.speciesDisplay).foregroundStyle(.secondary)
                Text(animal.breedDisplay).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canEdit {
                Picker("Active herd", selection: Binding(
                    get: { animal.herdID },
                    set: { onChange(animal, $0) }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(choices) { herd in
                        Text(herd.name).tag(Optional(herd.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel("Active herd for \(animal.displayName)")
            } else {
                Text(animal.herdName ?? "None").foregroundStyle(.secondary)
            }
        }
    }
}

struct CreateHerdSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: LivestockStore
    var onCreated: (UUID?) -> Void
    @State private var name = ""
    @State private var notes = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create herd").font(.title2.bold())
            Text(store.session.isLive ? "Saved in the DEV livestock database." : "Saved in this sample session.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Herd name", text: $name)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other information")
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
            }
            .formStyle(.grouped)
            if let message {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create herd") {
                    let enteredName = name
                    let enteredNotes = notes
                    Task {
                        let cleaned = enteredName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        let result = await store.createHerd(name: cleaned, notes: enteredNotes)
                        if result.hasPrefix("Herd saved") {
                            let createdID = store.herds.first { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }?.id
                            onCreated(createdID)
                            dismiss()
                        } else {
                            message = result
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct OverviewCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct AnimalListView: View {
    @Bindable var store: LivestockStore
    let destination: LivestockDestination

    private var animals: [Animal] {
        store.animals.filter { destination.includesAnimal($0) }
    }

    var body: some View {
        Group {
            if case .loaded = store.animalsState, animals.isEmpty {
                ContentUnavailableView(
                    destination.showsInactive ? destination.label : "No \(destination.label.lowercased())",
                    systemImage: destination.icon,
                    description: Text(
                        destination.showsInactive
                            ? "These are the \(destination.category == .pets ? "pets" : "live stock") that have been retired, with the date and total cost."
                            : "Use \(destination.category?.addLabel ?? "Add") in the left pane."
                    )
                )
            } else if case .loaded = store.animalsState {
                List(animals, selection: $store.selectedAnimalID) { animal in
                    Button {
                        store.selectedAnimalID = animal.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(animal.displayName).font(.headline)
                            Text(rowDetail(animal))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(animal.id as Animal.ID?)
                }
            } else {
                FixtureStateView(
                    title: "Animals",
                    systemImage: "pawprint",
                    state: store.animalsState,
                    ownershipNote: FixturePresentationBoundary.tenantDisclosure,
                    actionTitle: store.session.canOpenFixtureSession ? "Open sample session" : nil,
                    action: store.session.canOpenFixtureSession ? { Task { await store.loadFixtures() } } : nil
                )
            }
        }
        .navigationTitle(destination.label)
        .toolbarTitleDisplayMode(.inline)
    }

    private func rowDetail(_ animal: Animal) -> String {
        if destination.showsInactive {
            let when = animal.retiredOn?.formatted(date: .abbreviated, time: .omitted) ?? "Date not recorded"
            var line = "\(when) · \(LivestockMoney.usd(animal.recordedCostTotal))"
            if let saleAmount = animal.saleAmount, let saleOn = animal.saleOn {
                let saleDay = saleOn.formatted(date: .abbreviated, time: .omitted)
                line += " · Sale \(LivestockMoney.usd(saleAmount)) on \(saleDay)"
            }
            return line
        }
        if animal.species == .pet {
            return "\(animal.speciesDisplay) · \(animal.breedDisplay) · \(animal.identifierSummary)\(herdSuffix(animal))"
        }
        return "\(animal.species.label) · \(animal.productionType.label) · \(animal.identifierSummary)\(herdSuffix(animal))"
    }

    private func herdSuffix(_ animal: Animal) -> String {
        guard let name = animal.herdName, !name.isEmpty else { return "" }
        return " · \(name)"
    }
}

struct AnimalDetailView: View {
    @Bindable var store: LivestockStore
    let animalID: Animal.ID
    @State private var kind: LivestockIdentifierKind = .earTag
    @State private var value = ""
    @State private var identifierCost = ""
    @State private var retirementReason: LivestockIdentifierRetirementReason?
    @State private var saleAmount = ""
    @State private var saleOn = Date()
    @State private var message: String?
    @State private var pendingRetirement: IdentifierRetirementPrompt?
    @State private var lifecycleType: LivestockLifecycleEventType?
    @State private var occurredAt = Date()
    @State private var careType: LivestockCareEventType?
    @State private var careAt = Date()
    @State private var careCost = ""
    @State private var feedLines = [LivestockFeedEntry(inputType: .feed)]
    @State private var supplier = ""
    @State private var batch = ""
    @State private var feedAt = Date()
    @State private var costAmount = ""
    @State private var financeReference = ""
    @State private var productionChoice: ProductionType = .breeding
    @State private var breedChoice: Breed?
    @State private var classificationMessage: String?

    private var pendingSave: LivestockAnimalSaveDraft {
        LivestockAnimalSaveDraft(
            identifierKind: kind,
            identifierValue: value,
            lifecycleType: lifecycleType,
            lifecycleAt: occurredAt,
            careType: careType,
            careAt: careAt,
            feedLines: feedLines,
            feedAt: feedAt,
            supplier: supplier,
            batch: batch,
            identifierCost: identifierCost,
            careCost: careCost,
            costAmount: costAmount,
            financeReference: financeReference
        )
    }

    private var animal: Animal? {
        store.animals.first { $0.id == animalID }
    }

    private var canEditIdentifiers: Bool { store.canEditStoredAnimal }

    private var canRecordLifecycle: Bool { store.canEditStoredAnimal }

    var body: some View {
        if let animal {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(animal.displayName).font(.largeTitle.bold())
                        Text("\(animal.retirementDisplay) · \(animal.identifierSummary)").foregroundStyle(.secondary)
                        if store.session.isLive {
                            Text(FixturePresentationBoundary.classificationStoredBoundary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Classification", icon: "tag") {
                        LabeledContent("Species", value: animal.speciesDisplay)
                        if animal.species != .pet, canEditIdentifiers {
                            Picker("Production type", selection: $productionChoice) {
                                ForEach(LivestockCatalog.productionChoices(for: animal.species, including: animal.productionType)) { item in
                                    Text(item.label).tag(item)
                                }
                            }
                            Picker("Breed", selection: $breedChoice) {
                                Text("No breed").tag(nil as Breed?)
                                ForEach(LivestockCatalog.breedChoices(for: animal.species, including: animal.breed)) { item in
                                    Text(item.label).tag(Optional(item))
                                }
                            }
                            Button("Save classification") {
                                let animalID = animal.id
                                let production = productionChoice
                                let breed = breedChoice
                                Task {
                                    classificationMessage = await store.updateClassification(
                                        animalID: animalID,
                                        production: production,
                                        breed: breed
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!classificationChanged(animal))
                            if let classificationMessage {
                                Text(classificationMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            if animal.species != .pet {
                                LabeledContent("Production type", value: animal.productionType.label)
                            }
                            LabeledContent("Breed", value: animal.breedDisplay)
                        }
                    }
                    DetailSection(title: "Herd", icon: "rectangle.3.group") {
                        if let name = animal.herdName, !name.isEmpty {
                            LabeledContent("Herd", value: name)
                            if let started = animal.herdStartedAt {
                                LabeledContent("Since", value: started.formatted(date: .abbreviated, time: .shortened))
                            }
                        } else {
                            Text("No herd").foregroundStyle(.secondary)
                        }
                        Text("Change a herd from Herd overview. The herd picker is on the same row as the animal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DetailSection(title: "Identifiers", icon: "number") {
                        if animal.identifiers.isEmpty {
                            Text(animal.species == .pet ? "No license" : "No identifier").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.identifiers) { identifier in
                                LabeledContent(identifier.kind.label, value: identifier.value)
                            }
                        }
                        if canEditIdentifiers, !animal.isRetired {
                            Picker("Kind", selection: $kind) {
                                ForEach(LivestockIdentifierKind.choices(for: animal.species)) { item in
                                    Text(item.label).tag(item)
                                }
                            }
                            TextField(kind.valuePrompt, text: $value)
                            TextField("Cost", text: $identifierCost)
                            Text("Required when assigning an identifier. Zero is allowed. A negative amount corrects an earlier entry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !store.session.isLive {
                                Text(FixturePresentationBoundary.identifierBoundary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    DetailSection(title: "Retirement", icon: "archivebox") {
                        if animal.isRetired {
                            LabeledContent("Reason", value: animal.retirementDisplay)
                            if let saleAmount = animal.saleAmount, let saleOn = animal.saleOn {
                                LabeledContent("Sale amount", value: LivestockMoney.usd(saleAmount))
                                LabeledContent("Sale date", value: saleOn.formatted(date: .abbreviated, time: .omitted))
                            }
                        } else {
                            Text("Currently active")
                            if canEditIdentifiers {
                                Picker("Reason", selection: $retirementReason) {
                                    Text("Choose a reason").tag(nil as LivestockIdentifierRetirementReason?)
                                    ForEach(LivestockIdentifierRetirementReason.choices(for: animal.species)) { item in
                                        Text(item.label).tag(Optional(item))
                                    }
                                }
                                if retirementReason == .sold {
                                    DatePicker("Sale date", selection: $saleOn, displayedComponents: .date)
                                    TextField("Sale amount", text: $saleAmount)
                                    Text("Required for a sale. Zero is allowed.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Retire") {
                                    guard let reason = retirementReason else { return }
                                    pendingRetirement = IdentifierRetirementPrompt(
                                        animalID: animal.id,
                                        animalName: animal.displayName,
                                        species: animal.species,
                                        identifierIDs: animal.identifiers.filter(\.isActive).map(\.id),
                                        reason: reason,
                                        saleAmount: reason == .sold ? saleAmount : nil,
                                        saleOn: reason == .sold ? saleOn : nil
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canRetire(animal))
                            }
                        }
                        if let message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Routine lifecycle history", icon: "clock.arrow.circlepath") {
                        if animal.lifecycleEvents.isEmpty {
                            Text("No routine lifecycle history").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.lifecycleEvents) { event in
                                LabeledContent(event.type.label, value: event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        if canRecordLifecycle, !animal.isRetired {
                            Picker("Event", selection: $lifecycleType) {
                                Text("None").tag(nil as LivestockLifecycleEventType?)
                                ForEach(LivestockLifecycleEventType.allCases) { item in
                                    Text(item.label).tag(Optional(item))
                                }
                            }
                            if lifecycleType != nil {
                                DatePicker("Occurred", selection: $occurredAt)
                            }
                            if !store.session.isLive {
                                Text(FixturePresentationBoundary.lifecycleBoundary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    DetailSection(title: "Care", icon: "cross.case") {
                        if animal.careEvents.isEmpty {
                            Text("No care records").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.careEvents) { event in
                                LabeledContent(event.type.label, value: event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            Picker("Care", selection: $careType) {
                                Text("None").tag(nil as LivestockCareEventType?)
                                ForEach(LivestockCareEventType.allCases) { item in
                                    Text(item.label).tag(Optional(item))
                                }
                            }
                            if careType != nil {
                                DatePicker("Occurred", selection: $careAt)
                            }
                            TextField("Cost", text: $careCost)
                            Text("Required when recording care. Zero is allowed. A negative amount corrects an earlier entry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(FixturePresentationBoundary.careRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Feed", icon: "leaf") {
                        if animal.consumptions.isEmpty {
                            Text("No feed consumption").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.consumptions) { item in
                                LabeledContent(item.summary, value: item.observedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            ForEach($feedLines) { $line in
                                VStack(alignment: .leading, spacing: 8) {
                                    Picker("Feed", selection: $line.inputType) {
                                        ForEach(LivestockInputType.entryChoices(for: animal.species)) { item in
                                            Text(item.label).tag(item)
                                        }
                                    }
                                    TextField("Quantity", text: $line.quantity)
                                    Picker("Unit", selection: $line.unit) {
                                        ForEach(LivestockInputUnit.entryChoices) { item in
                                            Text(item.label).tag(item)
                                        }
                                    }
                                    Picker("Frequency", selection: $line.frequency) {
                                        ForEach(LivestockCostFrequency.allCases) { item in
                                            Text(item.label).tag(item)
                                        }
                                    }
                                    TextField("Cost", text: $line.cost)
                                    if feedLines.count > 1 {
                                        Button("Remove") { feedLines.removeAll { $0.id == line.id } }
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                            Button("Add feed") {
                                let type = LivestockInputType.entryChoices(for: animal.species).first ?? .feed
                                feedLines.append(LivestockFeedEntry(inputType: type))
                            }
                            TextField("Supplier", text: $supplier)
                            TextField("Batch", text: $batch)
                            DatePicker("Observed", selection: $feedAt)
                            Text(animal.species == .pet
                                ? "Add dry food, wet food, or a supplement. Each line keeps its own cost. Zero is allowed. A negative amount corrects an earlier entry."
                                : "Add feed, hay, or a supplement. Each line keeps its own cost. Zero is allowed. A negative amount corrects an earlier entry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(FixturePresentationBoundary.feedRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Cost", icon: "dollarsign.circle") {
                        let operationalCosts = animal.costs.filter { $0.frequency == nil }
                        if operationalCosts.isEmpty {
                            Text("No operational costs").foregroundStyle(.secondary)
                        } else {
                            ForEach(operationalCosts) { item in
                                Text(item.summary)
                            }
                        }
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            TextField("Amount in USD", text: $costAmount)
                            TextField("Finance reference", text: $financeReference)
                            Text("A negative amount corrects an earlier entry. Total Cost cannot go below zero.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(FixturePresentationBoundary.costRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if canEditIdentifiers, !animal.isRetired {
                        let summary = pendingSave.costSummary(recorded: animal.costs)
                        ForEach(summary.feedSubtotals) { row in
                            LabeledContent(row.label, value: LivestockMoney.usdSigned(row.amount))
                        }
                        LabeledContent("Feed total", value: LivestockMoney.usdSigned(summary.feedTotal))
                            .font(.headline)
                        LabeledContent("Other", value: LivestockMoney.usdSigned(summary.other))
                        Text("Feed lines add into Feed total. Total Cost adds Feed total to identifier, care, and operational costs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("Total Cost", value: LivestockMoney.usd(summary.total))
                        .font(.title3.bold())
                        if let problem = pendingSave.costProblem() {
                            Text(problem).font(.callout).foregroundStyle(.orange)
                        }
                        Button("Save") {
                            let animalID = animal.id
                            let draft = pendingSave
                            Task {
                                let result = await store.saveAnimalRecords(animalID: animalID, draft: draft)
                                if result.savedIdentifier { value = "" }
                                if result.acceptedIdentifierCost { identifierCost = "" }
                                if result.savedLifecycle { lifecycleType = nil }
                                if result.savedCare { careType = nil }
                                if result.acceptedCareCost { careCost = "" }
                                if result.savedFeed || result.acceptedFeedCost {
                                    let type = LivestockInputType.entryChoices(for: animal.species).first ?? .feed
                                    feedLines = [LivestockFeedEntry(inputType: type)]
                                    supplier = ""
                                    batch = ""
                                }
                                if result.savedCost {
                                    costAmount = ""
                                    financeReference = ""
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pendingSave.isEmpty || pendingSave.costProblem() != nil)
                        Text(FixturePresentationBoundary.saveConfirmsBoundary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DetailSection(title: "Costs by date", icon: "calendar") {
                        let days = LivestockCostLedger.days(from: animal.costs)
                        if days.isEmpty {
                            Text("No costs recorded").foregroundStyle(.secondary)
                        } else {
                            ForEach(days) { day in
                                LabeledContent(day.day.formatted(date: .abbreviated, time: .omitted), value: LivestockMoney.usd(day.total))
                                    .font(.headline)
                                ForEach(day.lines) { line in
                                    LabeledContent(
                                        "\(line.label) · \(line.recordedAt.formatted(date: .omitted, time: .shortened))",
                                        value: LivestockMoney.usdSigned(line.amount)
                                    )
                                }
                            }
                        }
                    }
                    Text(FixturePresentationBoundary.deferredSliceDisclosure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .onAppear { alignIdentifierChoices(for: animal) }
            .onChange(of: animal.id) { _, _ in alignIdentifierChoices(for: animal) }
            .onChange(of: animal.productionType) { _, _ in alignClassification(for: animal) }
            .onChange(of: animal.breed) { _, _ in alignClassification(for: animal) }
            .alert(
                "Retire \(pendingRetirement?.animalName ?? "this animal")?",
                isPresented: Binding(
                    get: { pendingRetirement != nil },
                    set: { if !$0 { pendingRetirement = nil } }
                )
            ) {
                Button("Proceed", role: .destructive) {
                    guard let pending = pendingRetirement else { return }
                    pendingRetirement = nil
                    let animalID = pending.animalID
                    let reason = pending.reason
                    Task {
                        let result = await store.retireAnimal(
                        animalID: animalID,
                        reason: reason,
                        saleAmount: pending.saleAmount,
                        saleOn: pending.saleOn
                    )
                        if case .rejected(let text) = result {
                            message = text
                        } else {
                            retirementReason = nil
                            message = store.session.isLive
                                ? FixturePresentationBoundary.databaseWriteBoundary
                                : "Retired."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(retirementConfirmation(pendingRetirement))
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = store.saveNotice, notice.animalID == animalID {
                    Label(notice.message, systemImage: notice.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(notice.succeeded ? Color.green : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(notice.succeeded ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                }
            }
        }
    }
}

private extension AnimalDetailView {
    func alignIdentifierChoices(for animal: Animal) {
        alignClassification(for: animal)
        if !kind.fits(animal.species) {
            kind = animal.species == .pet ? .license : .earTag
        }
        if let retirementReason, !retirementReason.fits(animal.species) {
            self.retirementReason = nil
        }
        let choices = LivestockInputType.entryChoices(for: animal.species)
        for index in feedLines.indices where !choices.contains(feedLines[index].inputType) {
            feedLines[index].inputType = choices[0]
        }
    }

    private func alignClassification(for animal: Animal) {
        productionChoice = animal.productionType
        breedChoice = animal.breed
    }

    private func classificationChanged(_ animal: Animal) -> Bool {
        productionChoice != animal.productionType || breedChoice?.code != animal.breed?.code
    }

    func canRetire(_ animal: Animal) -> Bool {
        guard let retirementReason, retirementReason.fits(animal.species) else { return false }
        guard retirementReason == .sold else { return true }
        return LivestockMoney.requirement(saleAmount, label: "Sale amount", allowZero: true) == nil
    }

    func retirementConfirmation(_ pending: IdentifierRetirementPrompt?) -> String {
        let subject = pending?.species == .pet ? "this pet" : "this animal"
        let reason = pending?.reason.label ?? "the selected reason"
        if pending?.reason == .sold, let text = pending?.saleAmount, let amount = LivestockMoney.decimal(text), let saleOn = pending?.saleOn {
            let day = saleOn.formatted(date: .abbreviated, time: .omitted)
            return "Retire \(subject) as Sold for \(LivestockMoney.usd(amount)) on \(day). This cannot be undone. Do you want to proceed, or do you want to cancel?"
        }
        return "Retire \(subject) as \(reason). This cannot be undone. Do you want to proceed, or do you want to cancel?"
    }
}

private struct IdentifierRetirementPrompt: Identifiable {
    let animalID: Animal.ID
    let animalName: String
    let species: Species
    let identifierIDs: [UUID]
    let reason: LivestockIdentifierRetirementReason
    var saleAmount: String? = nil
    var saleOn: Date? = nil

    var id: Animal.ID { animalID }
}

struct DetailSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }
}

struct FixtureStateView: View {
    let title: String
    let systemImage: String
    let state: FixtureLoadState
    let ownershipNote: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            if case .loading = state { ProgressView("Loading fixture state") }
            if let message = state.message {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
            Text(ownershipNote).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

struct AddAnimalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: LivestockStore
    let category: AnimalCategory
    var onCreated: () -> Void
    @State private var draft: AddAnimalDraft
    @State private var confirmation: String?

    init(store: LivestockStore, category: AnimalCategory, onCreated: @escaping () -> Void) {
        self.store = store
        self.category = category
        self.onCreated = onCreated
        _draft = State(initialValue: AddAnimalDraft(category: category))
    }

    private var canSubmit: Bool {
        draft.isValidCatalogSelection
            && !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.petFormProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(category == .pets ? "Add pet" : category.addLabel).font(.title2.bold())
            Text(store.session.isLive ? FixturePresentationBoundary.databaseWriteBoundary : FixturePresentationBoundary.addAnimalBoundary)
                .foregroundStyle(.secondary)
            Form {
                TextField("Display name", text: $draft.displayName)
                if category == .pets {
                    Picker("Species", selection: Binding(get: { draft.petKind }, set: { draft.selectPetKind($0) })) {
                        Text("Select species").tag(PetKind?.none)
                        ForEach(PetKind.allCases) { Text($0.label).tag(PetKind?.some($0)) }
                    }
                    if draft.petKind == .other {
                        TextField("Species", text: $draft.petSpeciesOther)
                        TextField("Breed", text: $draft.typedBreed)
                    } else if draft.petKind != nil {
                        Picker("Breed", selection: $draft.petBreedChoice) {
                            Text("No breed selected").tag("")
                            ForEach(LivestockCatalog.petBreeds(for: draft.petKind), id: \.self) { Text($0).tag($0) }
                            if draft.petKind == .dog {
                                Text("Mixed").tag("mixed")
                            }
                            Text("Type a breed").tag("typed")
                        }
                        if draft.petBreedChoice == "typed" {
                            TextField("Breed", text: $draft.typedBreed)
                        }
                        if draft.petKind == .dog, draft.petBreedChoice == "mixed" {
                            petMixField("First breed", text: $draft.mixBreedOne)
                            petMixField("Second breed", text: $draft.mixBreedTwo)
                        }
                    }
                } else {
                    Picker("Species", selection: Binding(get: { draft.species }, set: { draft.selectSpecies($0) })) {
                        Text("Select species").tag(Species?.none)
                        ForEach(category.speciesChoices) { Text($0.label).tag(Species?.some($0)) }
                    }
                    Picker("Production type", selection: Binding(get: { draft.productionType }, set: { draft.selectProductionType($0) })) {
                        Text("Select production type").tag(ProductionType?.none)
                        ForEach(LivestockCatalog.productionTypes(for: draft.species)) { Text($0.label).tag(ProductionType?.some($0)) }
                    }
                    .disabled(draft.species == nil)
                    Picker("Breed", selection: Binding(get: { draft.breed }, set: { draft.selectBreed($0) })) {
                        Text("No breed selected").tag(Breed?.none)
                        ForEach(LivestockCatalog.breeds(for: draft.species)) { Text($0.label).tag(Breed?.some($0)) }
                    }
                    .disabled(draft.species == nil)
                }
            }
            .formStyle(.grouped)
            if let confirmation { Label(confirmation, systemImage: "info.circle").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(category == .pets ? "Add pet" : category.addLabel) {
                    let entered = draft
                    Task {
                        switch await store.createAnimal(entered) {
                        case .created:
                            onCreated()
                            dismiss()
                        case .rejected(let message):
                            confirmation = message
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func petMixField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: text)
            Menu("Choose a listed breed") {
                ForEach(LivestockCatalog.dogBreeds, id: \.self) { breed in
                    Button(breed) { text.wrappedValue = breed }
                }
            }
        }
    }
}
