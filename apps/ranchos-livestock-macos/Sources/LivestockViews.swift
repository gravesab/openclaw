import SwiftUI

enum LivestockDestination: String, CaseIterable, Identifiable {
    case overview, herd, createHerd, herdsInactive, liveStock, liveStockInactive, breeding, pets, petsInactive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Herds/groups overview"
        case .herd: "Herd/group"
        case .createHerd: "Create herd/group"
        case .herdsInactive: "Herds/groups retired to a better life"
        case .liveStock: AnimalCategory.liveStock.label
        case .liveStockInactive: "Livestock/group retired to a better life"
        case .breeding: "Breeding tree"
        case .petsInactive: "Pets retired to a better life"
        case .pets: AnimalCategory.pets.label
        }
    }
    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .herd: "leaf"
        case .createHerd: "plus"
        case .herdsInactive: "archivebox"
        case .liveStock: "pawprint"
        case .liveStockInactive, .petsInactive: "archivebox"
        case .breeding: "arrow.triangle.branch"
        case .pets: "dog"
        }
    }
    var category: AnimalCategory? {
        switch self {
        case .overview, .herd, .createHerd, .herdsInactive, .breeding: nil
        case .liveStock, .liveStockInactive: .liveStock
        case .pets, .petsInactive: .pets
        }
    }
    var showsInactive: Bool {
        switch self {
        case .liveStockInactive, .petsInactive: true
        case .overview, .herd, .createHerd, .herdsInactive, .liveStock, .breeding, .pets: false
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
        split
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

    @ViewBuilder private var split: some View {
        #if os(iOS)
        NavigationSplitView {
            sidebar
        } detail: {
            destinationContent
        }
        #else
        NavigationSplitView {
            sidebar
        } content: {
            destinationContent
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detailContent
        }
        #endif
    }

    private var sidebar: some View {
        List(selection: $destination) {
                Section {
                    LivestockIdentityBadge(stamp: .current)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                }
                Section("Herds/Groups") {
                    LivestockWrappingLabel(title: LivestockDestination.overview.label, systemImage: LivestockDestination.overview.icon)
                        .tag(LivestockDestination.overview)
                    LivestockWrappingLabel(title: LivestockDestination.herd.label, systemImage: LivestockDestination.herd.icon)
                        .tag(LivestockDestination.herd)
                        .accessibilityLabel("Herd/group. Record feed or care for a whole herd/group.")
                    if store.canEditStoredAnimal {
                        Button {
                            destination = .overview
                            presentingCreateHerd = true
                        } label: {
                            LivestockWrappingLabel(title: LivestockDestination.createHerd.label, systemImage: LivestockDestination.createHerd.icon)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create herd/group")
                    }
                    LivestockWrappingLabel(title: LivestockDestination.herdsInactive.label, systemImage: LivestockDestination.herdsInactive.icon)
                        .tag(LivestockDestination.herdsInactive)
                        .accessibilityLabel("Herds/groups retired to a better life")
                }
                Section("Livestock/Group") {
                    LivestockWrappingLabel(title: LivestockDestination.liveStock.label, systemImage: LivestockDestination.liveStock.icon)
                        .tag(LivestockDestination.liveStock)
                    if store.canEditStoredAnimal {
                        addAnimalRow(.liveStock)
                    }
                    LivestockWrappingLabel(title: LivestockDestination.liveStockInactive.label, systemImage: LivestockDestination.liveStockInactive.icon)
                        .tag(LivestockDestination.liveStockInactive)
                        .accessibilityLabel("Livestock/group retired to a better life")
                    LivestockWrappingLabel(title: LivestockDestination.breeding.label, systemImage: LivestockDestination.breeding.icon)
                        .tag(LivestockDestination.breeding)
                }
                Section("Pets") {
                    LivestockWrappingLabel(title: LivestockDestination.pets.label, systemImage: LivestockDestination.pets.icon)
                        .tag(LivestockDestination.pets)
                    if store.canEditStoredAnimal {
                        addAnimalRow(.pets)
                    }
                    LivestockWrappingLabel(title: LivestockDestination.petsInactive.label, systemImage: LivestockDestination.petsInactive.icon)
                        .tag(LivestockDestination.petsInactive)
                        .accessibilityLabel("Pets retired to a better life")
                }
                Section("This herd") {
                    SessionStatusView(
                        session: store.session,
                        connectedUntil: store.liveRecords?.expiresAt,
                        holdMessage: store.connectionHoldMessage
                    )
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
            #if os(iOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 320)
            #else
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #endif
            .navigationTitle(LivestockBuildStamp.current.name)
            .safeAreaInset(edge: .bottom) {
                Text(store.session.statusFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.bar)
            }
    }

    private func requestHerdChange(_ animal: Animal, _ herdID: UUID?) {
        if herdID == animal.herdID { return }
        if let herdID, LivestockHerdMenu.selection(herdID, among: store.herds) == nil { return }
        if let herdID,
           let others = HerdSpeciesWarning.otherSpecies(assigning: animal, to: herdID, among: store.animals),
           let herd = store.herds.first(where: { $0.id == herdID && !$0.isRetired }) {
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
            LivestockWrappingLabel(title: category.addLabel, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.addLabel)
    }

    @ViewBuilder private var fixtureSessionControl: some View {
        if store.session.isLive {
            Text("Tags, lifecycle, care, feed, and cost save to the \(LivestockBuildStamp.current.databaseLabel).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if store.isReconnecting {
            ProgressView("Connecting to the DEV database…")
                .font(.caption)
        } else {
            Button("Reconnect") {
                Task { await store.reconnectToDev() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch destination ?? .overview {
        case .overview, .createHerd:
            HerdAnimalBrowser(
                store: store,
                herdID: $activeHerdID,
                status: herdStatus,
                onChange: requestHerdChange,
                onOpen: { destination = $0 },
                onAdd: store.canEditStoredAnimal ? { category in
                    addCategory = category
                    destination = category == .pets ? .pets : .liveStock
                    presentingAddAnimal = true
                } : nil
            )
        case .herd:
            #if os(iOS)
            ActiveHerdPane(store: store, herdID: $activeHerdID, status: herdStatus, onChange: requestHerdChange)
            #else
            OpenHerdsView(store: store, herdID: $activeHerdID)
            #endif
        case .herdsInactive: RetiredHerdsView(store: store, herdID: $retiredHerdID)
        case .liveStock: AnimalListView(store: store, destination: .liveStock)
        case .liveStockInactive: AnimalListView(store: store, destination: .liveStockInactive)
        case .breeding: BreedingTreeView(store: store)
        case .pets: AnimalListView(store: store, destination: .pets)
        case .petsInactive: AnimalListView(store: store, destination: .petsInactive)
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch destination ?? .overview {
        case .overview, .createHerd, .herd:
            ActiveHerdPane(store: store, herdID: $activeHerdID, status: herdStatus, onChange: requestHerdChange)
        case .herdsInactive:
            RetiredHerdPane(store: store, herdID: retiredHerdID)
        case .breeding:
            BreedingTreeDetail(store: store)
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
                    store.session.canReconnect
                        ? "The \(LivestockBuildStamp.current.databaseLabel) is not connected."
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

struct LivestockWrappingLabel: View {
    let title: String
    let systemImage: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    @ViewBuilder
    func livestockScreenTitle(_ title: String) -> some View {
        #if os(iOS)
        self.toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        #else
        self.navigationTitle(title)
        #endif
    }
}

struct LivestockWrappingContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
            configuration.content
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LivestockIdentityBadge: View {
    let stamp: LivestockBuildStamp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stamp.name)
                .font(.caption.weight(.heavy))
                .tracking(0.4)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(Color(red: 0.69, green: 0.51, blue: 0.12), in: Capsule())
            Text(stamp.headerDetail)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.09, green: 0.13, blue: 0.10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.94, blue: 0.86), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stamp.name), \(stamp.headerDetail)")
    }
}

struct SessionStatusView: View {
    let session: LivestockReadSession
    var connectedUntil: Date? = nil
    var holdMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(session.statusTitle, systemImage: session.isLive ? "lock.fill" : "pawprint")
                .font(.subheadline.weight(.semibold))
            if session.isLive {
                Text(LivestockDevLoopbackRead.connectedWhileOpenCaption)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let connectedUntil {
                    Text(LivestockDevLoopbackRead.connectedUntilCaption(connectedUntil))
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(session.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if session.isLive, let holdMessage {
                Text(holdMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [session.statusTitle]
        if session.isLive {
            parts.append(LivestockDevLoopbackRead.connectedWhileOpenCaption)
        }
        if session.isLive, let connectedUntil {
            parts.append(LivestockDevLoopbackRead.connectedUntilCaption(connectedUntil))
        }
        parts.append(session.statusDetail)
        if session.isLive, let holdMessage {
            parts.append(holdMessage)
        }
        return parts.joined(separator: ". ")
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

struct LivestockDatedFact: Identifiable {
    let id: UUID
    let title: String
    let when: Date
}

struct HerdAnimalBrowser: View {
    @Bindable var store: LivestockStore
    @Binding var herdID: UUID?
    var status: String?
    var onChange: (Animal, UUID?) -> Void
    var onOpen: (LivestockDestination) -> Void
    var onAdd: ((AnimalCategory) -> Void)?
    @State private var petHerdID: UUID?
    @State private var petID: UUID?

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

    private var careFacts: [LivestockDatedFact] {
        let animalRows = store.animals.flatMap { animal in
            animal.careEvents.filter(\.isActive).map {
                LivestockDatedFact(id: $0.id, title: "\(animal.displayName) · \($0.summary)", when: $0.occurredAt)
            }
        }
        let herdRows = store.herds.flatMap { herd in
            herd.careEvents.filter(\.isActive).map {
                LivestockDatedFact(id: $0.id, title: "\(herd.name) · \($0.summary)", when: $0.occurredAt)
            }
        }
        return (animalRows + herdRows).sorted { $0.when > $1.when }
    }

    private var feedFacts: [LivestockDatedFact] {
        let animalRows = store.animals.flatMap { animal in
            animal.consumptions.filter(\.isActive).map {
                LivestockDatedFact(id: $0.id, title: "\(animal.displayName) · \($0.summary)", when: $0.observedAt)
            }
        }
        let herdRows = store.herds.flatMap { herd in
            herd.consumptions.filter(\.isActive).map {
                LivestockDatedFact(id: $0.id, title: "\(herd.name) · \($0.summary)", when: $0.observedAt)
            }
        }
        return (animalRows + herdRows).sorted { $0.when > $1.when }
    }

    private func categoryRow(_ destination: LivestockDestination, count: Int) -> some View {
        Button {
            onOpen(destination)
        } label: {
            LivestockWrappingLabel(title: destination.label, systemImage: destination.icon, trailing: "\(count)")
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("\(destination.label), \(count)")
    }

    private func addRow(_ category: AnimalCategory) -> some View {
        Button {
            onAdd?(category)
        } label: {
            LivestockWrappingLabel(title: category.addLabel, systemImage: "plus")
        }
        .accessibilityLabel(category.addLabel)
    }

    var body: some View {
        Group {
            if case .loaded = store.overviewState, let overview = store.overview {
                List {
                    Section {
                        Button {
                            onOpen(.herd)
                        } label: {
                            LivestockWrappingLabel(
                                title: LivestockDestination.herd.label,
                                systemImage: LivestockDestination.herd.icon
                            )
                            .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Herd. Record feed or care for a whole herd.")
                    }
                    Section("Livestock/Group") {
                        categoryRow(.liveStock, count: overview.currentLivestock)
                        if onAdd != nil {
                            addRow(.liveStock)
                        }
                        categoryRow(.liveStockInactive, count: overview.retiredLivestock)
                    }
                    Section("Pets") {
                        categoryRow(.pets, count: overview.currentPets)
                        if onAdd != nil {
                            addRow(.pets)
                        }
                        categoryRow(.petsInactive, count: overview.retiredPets)
                    }
                    if store.canEditStoredAnimal {
                        addPetToHerdSection
                    }
                    Section("Care") {
                        let rows = careFacts
                        if rows.isEmpty {
                            Text("No care records").foregroundStyle(.secondary)
                        } else {
                            ForEach(rows) { row in
                                LabeledContent(row.title, value: row.when.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                    Section("Feed") {
                        Button {
                            onOpen(.herd)
                        } label: {
                            Text("Record feed for a whole herd/group")
                        }
                        .accessibilityLabel("Record feed for a whole herd/group")
                        let rows = feedFacts
                        if rows.isEmpty {
                            Text("No feed records").foregroundStyle(.secondary)
                        } else {
                            ForEach(rows) { row in
                                LabeledContent(row.title, value: row.when.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                    Section("Total estimated cost") {
                        LabeledContent("Total estimated cost", value: LivestockMoney.usd(overview.totalCost))
                        Text("cannot go below zero")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let status, !status.isEmpty {
                        Section {
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if groups.isEmpty {
                        Section {
                            Text("Current livestock/group and pets appear here, grouped by species.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(groups) { group in
                            Section(group.id) {
                                ForEach(group.animals) { animal in
                                    HerdChoiceRow(
                                        animal: animal,
                                        herds: LivestockHerdMenu.assignable(store.herds),
                                        showsIdentity: false,
                                        canEdit: store.canEditStoredAnimal,
                                        onChange: onChange,
                                        onRename: store.canEditStoredAnimal ? { name in
                                            await store.renameAnimal(animalID: animal.id, displayName: name)
                                        } : nil
                                    )
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            } else {
                FixtureStateView(
                    title: LivestockDestination.overview.label,
                    systemImage: "rectangle.3.group",
                    state: store.overviewState,
                    ownershipNote: FixturePresentationBoundary.tenantDisclosure,
                    actionTitle: store.session.canReconnect && !store.isReconnecting ? "Reconnect" : nil,
                    action: store.session.canReconnect && !store.isReconnecting ? { Task { await store.reconnectToDev() } } : nil
                )
            }
        }
        .livestockScreenTitle(LivestockDestination.overview.label)
        .onAppear { dropRetiredHerdSelections() }
        .onChange(of: store.herds) { _, _ in dropRetiredHerdSelections() }
    }

    private func dropRetiredHerdSelections() {
        let open = LivestockHerdMenu.assignable(store.herds)
        if LivestockHerdMenu.selection(herdID, among: store.herds) == nil {
            herdID = open.count == 1 ? open.first?.id : nil
        }
        if LivestockHerdMenu.selection(petHerdID, among: store.herds) == nil {
            petHerdID = nil
        }
    }

    private var activeHerds: [LivestockHerd] {
        LivestockHerdMenu.assignable(store.herds)
    }

    private var petsAvailableForHerd: [Animal] {
        store.animals
            .filter { $0.species == .pet && !$0.isRetired && $0.herdID != petHerdID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder
    private var addPetToHerdSection: some View {
        Section("Add a pet to a herd") {
            if activeHerds.isEmpty {
                Text("Create a herd, then choose it here.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Herd", selection: Binding(
                    get: { LivestockHerdMenu.selection(petHerdID, among: store.herds) },
                    set: { petHerdID = $0 }
                )) {
                    Text("Choose a herd").tag(nil as UUID?)
                    ForEach(activeHerds) { herd in
                        Text(herd.name).tag(Optional(herd.id))
                    }
                }
                if petsAvailableForHerd.isEmpty {
                    Text("Add a pet, then choose it here.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Pet", selection: $petID) {
                        Text("Choose a pet").tag(nil as UUID?)
                        ForEach(petsAvailableForHerd) { pet in
                            Text("\(pet.displayName) · \(pet.breedDisplay)").tag(Optional(pet.id))
                        }
                    }
                    Button("Add pet to herd") {
                        guard let petHerdID, let pet = store.animals.first(where: { $0.id == petID }) else { return }
                        onChange(pet, petHerdID)
                        petID = nil
                    }
                    .disabled(petHerdID == nil || petID == nil)
                }
            }
        }
    }
}

struct OpenHerdsView: View {
    @Bindable var store: LivestockStore
    @Binding var herdID: UUID?

    private var herds: [LivestockHerd] {
        LivestockHerdMenu.assignable(store.herds)
    }

    var body: some View {
        Group {
            if herds.isEmpty {
                ContentUnavailableView(
                    "Herd",
                    systemImage: LivestockDestination.herd.icon,
                    description: Text("Create a herd, then record feed or care for the whole herd here.")
                )
            } else {
                List(selection: $herdID) {
                    ForEach(herds) { herd in
                        Text(herd.name).tag(Optional(herd.id))
                    }
                }
            }
        }
        .livestockScreenTitle(LivestockDestination.herd.label)
        .onAppear { selectOpenHerd() }
        .onChange(of: store.herds) { _, _ in selectOpenHerd() }
    }

    private func selectOpenHerd() {
        let open = LivestockHerdMenu.assignable(store.herds)
        if LivestockHerdMenu.selection(herdID, among: store.herds) == nil {
            herdID = open.count == 1 ? open.first?.id : nil
        }
    }
}

struct ActiveHerdPane: View {
    @Bindable var store: LivestockStore
    @Binding var herdID: UUID?
    var status: String?
    var onChange: (Animal, UUID?) -> Void
    @State private var confirmingRetire = false
    @State private var careType: LivestockCareEventType?
    @State private var careAt = Date()
    @State private var shotName = ""
    @State private var medicineName = ""
    @State private var medicineKind = ""
    @State private var careDosage = ""
    @State private var careCost = ""
    @State private var careFinanceReference = ""
    @State private var careStatus: String?
    @State private var feedLines = [LivestockFeedEntry(inputType: .hay)]
    @State private var feedAt = Date()
    @State private var supplier = ""
    @State private var pickedSupplier = ""
    @State private var suppliers = LivestockSupplierDirectory()
    @State private var batch = ""
    @State private var feedStatus: String?
    @State private var products = LivestockProductDirectory()
    @State private var correctionTarget: LivestockCorrectionTarget?

    private var activeHerds: [LivestockHerd] {
        LivestockHerdMenu.assignable(store.herds)
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
            Picker("Herd", selection: Binding(
                get: { LivestockHerdMenu.selection(herdID, among: store.herds) },
                set: { herdID = $0 }
            )) {
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
                Section("Name") {
                    RecordNameEditor(
                        label: "Herd name",
                        savedName: selectedHerd.name,
                        recordID: selectedHerd.id.uuidString,
                        canEdit: store.canEditStoredAnimal,
                        onSave: { await store.renameHerd(herdID: selectedHerd.id, name: $0) }
                    )
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
                                onChange: onChange,
                                onRename: store.canEditStoredAnimal ? { name in
                                    await store.renameAnimal(animalID: animal.id, displayName: name)
                                } : nil
                            )
                        }
                    }
                }
                Section("Care") {
                    if selectedHerd.careEvents.isEmpty {
                        Text("No herd care").foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedHerd.careEvents) { event in
                            LabeledContent(
                                costTitle(event.historyTitle, cost: event.isActive ? selectedHerd.eventCost(event.id) : nil),
                                value: event.occurredAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if event.isActive, canCorrectHerd {
                                Button("Correct") { correctionTarget = .care(event) }
                            }
                        }
                    }
                    if !selectedHerd.careCostByType.isEmpty {
                        Text("Cost by type").font(.subheadline.bold())
                        ForEach(selectedHerd.careCostByType) { row in
                            LabeledContent(row.label, value: LivestockMoney.usdSigned(row.amount))
                        }
                    }
                    Text("This care belongs to the herd. It is not copied onto each animal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if store.session.isLive, store.canEditStoredAnimal {
                        Picker("Care", selection: $careType) {
                            Text("None").tag(nil as LivestockCareEventType?)
                            ForEach(LivestockCareEventType.allCases) { item in
                                Text(item.label).tag(Optional(item))
                            }
                        }
                        if careType == .vaccination {
                            LivestockProductFields(
                                category: .vaccination,
                                fieldTitle: "Shot",
                                name: $shotName,
                                kind: $medicineKind,
                                catalog: $products
                            )
                            Text("Leave this blank, or name the shot. Scanning adds it to the list; choose it if you want it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if careType == .medicationAdministration {
                            LivestockProductFields(
                                category: .medication,
                                fieldTitle: "Medicine",
                                kindTitle: "Kind",
                                name: $medicineName,
                                kind: $medicineKind,
                                catalog: $products
                            )
                            Text("Leave these blank, or enter the medicine and its kind. Scanning adds it to the list; choose it if you want it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let type = careType, type.requiresDosage {
                            LivestockDosageField(dosage: $careDosage, note: type.dosageRequirementNote)
                        }
                        if let type = careType {
                            DatePicker("Occurred", selection: $careAt)
                            LivestockAverageCostField(
                                emptyHint: type.costRequirementNote,
                                costs: selectedHerd.costs,
                                reference: $careFinanceReference,
                                amount: $careCost
                            )
                            Text(FixturePresentationBoundary.careRecordBoundary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let problem = herdCareCostProblem {
                                Text(problem).font(.callout).foregroundStyle(.orange)
                            }
                            Button("Save herd care") {
                                let id = selectedHerd.id
                                Task {
                                    careStatus = await store.saveHerdCare(
                                        herdID: id,
                                        type: type,
                                        occurredAt: careAt,
                                        itemName: type == .vaccination ? shotName : (type == .medicationAdministration ? medicineName : ""),
                                        itemKind: type == .medicationAdministration ? medicineKind : "",
                                        cost: careCost,
                                        financeReference: careFinanceReference,
                                        dosage: type.requiresDosage ? careDosage : ""
                                    )
                                    if careStatus?.hasPrefix("Herd care saved") == true {
                                        careType = nil
                                        shotName = ""
                                        medicineName = ""
                                        medicineKind = ""
                                        careDosage = ""
                                        careCost = ""
                                        careFinanceReference = ""
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(herdCareCostProblem != nil)
                        }
                    } else if store.canEditStoredAnimal {
                        Text("Connect to the \(LivestockBuildStamp.current.databaseLabel) to record herd care.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Feed") {
                    if selectedHerd.consumptions.isEmpty {
                        Text("No herd feed").foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedHerd.consumptions) { item in
                            LabeledContent(
                                costTitle(item.historyTitle, cost: item.isActive ? selectedHerd.eventCost(item.id) : nil),
                                value: item.observedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if item.isActive, canCorrectHerd {
                                Button("Correct") { correctionTarget = .feed(item) }
                            }
                        }
                    }
                    if !selectedHerd.feedCostByType.isEmpty {
                        Text("Cost by type").font(.subheadline.bold())
                        ForEach(selectedHerd.feedCostByType) { row in
                            LabeledContent(row.label, value: LivestockMoney.usdSigned(row.amount))
                        }
                    }
                    LabeledContent("Herd feed total", value: LivestockMoney.usd(selectedHerd.recordedCostTotal))
                        .font(.headline)
                    Text("This feed belongs to the herd. It is not copied onto each animal. Quantity and cost are required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if store.session.isLive, store.canEditStoredAnimal {
                        ForEach($feedLines) { $line in
                            LivestockFeedLineFields(
                                line: $line,
                                costs: selectedHerd.costs,
                                feedChoices: LivestockInputType.herdChoices,
                                catalog: $products,
                                showsRemove: feedLines.count > 1,
                                onRemove: { feedLines.removeAll { $0.id == line.id } }
                            )
                        }
                        DatePicker("Observed", selection: $feedAt)
                        Button("Add feed") {
                            feedLines.append(LivestockFeedEntry(inputType: .hay))
                        }
                        LivestockSupplierFields(
                            supplier: $supplier,
                            pickedSupplier: $pickedSupplier,
                            suppliers: suppliers,
                            batch: $batch
                        )
                        if let problem = herdFeedProblem {
                            Text(problem).font(.callout).foregroundStyle(.orange)
                        }
                        Button("Save herd feed") {
                            let id = selectedHerd.id
                            let lines = feedLines
                            Task {
                                feedStatus = await store.saveHerdFeed(
                                    herdID: id,
                                    lines: lines,
                                    observedAt: feedAt,
                                    supplier: supplier,
                                    batch: batch
                                )
                                if feedStatus?.hasPrefix("Herd feed saved") == true {
                                    feedLines = [LivestockFeedEntry(inputType: .hay)]
                                    suppliers.remember(supplier)
                                    suppliers.save()
                                    supplier = suppliers.last
                                    pickedSupplier = suppliers.last
                                    batch = ""
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!LivestockFeedEntry.canSave(feedLines))
                    } else if store.canEditStoredAnimal {
                        Text("Connect to the \(LivestockBuildStamp.current.databaseLabel) to record herd feed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            } else {
                Text("Choose a herd/group to record feed or care for the whole herd/group.")
                    .foregroundStyle(.secondary)
            }
            if let status, !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let careStatus, !careStatus.isEmpty {
                Text(careStatus).font(.callout).foregroundStyle(.secondary)
            }
            if let feedStatus, !feedStatus.isEmpty {
                Text(feedStatus).font(.callout).foregroundStyle(.secondary)
            }
        }
        .livestockScreenTitle(LivestockDestination.herd.label)
        .onAppear {
            dropRetiredSelection()
            refreshSuppliers(fillEmpty: true)
            refreshProducts()
        }
        .onChange(of: store.herds) { _, _ in
            dropRetiredSelection()
            refreshSuppliers(fillEmpty: supplier.isEmpty)
            refreshProducts()
        }
        .sheet(item: $correctionTarget) { target in
            LivestockRecordCorrectionSheet(store: store, herdID: herdID, target: target)
        }
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

    private var canCorrectHerd: Bool {
        store.session.isLive && store.fixtureWriteRole.canCorrectLifecycle && store.canEditStoredAnimal
    }

    private var herdCareCostProblem: String? {
        careType?.costProblem(careCost) ?? careType?.dosageProblem(careDosage)
    }

    private func dropRetiredSelection() {
        let open = LivestockHerdMenu.assignable(store.herds)
        if LivestockHerdMenu.selection(herdID, among: store.herds) == nil {
            herdID = open.count == 1 ? open.first?.id : nil
        }
    }

    private func refreshSuppliers(fillEmpty: Bool) {
        suppliers = LivestockSupplierDirectory.load().merging(animals: store.animals, herds: store.herds)
        guard fillEmpty, supplier.isEmpty, !suppliers.last.isEmpty else { return }
        supplier = suppliers.last
        pickedSupplier = suppliers.last
    }

    private func refreshProducts() {
        products = LivestockProductDirectory.load().merging(animals: store.animals, herds: store.herds)
    }

    private var herdFeedProblem: String? {
        for line in feedLines where line.hasQuantity || !line.cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let problem = LivestockFeedEntry.problem(quantity: line.quantity, cost: line.cost, feed: line.inputType.label) {
                return problem
            }
        }
        return nil
    }

    private func costTitle(_ title: String, cost: Decimal?) -> String {
        guard let cost else { return title }
        return "\(title) · \(LivestockMoney.usdSigned(cost))"
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
                ContentUnavailableView(LivestockDestination.herdsInactive.label, systemImage: "archivebox", description: Text("No herds/groups have been retired."))
            } else {
                List(selection: $herdID) {
                    if let selected = retired.first(where: { $0.id == herdID }) {
                        Section("Name") {
                            RecordNameEditor(
                                label: "Herd name",
                                savedName: selected.name,
                                recordID: selected.id.uuidString,
                                canEdit: store.canEditStoredAnimal,
                                onSave: { await store.renameHerd(herdID: selected.id, name: $0) }
                            )
                        }
                    }
                    ForEach(retired) { herd in
                        #if os(iOS)
                        NavigationLink {
                            RetiredHerdPane(store: store, herdID: herd.id)
                        } label: {
                            retiredHerdLabel(herd)
                        }
                        #else
                        Button {
                            herdID = herd.id
                        } label: {
                            retiredHerdLabel(herd)
                        }
                        .buttonStyle(.plain)
                        .tag(herd.id as UUID?)
                        #endif
                    }
                }
            }
        }
        .livestockScreenTitle(LivestockDestination.herdsInactive.label)
    }

    private func retiredHerdLabel(_ herd: LivestockHerd) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(herd.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(herd.retiredAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date not recorded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct RetiredHerdPane: View {
    @Bindable var store: LivestockStore
    let herdID: UUID?

    private var herd: LivestockHerd? {
        store.herds.first { $0.id == herdID && $0.isRetired }
    }

    var body: some View {
        if let herd {
            List {
                Section("Name") {
                    RecordNameEditor(
                        label: "Herd name",
                        savedName: herd.name,
                        recordID: herd.id.uuidString,
                        canEdit: store.canEditStoredAnimal,
                        onSave: { await store.renameHerd(herdID: herd.id, name: $0) }
                    )
                }
                LabeledContent("Retired", value: herd.retiredAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date not recorded")
                Section("Other information") {
                    Text(herd.notes.isEmpty ? "None" : herd.notes)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #if os(iOS)
            .labeledContentStyle(LivestockWrappingContentStyle())
            #endif
            .livestockScreenTitle(herd.name)
        } else {
            ContentUnavailableView(LivestockDestination.herdsInactive.label, systemImage: "archivebox", description: Text("Choose a herd/group."))
        }
    }
}

struct LivestockCostEntry: View {
    let title: String
    @Binding var amount: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            HStack {
                TextField("0.00", text: Binding(
                    get: { amount },
                    set: { amount = LivestockMoney.entry($0) }
                ), prompt: Text("0.00"))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
                .appleIntelligenceDictation(Binding(
                    get: { amount },
                    set: { amount = LivestockMoney.entry($0) }
                ))
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct LivestockAverageCostField: View {
    var title: String = "Average cost"
    var emptyHint: String = "No transaction is on this animal. Enter an average cost. This does not post to Finance."
    let costs: [LivestockCostAttribution]
    @Binding var reference: String
    @Binding var amount: String

    private var linked: [LivestockCostAttribution] {
        costs.filter { !($0.financeReference ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !linked.isEmpty {
                Picker("Transaction", selection: Binding(
                    get: { reference },
                    set: { newValue in
                        reference = newValue
                        if let match = linked.first(where: { $0.financeReference == newValue }) {
                            amount = LivestockMoney.entry(match.amount)
                        }
                    }
                )) {
                    Text(title).tag("")
                    ForEach(linked) { cost in
                        Text("\(cost.financeReference ?? "") · \(LivestockMoney.usdSigned(LivestockMoney.signed(cost.amount)))")
                            .tag(cost.financeReference ?? "")
                    }
                }
            }
            LivestockCostEntry(title: title, amount: $amount)
            Text(linked.isEmpty
                ? emptyHint
                : "The amount follows the transaction you choose. Choose \(title) to type one yourself. This does not post to Finance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LivestockFeedLineFields: View {
    @Binding var line: LivestockFeedEntry
    var costs: [LivestockCostAttribution]
    var feedChoices: [LivestockInputType]
    @Binding var catalog: LivestockProductDirectory
    var costTitle: String = "Cost"
    var costHint: String = "Enter the cost of one feeding. This does not post to Finance."
    var showsRemove: Bool
    var onRemove: () -> Void
    @State private var unusedFeedName = ""
    @State private var unusedFeedKind = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LivestockProductFields(
                category: .feed,
                fieldTitle: "Feed",
                feedChoices: feedChoices,
                name: $unusedFeedName,
                kind: $unusedFeedKind,
                feedType: $line.inputType,
                catalog: $catalog
            )
            labeled("Feed") {
                Picker("Feed", selection: $line.inputType) {
                    ForEach(feedChoices) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            labeled("Quantity") {
                HStack {
                    TextField("1", text: $line.quantity, prompt: Text("1"))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: line.quantity) { _, newValue in
                            let limited = String(newValue.filter(\.isNumber).prefix(2))
                            if limited != newValue { line.quantity = limited }
                        }
                        .appleIntelligenceDictation($line.quantity)
                    Spacer(minLength: 0)
                }
            }
            labeled("Unit") {
                Picker("Unit", selection: $line.unit) {
                    ForEach(LivestockInputUnit.entryChoices) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            labeled("Frequency") {
                Picker("Frequency", selection: $line.frequency) {
                    ForEach(LivestockCostFrequency.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            LivestockAverageCostField(
                title: costTitle,
                emptyHint: costHint,
                costs: costs,
                reference: $line.financeReference,
                amount: $line.cost
            )
            LabeledContent("Estimated annual cost", value: LivestockMoney.usdSigned(line.annualFeedCost))
            if line.hasQuantity || !line.cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let problem = LivestockFeedEntry.problem(
                quantity: line.quantity,
                cost: line.cost,
                feed: line.inputType.label
               ) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsRemove {
                Button("Remove", action: onRemove)
            }
        }
        .padding(.bottom, 8)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct LivestockSupplierFields: View {
    @Binding var supplier: String
    @Binding var pickedSupplier: String
    var suppliers: LivestockSupplierDirectory
    @Binding var batch: String

    var body: some View {
        Group {
            if !suppliers.names.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suppliers")
                        .foregroundStyle(.secondary)
                    Picker("Suppliers", selection: $pickedSupplier) {
                        Text("Choose a supplier").tag("")
                        ForEach(suppliers.names, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .onChange(of: pickedSupplier) { _, name in
                    guard !name.isEmpty else { return }
                    supplier = name
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Supplier")
                    .foregroundStyle(.secondary)
                TextField("Supplier", text: $supplier, prompt: Text("Supplier"))
                    .appleIntelligenceDictation($supplier)
            }
            Text("Choosing a supplier fills in the last name saved from feed. You can change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch")
                    .foregroundStyle(.secondary)
                TextField("Batch", text: $batch, prompt: Text("Batch"))
                    .appleIntelligenceDictation($batch)
            }
        }
    }
}

struct RecordNameEditor: View {
    let label: String
    let savedName: String
    let recordID: String
    var canEdit: Bool
    var prominent = false
    var onSave: (String) async -> String
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        Group {
            if canEdit {
                TextField(label, text: $draft)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .appleIntelligenceDictation($draft)
                Button("Save name") {
                    let entered = draft
                    Task { message = await onSave(entered) }
                }
                .disabled(cleaned.isEmpty || cleaned == savedName)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if prominent {
                Text(savedName)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(savedName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = savedName }
        .onChange(of: recordID) { _, _ in
            draft = savedName
            message = nil
        }
        .onChange(of: savedName) { _, newName in
            let typed = draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            draft = newName
            if typed != newName { message = nil }
        }
    }

    private var cleaned: String {
        draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct HerdChoiceRow: View {
    let animal: Animal
    let herds: [LivestockHerd]
    var showsIdentity: Bool
    var canEdit: Bool
    var onChange: (Animal, UUID?) -> Void
    var onRename: ((String) async -> String)? = nil

    private var choices: [LivestockHerd] {
        LivestockHerdMenu.assignable(herds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onRename {
                RecordNameEditor(
                    label: "Name",
                    savedName: animal.displayName,
                    recordID: animal.id.uuidString,
                    canEdit: canEdit,
                    onSave: onRename
                )
            } else {
                Text(animal.displayName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsIdentity {
                Text("\(animal.speciesDisplay) · \(animal.breedDisplay)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            herdControl
        }
    }

    @ViewBuilder
    private var herdControl: some View {
        if canEdit {
            Picker("Active herd", selection: Binding(
                get: { LivestockHerdMenu.selection(animal.herdID, among: herds) },
                set: { onChange(animal, $0) }
            )) {
                Text("None").tag(nil as UUID?)
                ForEach(choices) { herd in
                    Text(herd.name).tag(Optional(herd.id))
                }
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #endif
            .labelsHidden()
            #if os(macOS)
            .frame(maxWidth: 220)
            #endif
            .accessibilityLabel("Active herd for \(animal.displayName)")
        } else {
            Text(animal.herdName ?? "None").foregroundStyle(.secondary)
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
        #if os(iOS)
        NavigationStack {
            Form {
                Section {
                    Text(store.session.isLive ? "Saved in the \(LivestockBuildStamp.current.databaseLabel)." : "Connect to the \(LivestockBuildStamp.current.databaseLabel) to save a herd.")
                        .foregroundStyle(.secondary)
                }
                Section("Herd name") {
                    TextField("Herd name", text: $name)
                        .textInputAutocapitalization(.words)
                        .appleIntelligenceDictation($name)
                }
                Section("Other information") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                        .appleIntelligenceDictation($notes)
                }
                if let message {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    createHerdButton
                        .frame(maxWidth: .infinity, alignment: .center)
                } footer: {
                    Text("Enter a herd/group name, then tap Create herd/group.")
                }
            }
            .navigationTitle(LivestockDestination.createHerd.label)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(LivestockDestination.createHerd.label).font(.title2.bold())
            Text(store.session.isLive ? "Saved in the \(LivestockBuildStamp.current.databaseLabel)." : "Connect to the \(LivestockBuildStamp.current.databaseLabel) to save a herd/group.")
                .foregroundStyle(.secondary)
            TextField("Herd name", text: $name)
                .textFieldStyle(.roundedBorder)
                .appleIntelligenceDictation($name)
            VStack(alignment: .leading, spacing: 6) {
                Text("Other information")
                TextEditor(text: $notes)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .appleIntelligenceDictation($notes)
            }
            if let message {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                createHerdButton
            }
        }
        .padding(24)
        .frame(width: 520)
        #endif
    }

    private var createHerdButton: some View {
        Button(LivestockDestination.createHerd.label) {
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
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

struct BreedingTreeView: View {
    @Bindable var store: LivestockStore

    private var livestock: [Animal] {
        store.animals
            .filter { $0.species != .pet }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List(selection: $store.selectedAnimalID) {
            if livestock.isEmpty {
                Text("Add livestock to record sire, dam, and who they are bred with.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(livestock) { animal in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(animal.displayName).font(.headline)
                        Text(treeSummary(animal))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(animal.id as Animal.ID?)
                }
            }
        }
        .livestockScreenTitle(LivestockDestination.breeding.label)
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if let animal = focused {
                BreedingTreeCanvas(animal: animal, animals: store.animals)
                    .padding()
            }
        }
        #endif
    }

    private var focused: Animal? {
        livestock.first { $0.id == store.selectedAnimalID } ?? livestock.first
    }

    private func treeSummary(_ animal: Animal) -> String {
        var parts = [animal.productionType.label]
        if let sire = store.animals.first(where: { $0.id == animal.sireID }) {
            parts.append("Sire \(sire.displayName)")
        }
        if let dam = store.animals.first(where: { $0.id == animal.damID }) {
            parts.append("Dam \(dam.displayName)")
        }
        if let mate = store.animals.first(where: { $0.id == animal.bredWithID }) {
            parts.append("Bred with \(mate.displayName)")
        }
        return parts.joined(separator: " · ")
    }
}

struct BreedingTreeDetail: View {
    @Bindable var store: LivestockStore

    private var livestock: [Animal] {
        store.animals.filter { $0.species != .pet }
    }

    var body: some View {
        if let animal = livestock.first(where: { $0.id == store.selectedAnimalID }) ?? livestock.first {
            ScrollView {
                BreedingTreeCanvas(animal: animal, animals: store.animals)
                    .padding(24)
            }
            .livestockScreenTitle(animal.displayName)
        } else {
            ContentUnavailableView(
                LivestockDestination.breeding.label,
                systemImage: "arrow.triangle.branch",
                description: Text("Choose an animal to see sire, dam, the current mate, and offspring.")
            )
        }
    }
}

struct BreedingTreeCanvas: View {
    let animal: Animal
    let animals: [Animal]

    var body: some View {
        let tree = LivestockBreeding.tree(for: animal, among: animals)
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                ancestorColumn(tree.sire, title: "Sire")
                ancestorColumn(tree.dam, title: "Dam")
            }
            breedingCard(name: tree.name, role: tree.role, prominent: true)
            if let mate = tree.mate {
                VStack(spacing: 8) {
                    Text("Bred with").font(.caption).foregroundStyle(.secondary)
                    breedingCard(name: mate.name, role: mate.role, prominent: false)
                }
            }
            if !tree.mates.isEmpty {
                labeledRow("Also bred to", tree.mates)
            }
            if !tree.offspring.isEmpty {
                labeledRow("Offspring", tree.offspring)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func ancestorColumn(_ node: LivestockBreedingNode?, title: String) -> some View {
        VStack(spacing: 8) {
            if let sire = node?.sire {
                breedingCard(name: sire.name, role: "Sire", prominent: false)
            }
            if let dam = node?.dam {
                breedingCard(name: dam.name, role: "Dam", prominent: false)
            }
            if let node {
                breedingCard(name: node.name, role: title, prominent: false)
            } else {
                breedingCard(name: "Unknown", role: title, prominent: false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func labeledRow(_ title: String, _ nodes: [LivestockBreedingNode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(nodes) { node in
                    breedingCard(name: node.name, role: node.role, prominent: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breedingCard(name: String, role: String, prominent: Bool) -> some View {
        VStack(spacing: 4) {
            Text(role).font(.caption).foregroundStyle(.secondary)
            Text(name)
                .font(prominent ? .title3.bold() : .headline)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(minWidth: 120)
        .background(prominent ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AnimalListView: View {
    @Bindable var store: LivestockStore
    let destination: LivestockDestination
    @State private var query = ""

    private var inDestination: [Animal] {
        store.animals.filter { destination.includesAnimal($0) }
    }

    private var animals: [Animal] {
        LivestockAnimalSearch.listed(inDestination, query: query)
    }

    var body: some View {
        Group {
            if case .loaded = store.animalsState, inDestination.isEmpty {
                ContentUnavailableView(
                    destination.showsInactive ? destination.label : "No \(destination.label.lowercased())",
                    systemImage: destination.icon,
                    description: Text(
                        destination.showsInactive
                            ? "These are the \(destination.category == .pets ? "pets" : "livestock/group") retired to a better life, with the date and total estimated cost."
                            : "Use \(destination.category?.addLabel ?? "Add") in the left pane."
                    )
                )
            } else if case .loaded = store.animalsState, animals.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("No \(destination.label.lowercased()) match that name or identifier.")
                )
            } else if case .loaded = store.animalsState {
                List(selection: $store.selectedAnimalID) {
                    if let selected = animals.first(where: { $0.id == store.selectedAnimalID }) {
                        Section("Name") {
                            RecordNameEditor(
                                label: "Name",
                                savedName: selected.displayName,
                                recordID: selected.id.uuidString,
                                canEdit: store.canEditStoredAnimal,
                                onSave: { await store.renameAnimal(animalID: selected.id, displayName: $0) }
                            )
                        }
                    }
                    ForEach(animals) { animal in
                        #if os(iOS)
                        NavigationLink {
                            AnimalDetailView(store: store, animalID: animal.id)
                                .onAppear { store.selectedAnimalID = animal.id }
                        } label: {
                            animalRowLabel(animal)
                        }
                        #else
                        Button {
                            store.selectedAnimalID = animal.id
                        } label: {
                            animalRowLabel(animal)
                        }
                        .buttonStyle(.plain)
                        .tag(animal.id as Animal.ID?)
                        #endif
                    }
                }
            } else {
                FixtureStateView(
                    title: "Animals",
                    systemImage: "pawprint",
                    state: store.animalsState,
                    ownershipNote: FixturePresentationBoundary.tenantDisclosure,
                    actionTitle: store.session.canReconnect && !store.isReconnecting ? "Reconnect" : nil,
                    action: store.session.canReconnect && !store.isReconnecting ? { Task { await store.reconnectToDev() } } : nil
                )
            }
        }
        .livestockScreenTitle(destination.label)
        .searchable(text: $query, prompt: "Name or identifier")
    }

    private func animalRowLabel(_ animal: Animal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(animal.displayName)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(rowDetail(animal))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        var line = "\(animal.species.label) · \(animal.productionType.label) · \(animal.identifierSummary)\(herdSuffix(animal))"
        if let mateID = animal.bredWithID, let mate = store.animals.first(where: { $0.id == mateID }) {
            line += " · Bred with \(mate.displayName)"
        }
        return line
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
    @State private var lifecycleWeight = ""
    @State private var correctingEventID: UUID?
    @State private var correctionAt = Date()
    @State private var correctionReason: LivestockLifecycleCorrectionReason?
    @State private var pendingCorrection: LifecycleCorrectionPrompt?
    @State private var correctionWeight = ""
    @State private var correctionCost = ""
    @State private var correctionTarget: LivestockCorrectionTarget?
    @State private var careType: LivestockCareEventType?
    @State private var careAt = Date()
    @State private var shotName = ""
    @State private var medicineName = ""
    @State private var medicineKind = ""
    @State private var careDosage = ""
    @State private var careFinanceReference = ""
    @State private var careCost = ""
    @State private var lifecycleCost = ""
    @State private var feedLines = [LivestockFeedEntry(inputType: .feed)]
    @State private var supplier = ""
    @State private var pickedSupplier = ""
    @State private var suppliers = LivestockSupplierDirectory()
    @State private var batch = ""
    @State private var feedAt = Date()
    @State private var products = LivestockProductDirectory()
    @State private var costAmount = ""
    @State private var financeReference = ""
    @State private var productionChoice: ProductionType = .breeding
    @State private var breedChoice: Breed?
    @State private var classificationMessage: String?
    @State private var sireChoice: UUID?
    @State private var damChoice: UUID?
    @State private var mateChoice: UUID?
    @State private var breedingMessage: String?

    private var pendingSave: LivestockAnimalSaveDraft {
        LivestockAnimalSaveDraft(
            identifierKind: kind,
            identifierValue: value,
            lifecycleType: lifecycleType,
            lifecycleAt: occurredAt,
            lifecycleWeight: lifecycleWeight,
            lifecycleCost: store.session.isLive ? lifecycleCost : "",
            careType: careType,
            careAt: careAt,
            careItemName: careType == .vaccination ? shotName : (careType == .medicationAdministration ? medicineName : ""),
            careItemKind: careType == .medicationAdministration ? medicineKind : "",
            careDosage: careType?.requiresDosage == true ? careDosage : "",
            careFinanceReference: careFinanceReference,
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

    private func feedChoices(for animal: Animal) -> [LivestockInputType] {
        LivestockInputType.entryChoices(for: animal.species, petKind: animal.petKind)
    }

    private func refreshSuppliers(fillEmpty: Bool) {
        suppliers = LivestockSupplierDirectory.load().merging(animals: store.animals, herds: store.herds)
        guard fillEmpty, supplier.isEmpty, !suppliers.last.isEmpty else { return }
        supplier = suppliers.last
        pickedSupplier = suppliers.last
    }

    private func refreshProducts() {
        products = LivestockProductDirectory.load().merging(animals: store.animals, herds: store.herds)
    }

    private func canCorrectRecords(_ animal: Animal) -> Bool {
        store.session.isLive && canCorrectLifecycle
    }

    private static func costTitle(_ title: String, cost: Decimal?) -> String {
        guard let cost else { return title }
        return "\(title) · \(LivestockMoney.usdSigned(cost))"
    }

    @ViewBuilder
    private static func typeCostRows(_ rows: [LivestockTypeCost]) -> some View {
        if !rows.isEmpty {
            Text("Cost by type").font(.subheadline.bold())
            ForEach(rows) { row in
                LabeledContent(row.label, value: LivestockMoney.usdSigned(row.amount))
            }
        }
    }

    private func alignFeedLines(for animal: Animal) {
        let choices = feedChoices(for: animal)
        guard let first = choices.first else { return }
        feedLines = feedLines.map { line in
            var copy = line
            if !choices.contains(copy.inputType) { copy.inputType = first }
            if !LivestockInputUnit.entryChoices.contains(copy.unit) { copy.unit = .scoop }
            return copy
        }
    }

    private var canEditIdentifiers: Bool { store.canEditStoredAnimal }

    private var canRecordLifecycle: Bool { store.canEditStoredAnimal }

    private var canCorrectLifecycle: Bool { store.fixtureWriteRole.canCorrectLifecycle && store.canEditStoredAnimal }

    var body: some View {
        if let animal {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        RecordNameEditor(
                            label: "Name",
                            savedName: animal.displayName,
                            recordID: animal.id.uuidString,
                            canEdit: canEditIdentifiers,
                            prominent: true,
                            onSave: { await store.renameAnimal(animalID: animal.id, displayName: $0) }
                        )
                        Text("\(animal.retirementDisplay) · \(animal.identifierSummary)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    if animal.species != .pet {
                        DetailSection(title: "Genetics", icon: "arrow.triangle.branch") {
                            if canEditIdentifiers {
                                breedingPickers(for: animal)
                                Button("Save breeding") {
                                    let animalID = animal.id
                                    let sire = sireChoice
                                    let dam = damChoice
                                    let mate = mateChoice
                                    Task {
                                        breedingMessage = await store.updateBreeding(
                                            animalID: animalID,
                                            sireID: sire,
                                            damID: dam,
                                            bredWithID: mate
                                        )
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!breedingChanged(animal) || breedingProblem(animal) != nil)
                                if let problem = breedingProblem(animal) {
                                    Text(problem).font(.callout).foregroundStyle(.orange)
                                }
                                if animal.productionType == .breeding, mateChoice == nil {
                                    Text("Choose who this animal is being bred with so the genetics stay straight.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let breedingMessage {
                                    Text(breedingMessage).font(.callout).foregroundStyle(.secondary)
                                }
                            } else {
                                LabeledContent("Sire", value: relativeName(animal.sireID))
                                LabeledContent("Dam", value: relativeName(animal.damID))
                                LabeledContent("Bred with", value: relativeName(animal.bredWithID))
                            }
                            Text("Sire and dam are the parents of this animal. Bred with is the current mate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Herd/group", icon: "rectangle.3.group") {
                        if let name = animal.herdName, !name.isEmpty {
                            LabeledContent("Herd/group", value: name)
                            if let started = animal.herdStartedAt {
                                LabeledContent("Since", value: started.formatted(date: .abbreviated, time: .shortened))
                            }
                        } else {
                            Text("No herd/group").foregroundStyle(.secondary)
                        }
                        Text("Change a herd/group from Herds/groups overview. The herd/group picker is on the same row as the animal.")
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
                                .appleIntelligenceDictation($value)
                            LivestockCostEntry(title: "Cost", amount: $identifierCost)
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
                            Text(FixturePresentationBoundary.retiredCorrectionBoundary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let saleAmount = animal.saleAmount, let saleOn = animal.saleOn {
                                LabeledContent("Sale amount", value: LivestockMoney.usd(saleAmount))
                                LabeledContent("Sale date", value: saleOn.formatted(date: .abbreviated, time: .omitted))
                                Button("Bill of sale") {
                                    LivestockBillOfSale.open(animal)
                                }
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
                                    LivestockCostEntry(title: "Sale amount", amount: $saleAmount)
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
                            ForEach(animal.lifecycleEvents.sorted { $0.occurredAt < $1.occurredAt }) { event in
                                LabeledContent(
                                    Self.costTitle(event.historyTitle, cost: animal.eventCost(event.id)),
                                    value: event.occurredAt.formatted(date: .abbreviated, time: .shortened)
                                )
                                if event.isCurrent, canCorrectLifecycle, animal.retirementReason == nil {
                                    Button("Correct") {
                                        correctingEventID = event.id
                                        correctionAt = event.occurredAt
                                        correctionReason = nil
                                        correctionWeight = event.weightPounds.map { "\($0)" } ?? ""
                                        correctionCost = ""
                                    }
                                }
                            }
                        }
                        if let correcting = animal.lifecycleEvents.first(where: { $0.id == correctingEventID }),
                           correcting.isCurrent,
                           canCorrectLifecycle,
                           animal.retirementReason == nil {
                            Text("Correct \(correcting.type.label). The earlier record stays.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            DatePicker("Corrected time", selection: $correctionAt)
                            if correcting.type == .weightRecorded, store.session.isLive {
                                TextField("Corrected weight in pounds", text: $correctionWeight)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                    .appleIntelligenceDictation($correctionWeight)
                                if let problem = LivestockWeight.requirement(correctionWeight), !correctionWeight.isEmpty {
                                    Text(problem).font(.callout).foregroundStyle(.orange)
                                }
                            }
                            Picker("Reason", selection: $correctionReason) {
                                Text("Choose a reason").tag(nil as LivestockLifecycleCorrectionReason?)
                                ForEach(LivestockLifecycleCorrectionReason.allCases) { item in
                                    Text(item.label).tag(Optional(item))
                                }
                            }
                            let savedCosts = animal.eventCosts(correcting.id)
                            if store.session.isLive, let reason = correctionReason {
                                if reason == .duplicateEntry {
                                    if !savedCosts.isEmpty {
                                        Text("The cost saved with this event comes out of the totals too.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if savedCosts.count > 1 {
                                    Text("Several costs are saved with this event. Correct the right one under Costs by date.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    if let saved = savedCosts.first {
                                        LabeledContent("Saved cost", value: LivestockMoney.usdSigned(LivestockMoney.signed(saved.amount)))
                                    }
                                    LivestockCostEntry(title: savedCosts.isEmpty ? "Cost" : "Corrected cost", amount: $correctionCost)
                                    Text(savedCosts.isEmpty
                                        ? "No cost was saved with this event. Enter one to add it with the correction, or leave it blank."
                                        : "Leave it blank to keep the saved cost. The earlier cost stays in the history.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let fix = correctionCostFix(savedCosts),
                                       let problem = fix.problem(reason: reason) {
                                        Text(problem).font(.callout).foregroundStyle(.orange)
                                    }
                                }
                            }
                            Button("Confirm correction") {
                                guard let reason = correctionReason else { return }
                                pendingCorrection = LifecycleCorrectionPrompt(
                                    animalID: animal.id,
                                    eventID: correcting.id,
                                    eventLabel: correcting.type.label,
                                    occurredAt: correctionAt,
                                    reason: reason,
                                    weightPounds: correcting.type == .weightRecorded ? correctionWeight : "",
                                    cost: store.session.isLive ? correctionCostFix(savedCosts) : nil
                                )
                            }
                            .disabled(
                                correctionReason == nil
                                    || (correcting.type == .weightRecorded && store.session.isLive
                                        && LivestockWeight.requirement(correctionWeight) != nil)
                                    || (store.session.isLive && correctionReason.flatMap { reason in
                                        correctionCostFix(savedCosts)?.problem(reason: reason)
                                    } != nil)
                            )
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
                            if lifecycleType == .weightRecorded {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    TextField("Weight in pounds", text: $lifecycleWeight)
                                        #if os(iOS)
                                        .keyboardType(.decimalPad)
                                        #endif
                                        .appleIntelligenceDictation($lifecycleWeight)
                                    TextField("Kilograms", text: .constant(LivestockWeight.kilogramsText(for: lifecycleWeight)))
                                        .disabled(true)
                                        .accessibilityLabel("Kilograms, read only")
                                }
                                Text("Enter pounds. Kilograms update from that weight and cannot be edited.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let problem = pendingSave.lifecycleProblem(), !lifecycleWeight.isEmpty {
                                    Text(problem)
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if lifecycleType != nil, store.session.isLive {
                                LivestockCostEntry(title: "Event cost", amount: $lifecycleCost)
                                Text("Optional. Saved with this event and added to Total estimated cost. Zero is allowed. A negative amount corrects an earlier entry.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !store.session.isLive {
                                Text(FixturePresentationBoundary.lifecycleBoundary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Self.typeCostRows(animal.lifecycleCostByType)
                    }
                    DetailSection(title: "Care", icon: "cross.case") {
                        if animal.careEvents.isEmpty {
                            Text("No care records").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.careEvents) { event in
                                LabeledContent(
                                    Self.costTitle(event.historyTitle, cost: event.isActive ? animal.eventCost(event.id) : nil),
                                    value: event.occurredAt.formatted(date: .abbreviated, time: .shortened)
                                )
                                if event.isActive, canCorrectRecords(animal) {
                                    Button("Correct") { correctionTarget = .care(event) }
                                }
                            }
                        }
                        Self.typeCostRows(animal.careCostByType)
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            Picker("Care", selection: $careType) {
                                Text("None").tag(nil as LivestockCareEventType?)
                                ForEach(LivestockCareEventType.allCases) { item in
                                    Text(item.label).tag(Optional(item))
                                }
                            }
                            if careType == .vaccination {
                                LivestockProductFields(
                                    category: .vaccination,
                                    fieldTitle: "Shot",
                                    name: $shotName,
                                    kind: $medicineKind,
                                    catalog: $products
                                )
                                Text("Leave this blank, or name the shot. Scanning adds it to the list; choose it if you want it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if careType == .medicationAdministration {
                                LivestockProductFields(
                                    category: .medication,
                                    fieldTitle: "Medicine",
                                    kindTitle: "Kind",
                                    name: $medicineName,
                                    kind: $medicineKind,
                                    catalog: $products
                                )
                                Text("Leave these blank, or enter the medicine and its kind. Scanning adds it to the list; choose it if you want it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let type = careType, type.requiresDosage {
                                LivestockDosageField(dosage: $careDosage, note: type.dosageRequirementNote)
                                if let problem = type.dosageProblem(careDosage) {
                                    Text(problem)
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if let type = careType {
                                DatePicker("Occurred", selection: $careAt)
                                LivestockAverageCostField(
                                    emptyHint: type.costRequirementNote,
                                    costs: animal.costs,
                                    reference: $careFinanceReference,
                                    amount: $careCost
                                )
                                if let problem = type.costProblem(careCost) {
                                    Text(problem)
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text(FixturePresentationBoundary.careRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Feed", icon: "leaf") {
                        if animal.consumptions.isEmpty {
                            Text("No feed consumption").foregroundStyle(.secondary)
                        } else {
                            ForEach(animal.consumptions) { item in
                                LabeledContent(
                                    Self.costTitle(item.historyTitle, cost: item.isActive ? animal.eventCost(item.id) : nil),
                                    value: item.observedAt.formatted(date: .abbreviated, time: .shortened)
                                )
                                if item.isActive, canCorrectRecords(animal) {
                                    Button("Correct") { correctionTarget = .feed(item) }
                                }
                            }
                        }
                        Self.typeCostRows(animal.feedCostByType)
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            ForEach($feedLines) { $line in
                                LivestockFeedLineFields(
                                    line: $line,
                                    costs: animal.costs,
                                    feedChoices: feedChoices(for: animal),
                                    catalog: $products,
                                    showsRemove: feedLines.count > 1,
                                    onRemove: { feedLines.removeAll { $0.id == line.id } }
                                )
                            }
                            DatePicker("Observed", selection: $feedAt)
                            Button("Add feed") {
                                feedLines.append(LivestockFeedEntry(inputType: feedChoices(for: animal).first ?? .preparedMeal, unit: .scoop))
                            }
                            LivestockSupplierFields(
                                supplier: $supplier,
                                pickedSupplier: $pickedSupplier,
                                suppliers: suppliers,
                                batch: $batch
                            )
                            Text("Choose the feed this animal eats, then the unit: one scoop, one cup, one bale, or one each. The estimated annual cost is the quantity times the cost of each feeding times how often you feed it in a year. Weekly is 52, daily is 365, monthly is 12, quarterly is 4, semi-annual is 2, and annual is 1.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(FixturePresentationBoundary.feedRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DetailSection(title: "Cost", icon: "dollarsign.circle") {
                        let operationalCosts = animal.activeCosts.filter { $0.frequency == nil && !$0.isEventCost }
                        if operationalCosts.isEmpty {
                            Text("No operational costs").foregroundStyle(.secondary)
                        } else {
                            ForEach(operationalCosts) { item in
                                Text(item.summary)
                            }
                        }
                        if canCorrectRecords(animal), !animal.activeCosts.isEmpty {
                            Text("To correct any saved cost, use Correct under Costs by date.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if store.session.isLive, canEditIdentifiers, !animal.isRetired {
                            LivestockCostEntry(title: "Amount in USD", amount: $costAmount)
                            TextField("Finance reference", text: $financeReference)
                                .appleIntelligenceDictation($financeReference)
                            Text("A negative amount corrects an earlier entry. Total estimated cost cannot go below zero.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(FixturePresentationBoundary.costRecordBoundary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if canEditIdentifiers, !animal.isRetired {
                        let summary = pendingSave.costSummary(recorded: animal.activeCosts)
                        ForEach(summary.feedSubtotals) { row in
                            LabeledContent(row.label, value: LivestockMoney.usdSigned(row.amount))
                        }
                        LabeledContent("Feed total", value: LivestockMoney.usdSigned(summary.feedTotal))
                            .font(.headline)
                        LabeledContent("Other", value: LivestockMoney.usdSigned(summary.other))
                        Text("Feed lines add the estimated annual cost into Feed total. Total estimated cost adds Feed total to identifier, lifecycle event, care, and operational costs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("Total estimated cost", value: LivestockMoney.usd(summary.total))
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
                                if result.savedLifecycle {
                                    lifecycleType = nil
                                    lifecycleWeight = ""
                                }
                                if result.acceptedLifecycleCost { lifecycleCost = "" }
                                if result.savedCare {
                                    careType = nil
                                    shotName = ""
                                    medicineName = ""
                                    medicineKind = ""
                                    careDosage = ""
                                }
                                if result.acceptedCareCost {
                                    careCost = ""
                                    careFinanceReference = ""
                                }
                                if result.savedFeed || result.acceptedFeedCost {
                                    let type = feedChoices(for: animal).first ?? .preparedMeal
                                    feedLines = [LivestockFeedEntry(inputType: type, unit: .scoop)]
                                    suppliers.remember(supplier)
                                    suppliers.save()
                                    supplier = suppliers.last
                                    pickedSupplier = suppliers.last
                                    batch = ""
                                }
                                if result.savedCost {
                                    costAmount = ""
                                    financeReference = ""
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pendingSave.isEmpty || pendingSave.lifecycleProblem() != nil || pendingSave.costProblem() != nil)
                        Text(FixturePresentationBoundary.saveConfirmsBoundary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DetailSection(title: "Costs by date", icon: "calendar") {
                        let days = LivestockCostLedger.days(from: animal.activeCosts, label: animal.costLabel)
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
                                    if canCorrectRecords(animal), let cost = animal.costs.first(where: { $0.id == line.id }) {
                                        Button("Correct") { correctionTarget = .cost(cost, label: line.label) }
                                    }
                                }
                            }
                        }
                        let removed = animal.costs.filter(animal.isRemovedWithEvent)
                        if !removed.isEmpty {
                            Text("Removed with a duplicate event · not counted")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(removed) { cost in
                                LabeledContent(
                                    "\(animal.costLabel(cost)) · \(cost.recordedAt.formatted(date: .abbreviated, time: .shortened))",
                                    value: LivestockMoney.usdSigned(LivestockMoney.signed(cost.amount))
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(FixturePresentationBoundary.deferredSliceDisclosure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onAppear {
                    alignFeedLines(for: animal)
                    refreshSuppliers(fillEmpty: true)
                    refreshProducts()
                }
                .onChange(of: store.animals.map(\.consumptions.count)) { _, _ in
                    refreshSuppliers(fillEmpty: supplier.isEmpty)
                    refreshProducts()
                }
                #if os(iOS)
                .labeledContentStyle(LivestockWrappingContentStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                #else
                .padding(24)
                #endif
            }
            .onAppear { alignIdentifierChoices(for: animal) }
            .onChange(of: animal.id) { _, _ in alignIdentifierChoices(for: animal) }
            .onChange(of: animal.productionType) { _, _ in alignClassification(for: animal) }
            .onChange(of: animal.breed) { _, _ in alignClassification(for: animal) }
            .onChange(of: animal.sireID) { _, _ in alignClassification(for: animal) }
            .onChange(of: animal.damID) { _, _ in alignClassification(for: animal) }
            .onChange(of: animal.bredWithID) { _, _ in alignClassification(for: animal) }
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
            .sheet(item: $correctionTarget) { target in
                LivestockRecordCorrectionSheet(store: store, animalID: animalID, target: target)
            }
            .alert(
                "Correct this \(pendingCorrection?.eventLabel ?? "event")?",
                isPresented: Binding(
                    get: { pendingCorrection != nil },
                    set: { if !$0 { pendingCorrection = nil } }
                )
            ) {
                Button("Proceed") {
                    guard let pending = pendingCorrection else { return }
                    pendingCorrection = nil
                    let animalID = pending.animalID
                    let eventID = pending.eventID
                    let occurredAt = pending.occurredAt
                    let reason = pending.reason
                    let weight = pending.weightPounds
                    let cost = pending.cost
                    Task {
                        let result = await store.correctLifecycleEvent(
                            animalID: animalID,
                            eventID: eventID,
                            occurredAt: occurredAt,
                            reason: reason,
                            confirmed: true,
                            weightPounds: weight,
                            cost: cost
                        )
                        if case .rejected(let text) = result {
                            message = text
                        } else {
                            correctingEventID = nil
                            correctionReason = nil
                            correctionCost = ""
                            message = store.session.isLive
                                ? FixturePresentationBoundary.databaseWriteBoundary
                                : "Corrected. The earlier record stays."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The earlier record stays. This correction becomes the current \(pendingCorrection?.eventLabel ?? "event").")
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
        sireChoice = animal.sireID
        damChoice = animal.damID
        mateChoice = animal.bredWithID
    }

    private func classificationChanged(_ animal: Animal) -> Bool {
        productionChoice != animal.productionType || breedChoice?.code != animal.breed?.code
    }

    private func breedingChanged(_ animal: Animal) -> Bool {
        sireChoice != animal.sireID || damChoice != animal.damID || mateChoice != animal.bredWithID
    }

    private func breedingProblem(_ animal: Animal) -> String? {
        LivestockBreeding.problem(
            animal: animal,
            sireID: sireChoice,
            damID: damChoice,
            bredWithID: mateChoice,
            among: store.animals
        )
    }

    private func relativeName(_ id: UUID?) -> String {
        guard let id else { return "None" }
        return store.animals.first { $0.id == id }?.displayName ?? "Unknown"
    }

    @ViewBuilder
    private func breedingPickers(for animal: Animal) -> some View {
        let relatives = LivestockBreeding.relatives(for: animal.species, excluding: animal.id, among: store.animals)
        Picker("Sire", selection: $sireChoice) {
            Text("No sire").tag(nil as UUID?)
            ForEach(relatives) { relative in
                Text(relative.displayName).tag(Optional(relative.id))
            }
        }
        Picker("Dam", selection: $damChoice) {
            Text("No dam").tag(nil as UUID?)
            ForEach(relatives) { relative in
                Text(relative.displayName).tag(Optional(relative.id))
            }
        }
        Picker("Bred with", selection: $mateChoice) {
            Text("Not yet chosen").tag(nil as UUID?)
            ForEach(relatives) { relative in
                Text(relative.displayName).tag(Optional(relative.id))
            }
        }
    }

    /// The inline lifecycle correction corrects a single saved cost or adds the first one.
    func correctionCostFix(_ saved: [LivestockCostAttribution]) -> LivestockCostFix? {
        guard correctionReason != .duplicateEntry, saved.count <= 1 else { return nil }
        return LivestockCostFix.entered(costID: saved.first?.id, amount: correctionCost)
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

private struct LifecycleCorrectionPrompt: Identifiable {
    let animalID: Animal.ID
    let eventID: UUID
    let eventLabel: String
    let occurredAt: Date
    let reason: LivestockLifecycleCorrectionReason
    var weightPounds: String = ""
    var cost: LivestockCostFix? = nil

    var id: UUID { eventID }
}

private struct LivestockDosageField: View {
    @Binding var dosage: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dosage")
                .foregroundStyle(.secondary)
            TextField("Dosage", text: $dosage, prompt: Text("5 mL, 2 cc, 1 bolus"))
                .appleIntelligenceDictation($dosage)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum LivestockCorrectionTarget: Identifiable, Equatable {
    case care(LivestockCareEvent)
    case feed(LivestockConsumption)
    case cost(LivestockCostAttribution, label: String)

    var id: UUID {
        switch self {
        case .care(let event): event.id
        case .feed(let item): item.id
        case .cost(let cost, _): cost.id
        }
    }

    var title: String {
        switch self {
        case .care(let event): "Correct \(event.summary)"
        case .feed(let item): "Correct \(item.summary)"
        case .cost(let cost, let label): "Correct \(label) · \(LivestockMoney.usdSigned(LivestockMoney.signed(cost.amount)))"
        }
    }

    var reasons: [LivestockLifecycleCorrectionReason] {
        switch self {
        case .care, .feed: LivestockLifecycleCorrectionReason.allCases
        case .cost: LivestockLifecycleCorrectionReason.costChoices
        }
    }
}

private struct LivestockRecordCorrectionSheet: View {
    let store: LivestockStore
    var animalID: Animal.ID? = nil
    var herdID: UUID? = nil
    let target: LivestockCorrectionTarget
    @Environment(\.dismiss) private var dismiss
    @State private var reason: LivestockLifecycleCorrectionReason?
    @State private var when = Date()
    @State private var itemName = ""
    @State private var itemKind = ""
    @State private var dosage = ""
    @State private var quantity = ""
    @State private var unit: LivestockInputUnit = .scoop
    @State private var frequency: LivestockCostFrequency = .daily
    @State private var supplier = ""
    @State private var batch = ""
    @State private var amount = ""
    @State private var costAmount = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var products = LivestockProductDirectory()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        Text("Choose a reason").tag(nil as LivestockLifecycleCorrectionReason?)
                        ForEach(target.reasons) { item in
                            Text(item.label).tag(Optional(item))
                        }
                    }
                }
                if reason == .duplicateEntry {
                    Section {
                        Text(duplicateExplanation)
                            .foregroundStyle(.secondary)
                    }
                } else if reason != nil {
                    fields
                    costFields
                }
                Section {
                    Text("The earlier record stays. This correction becomes the current record. Only the owner can correct.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let issue = dosageIssue ?? problem {
                        Text(issue).font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(target.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save correction") { save() }
                        .disabled(saving || correction == nil || correction?.problem != nil || dosageIssue != nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .onAppear {
            products = LivestockProductDirectory.load().merging(animals: store.animals, herds: store.herds)
            prefill()
        }
    }

    @ViewBuilder private var fields: some View {
        switch target {
        case .care(let event):
            Section("Care") {
                DatePicker("Occurred", selection: $when)
                if event.type == .vaccination {
                    LivestockProductFields(
                        category: .vaccination,
                        fieldTitle: "Shot",
                        name: $itemName,
                        kind: $itemKind,
                        catalog: $products
                    )
                }
                if event.type == .medicationAdministration {
                    LivestockProductFields(
                        category: .medication,
                        fieldTitle: "Medicine",
                        kindTitle: "Kind",
                        name: $itemName,
                        kind: $itemKind,
                        catalog: $products
                    )
                }
                if event.type.requiresDosage {
                    LivestockDosageField(dosage: $dosage, note: event.type.dosageRequirementNote)
                }
                Text("The care type stays \(event.type.label). To change the type, record the right care and mark this one a duplicate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .feed(let item):
            Section(item.inputType.label) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quantity")
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("1", text: $quantity, prompt: Text("1"))
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: quantity) { _, newValue in
                                let limited = String(newValue.filter(\.isNumber).prefix(2))
                                if limited != newValue { quantity = limited }
                            }
                        Spacer(minLength: 0)
                    }
                }
                Picker("Unit", selection: $unit) {
                    ForEach(unitChoices(item)) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("Frequency", selection: $frequency) {
                    ForEach(LivestockCostFrequency.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                DatePicker("Observed", selection: $when)
                TextField("Supplier", text: $supplier)
                    .appleIntelligenceDictation($supplier)
                TextField("Batch", text: $batch)
                    .appleIntelligenceDictation($batch)
                Text("The feed stays \(item.inputType.label). To change the feed, record the right one and mark this one a duplicate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .cost:
            Section("Cost") {
                LivestockCostEntry(title: "Corrected amount", amount: $amount)
                Text("Enter the right amount. A negative amount is allowed for a correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dosageIssue: String? {
        guard reason != .duplicateEntry, case .care(let event) = target else { return nil }
        return event.type.dosageProblem(dosage)
    }

    private var duplicateExplanation: String {
        let base = "This record comes off the lists and out of the totals. The earlier record stays in the history."
        guard !(linkedCosts ?? []).isEmpty else { return base }
        return base + " The cost saved with it comes out of the totals too."
    }

    /// Counted costs that travel with this care or feed record; nil for a cost correction.
    private var linkedCosts: [LivestockCostAttribution]? {
        if let herdID, let herd = store.herds.first(where: { $0.id == herdID }) {
            switch target {
            case .care(let event): return herd.eventCosts(event.id)
            case .feed(let item): return herd.eventCosts(item.id)
            case .cost: return nil
            }
        }
        guard let animalID, let animal = store.animals.first(where: { $0.id == animalID }) else { return [] }
        switch target {
        case .care(let event): return animal.eventCosts(event.id)
        case .feed(let item): return animal.eventCosts(item.id)
        case .cost: return nil
        }
    }

    @ViewBuilder private var costFields: some View {
        if let linked = linkedCosts {
            Section("Cost") {
                if linked.count > 1 {
                    Text("Several costs are saved with this record. Correct the right one under Costs by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let saved = linked.first {
                    LabeledContent("Saved cost", value: LivestockMoney.usdSigned(LivestockMoney.signed(saved.amount)))
                    LivestockCostEntry(title: "Corrected cost", amount: $costAmount)
                    Text("Leave it blank to keep the saved cost. The earlier cost stays in the history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LivestockCostEntry(title: "Cost", amount: $costAmount)
                    Text(noSavedCostNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var noSavedCostNote: String {
        if case .feed = target {
            return "No cost was saved with this feed record. Feed needs a quantity and a cost, so enter the cost to save the correction."
        }
        return "No cost was saved with this care. Enter one to add it with the correction, or leave it blank."
    }

    private var costFix: LivestockCostFix? {
        guard reason != .duplicateEntry, let linked = linkedCosts, linked.count <= 1 else { return nil }
        // A feed record without a saved cost must get one with the correction.
        if linked.isEmpty, case .feed = target {
            return LivestockCostFix(costID: nil, amount: costAmount)
        }
        return LivestockCostFix.entered(costID: linked.first?.id, amount: costAmount)
    }

    private var correction: LivestockRecordCorrection? {
        guard let reason else { return nil }
        switch target {
        case .care(let event):
            return .care(
                eventID: event.id,
                occurredAt: when,
                reason: reason,
                itemName: event.type == .observation || event.type == .treatment || event.type == .surgery ? "" : itemName,
                itemKind: event.type == .medicationAdministration ? itemKind : "",
                dosage: event.type.requiresDosage ? dosage : "",
                cost: costFix
            )
        case .feed(let item):
            return .feed(
                consumptionID: item.id,
                quantity: reason == .duplicateEntry ? Self.wholeQuantity(item.quantity) : quantity,
                unit: unit,
                frequency: frequency,
                observedAt: when,
                supplier: supplier,
                batch: batch,
                reason: reason,
                cost: costFix
            )
        case .cost(let cost, _):
            return .cost(costID: cost.id, amount: reason == .duplicateEntry ? cost.amount : amount, reason: reason)
        }
    }

    private func unitChoices(_ item: LivestockConsumption) -> [LivestockInputUnit] {
        let choices = LivestockInputUnit.entryChoices
        return choices.contains(item.unit) ? choices : choices + [item.unit]
    }

    private func prefill() {
        switch target {
        case .care(let event):
            when = event.occurredAt
            itemName = event.itemName ?? ""
            itemKind = event.itemKind ?? ""
            dosage = event.dosage ?? ""
        case .feed(let item):
            when = item.observedAt
            quantity = Self.wholeQuantity(item.quantity)
            unit = item.unit
            frequency = item.frequency ?? .daily
            supplier = item.supplier ?? ""
            batch = item.batch ?? ""
        case .cost(let cost, _):
            amount = LivestockMoney.entry(cost.amount)
        }
    }

    /// Saved quantities can carry decimals from older entries; the form takes whole numbers up to 99.
    private static func wholeQuantity(_ text: String) -> String {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return "" }
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 0, .plain)
        let whole = NSDecimalNumber(decimal: rounded).intValue
        return whole > 0 ? String(min(whole, 99)) : ""
    }

    private func save() {
        guard let correction else { return }
        saving = true
        Task {
            let failure = await store.correctRecord(animalID: animalID, herdID: herdID, correction)
            saving = false
            if let failure {
                problem = failure
            } else {
                dismiss()
            }
        }
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
            if case .loading = state { ProgressView("Connecting to the DEV database…") }
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
    @State private var isSaving = false

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
        #if os(iOS)
        NavigationStack {
            Form {
                Section {
                    Text(store.session.isLive ? FixturePresentationBoundary.databaseWriteBoundary : FixturePresentationBoundary.addAnimalBoundary)
                        .foregroundStyle(.secondary)
                }
                animalFields
                if let confirmation {
                    Section {
                        Label(confirmation, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    addAnimalButton
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle(category.addLabel)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(category.addLabel).font(.title2.bold())
            Text(store.session.isLive ? FixturePresentationBoundary.databaseWriteBoundary : FixturePresentationBoundary.addAnimalBoundary)
                .foregroundStyle(.secondary)
            Form {
                animalFields
            }
            .formStyle(.grouped)
            if let confirmation {
                Label(confirmation, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                addAnimalButton
            }
        }
        .padding(24)
        .frame(width: 520)
        #endif
    }

    @ViewBuilder
    private var animalFields: some View {
        TextField("Display name", text: $draft.displayName)
            .appleIntelligenceDictation($draft.displayName)
        if category == .pets {
            Picker("Species", selection: Binding(get: { draft.petKind }, set: { draft.selectPetKind($0) })) {
                Text("Select species").tag(PetKind?.none)
                ForEach(PetKind.allCases) { Text($0.label).tag(PetKind?.some($0)) }
            }
            if draft.petKind == .other {
                TextField("Species", text: $draft.petSpeciesOther)
                    .appleIntelligenceDictation($draft.petSpeciesOther)
            }
            if draft.petKind != nil {
                Picker("Breed", selection: $draft.petBreedChoice) {
                    Text("No breed selected").tag("")
                    ForEach(LivestockCatalog.petBreedMenu(for: draft.petKind)) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                if draft.petBreedChoice == "typed" {
                    TextField("Breed", text: $draft.typedBreed)
                        .appleIntelligenceDictation($draft.typedBreed)
                }
                if draft.petBreedChoice == "mixed" {
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

    private var addAnimalButton: some View {
        Button(category.addLabel) {
            guard !isSaving else { return }
            isSaving = true
            let entered = draft
            Task {
                switch await store.createAnimal(entered) {
                case .created:
                    onCreated()
                    dismiss()
                case .rejected(let message):
                    confirmation = message
                    isSaving = false
                }
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit || isSaving)
    }

    private func petMixField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: text)
                .appleIntelligenceDictation(text)
            Menu("Choose a listed breed") {
                ForEach(LivestockCatalog.petBreeds(for: draft.petKind), id: \.self) { breed in
                    Button(breed) { text.wrappedValue = breed }
                }
            }
        }
    }
}
