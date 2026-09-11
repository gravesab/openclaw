import SwiftUI

enum LivestockDestination: String, CaseIterable, Identifiable {
    case overview, animals, care, feed, costs
    var id: String { rawValue }
    var label: String { switch self { case .overview: "Herd overview"; case .animals: "Animals"; case .care: "Care"; case .feed: "Feed and supplies"; case .costs: "Costs" } }
    var icon: String { switch self { case .overview: "rectangle.3.group"; case .animals: "pawprint"; case .care: "cross.case"; case .feed: "leaf"; case .costs: "dollarsign.circle" } }
}

struct LivestockRootView: View {
    @Bindable var store: LivestockStore
    @State private var destination: LivestockDestination? = .overview
    @State private var presentingAddAnimal = false
    @State private var appearance: AppearanceChoice = .system
    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Livestock Management") { ForEach(LivestockDestination.allCases) { item in Label(item.label, systemImage: item.icon).tag(item) } }
                Section("Context") { FixtureContextView(context: store.fixtureContext) }
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
            .navigationTitle("Ranch OS")
            .safeAreaInset(edge: .bottom) { Text(FixturePresentationBoundary.tenantDisclosure).font(.caption).foregroundStyle(.secondary).padding(12) }
        } content: { destinationContent } detail: { detailContent }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add animal", systemImage: "plus") { presentingAddAnimal = true }.accessibilityHint("Opens an in-memory DEV fixture form") }
        }
        .sheet(isPresented: $presentingAddAnimal) { AddAnimalSheet() }
        .preferredColorScheme(appearance.colorScheme)
    }
    @ViewBuilder private var destinationContent: some View {
        switch destination ?? .overview {
        case .overview: HerdOverviewView(store: store)
        case .animals: AnimalListView(store: store)
        case .care: CareFixtureView(store: store)
        case .feed: FeedAndSuppliesFixtureView(store: store)
        case .costs: CostsFixtureView(store: store)
        }
    }
    @ViewBuilder private var detailContent: some View {
        if destination == .animals, let animal = store.animals.first(where: { $0.id == store.selectedAnimalID }) { AnimalDetailView(animal: animal) }
        else { ContentUnavailableView("Select an animal", systemImage: "pawprint", description: Text("Animal details are fixture read-model presentation only.")) }
    }
}

struct FixtureContextView: View {
    let context: FixturePresentationContext
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(context.environment, systemImage: "testtube.2").font(.subheadline.weight(.semibold))
            Text(context.displayName).font(.caption)
            Text(context.statusLabel).font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine).accessibilityLabel("Fixture tenant context: \(context.displayName). \(context.statusLabel)")
    }
}

struct HerdOverviewView: View {
    let store: LivestockStore
    var body: some View {
        Group {
            if case .loaded = store.overviewState, let overview = store.overview {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text("Herd overview").font(.largeTitle.bold())
                    Text("Fixture operational indicators only. Herd assignment and history are not enabled.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        OverviewCard(title: "Animals", value: "\(overview.activeAnimals)", detail: "active fixture records", icon: "pawprint")
                        OverviewCard(title: "Care due", value: "\(overview.careDue)", detail: "read-model placeholder", icon: "cross.case")
                        OverviewCard(title: "Feeding needs", value: "\(overview.feedingNeeds)", detail: "fixture indicator", icon: "leaf")
                        OverviewCard(title: "Operational costs", value: overview.operationalCostLabel, detail: "not a ledger balance", icon: "dollarsign.circle")
                    }
                    Label(FixturePresentationBoundary.tenantDisclosure, systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                }.padding(24) }
            } else { FixtureStateView(title: "Herd overview", systemImage: "rectangle.3.group", state: store.overviewState, ownershipNote: FixturePresentationBoundary.tenantDisclosure) }
        }.navigationTitle("Herd overview")
    }
}

struct OverviewCard: View {
    let title: String; let value: String; let detail: String; let icon: String
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: icon).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit(); Text(detail).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .combine) }
}

struct AnimalListView: View {
    @Bindable var store: LivestockStore
    var body: some View {
        Group {
            if case .loaded = store.animalsState { List(store.animals, selection: $store.selectedAnimalID) { animal in VStack(alignment: .leading, spacing: 4) { Text(animal.displayName).font(.headline); Text("\(animal.species.label) · \(animal.productionType.label) · \(animal.identifier)").font(.subheadline).foregroundStyle(.secondary) }.tag(animal.id) } }
            else { FixtureStateView(title: "Animals", systemImage: "pawprint", state: store.animalsState, ownershipNote: FixturePresentationBoundary.tenantDisclosure) }
        }.navigationTitle("Animals")
    }
}

struct AnimalDisplayNamePicker: View {
    @Bindable var store: LivestockStore

    var body: some View {
        Picker("Animal display name", selection: $store.selectedAnimalID) {
            Text("Select animal").tag(Animal.ID?.none)
            ForEach(store.animals) { animal in
                Text(animal.displayName).tag(Animal.ID?.some(animal.id))
            }
        }
        .accessibilityLabel("Animal display name")
    }
}

struct CareFixtureView: View {
    @Bindable var store: LivestockStore
    @State private var careType = "Routine checkup"
    @State private var careDate = Date()
    @State private var careNote = ""

    private var selectedAnimal: Animal? {
        store.animals.first { $0.id == store.selectedAnimalID }
    }

    var body: some View {
        Group {
            if case .loaded = store.animalsState, let animal = selectedAnimal {
                Form {
                    Section("Animal") {
                        AnimalDisplayNamePicker(store: store)
                        LabeledContent("Next care", value: animal.care.nextCheckLabel)
                        LabeledContent("Care summary", value: animal.care.summary)
                    }
                    Section("Care questions") {
                        Picker("Care type", selection: $careType) {
                            Text("Routine checkup").tag("Routine checkup")
                            Text("Vaccination").tag("Vaccination")
                            Text("Treatment").tag("Treatment")
                            Text("Weight check").tag("Weight check")
                        }
                        DatePicker("Care date", selection: $careDate, displayedComponents: .date)
                        TextField("Care note", text: $careNote)
                    }
                    Section {
                        Text("Care questions are session-only DEV fixture presentation. No animal care record is saved.")
                            .foregroundStyle(.secondary)
                        Text(FixturePresentationBoundary.careOwnership)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .onAppear { careNote = animal.care.summary }
                .onChange(of: store.selectedAnimalID) { _, _ in
                    careNote = selectedAnimal?.care.summary ?? ""
                }
            } else {
                FixtureStateView(title: "Care", systemImage: "cross.case", state: store.animalsState, ownershipNote: FixturePresentationBoundary.careOwnership)
            }
        }
        .navigationTitle("Care")
    }
}

struct FeedAndSuppliesFixtureView: View {
    @Bindable var store: LivestockStore

    private var selectedAnimal: Animal? {
        store.animals.first { $0.id == store.selectedAnimalID }
    }

    var body: some View {
        Group {
            if case .loaded = store.animalsState, let animal = selectedAnimal {
                Form {
                    Section("Animal") { AnimalDisplayNamePicker(store: store) }
                    Section("Prefilled feeding") {
                        LabeledContent("Ration", value: animal.feed.rationLabel)
                        LabeledContent("Daily amount", value: animal.feed.dailyAmountLabel)
                    }
                    Section {
                        Text("Feed, hay, and supplements are local fixture presentation only; no inventory transaction is available.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                FixtureStateView(title: "Feed and supplies", systemImage: "leaf", state: store.animalsState, ownershipNote: FixturePresentationBoundary.tenantDisclosure)
            }
        }
        .navigationTitle("Feed and supplies")
    }
}

struct CostsFixtureView: View {
    @Bindable var store: LivestockStore

    private var selectedAnimal: Animal? {
        store.animals.first { $0.id == store.selectedAnimalID }
    }

    var body: some View {
        Group {
            if case .loaded = store.animalsState, let animal = selectedAnimal {
                Form {
                    Section("Animal") { AnimalDisplayNamePicker(store: store) }
                    Section("Prefilled operational cost attribution") {
                        LabeledContent("Attribution", value: animal.operationalCostAttribution.categoryLabel)
                        LabeledContent("Amount", value: animal.operationalCostAttribution.amountLabel)
                    }
                    Section {
                        Text(FixturePresentationBoundary.financeOwnership)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                FixtureStateView(title: "Costs", systemImage: "dollarsign.circle", state: store.animalsState, ownershipNote: FixturePresentationBoundary.financeOwnership)
            }
        }
        .navigationTitle("Costs")
    }
}

struct AnimalDetailView: View {
    let animal: Animal
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) { Text(animal.displayName).font(.largeTitle.bold()); Text("\(animal.status) · fixture read-model record").foregroundStyle(.secondary) }
        DetailSection(title: "Identifiers", icon: "number") { LabeledContent("Primary tag", value: animal.identifier) }
        DetailSection(title: "Routine lifecycle history", icon: "clock.arrow.circlepath") { Text("No routine lifecycle history is connected in this fixture.").foregroundStyle(.secondary) }
        DetailSection(title: "Veterinary care", icon: "cross.case") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Next care", value: animal.care.nextCheckLabel)
                LabeledContent("Care summary", value: animal.care.summary)
                Text(FixturePresentationBoundary.careOwnership).foregroundStyle(.secondary)
            }
        }
        DetailSection(title: "Surgeries and treatments", icon: "stethoscope") { Text("Authorized care history will supply this section; fixture state is empty.").foregroundStyle(.secondary) }
        DetailSection(title: "Supplements", icon: "pills") { Text("No fixture supplement consumption is connected.").foregroundStyle(.secondary) }
        DetailSection(title: "Feed and hay consumption", icon: "leaf") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Ration", value: animal.feed.rationLabel)
                LabeledContent("Daily amount", value: animal.feed.dailyAmountLabel)
            }
        }
        DetailSection(title: "Operational cost attribution", icon: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Attribution", value: animal.operationalCostAttribution.categoryLabel)
                LabeledContent("Amount", value: animal.operationalCostAttribution.amountLabel)
                Text(FixturePresentationBoundary.financeOwnership).foregroundStyle(.secondary)
            }
        }
    }.padding(24) } }
}

struct DetailSection<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View { GroupBox { content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) } label: { Label(title, systemImage: icon).font(.headline) } }
}

struct FixtureStateView: View {
    let title: String; let systemImage: String; let state: FixtureLoadState; let ownershipNote: String
    var body: some View { VStack(spacing: 14) { Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary); Text(title).font(.title2.bold()); if case .loading = state { ProgressView("Loading fixture state") }; if let message = state.message { Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary) }; Text(ownershipNote).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32).accessibilityElement(children: .combine) }
}

struct AddAnimalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AddAnimalDraft()
    @State private var confirmation: String?
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Add animal").font(.title2.bold()); Text(FixturePresentationBoundary.addAnimalBoundary).foregroundStyle(.secondary)
        Form {
            TextField("Display name", text: $draft.displayName)
            Picker("Species", selection: Binding(get: { draft.species }, set: { draft.selectSpecies($0) })) { Text("Select species").tag(Species?.none); ForEach(Species.pickerChoices) { Text($0.label).tag(Species?.some($0)) } }
            if draft.species == .other {
                TextField("Describe other livestock type", text: $draft.otherSpeciesDescription)
                    .accessibilityLabel("Describe other livestock type")
                Text(FixturePresentationBoundary.otherSpeciesBoundary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if draft.species == .rabbit {
                Text(FixturePresentationBoundary.rabbitSpeciesBoundary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(FixturePresentationBoundary.rabbitSpeciesBoundary)
            }
            Picker("Production type", selection: Binding(get: { draft.productionType }, set: { draft.selectProductionType($0) })) { Text("Select production type").tag(ProductionType?.none); ForEach(LivestockCatalog.productionTypes(for: draft.species)) { Text($0.label).tag(ProductionType?.some($0)) } }.disabled(draft.species == nil)
            Picker("Breed", selection: Binding(get: { draft.breed }, set: { draft.selectBreed($0) })) { Text("No breed selected").tag(Breed?.none); ForEach(LivestockCatalog.breeds(for: draft.species)) { Text($0.label).tag(Breed?.some($0)) } }.disabled(draft.species == nil)
        }.formStyle(.grouped)
        if let confirmation { Label(confirmation, systemImage: "info.circle").foregroundStyle(.secondary) }
        HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Show fixture outcome") { confirmation = draft.submitFixturePresentation() }.keyboardShortcut(.defaultAction).disabled(!draft.isValidCatalogSelection) }
    }.padding(24).frame(width: 520) }
}
