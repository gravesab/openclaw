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
    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Livestock Management") { ForEach(LivestockDestination.allCases) { item in Label(item.label, systemImage: item.icon).tag(item) } }
                Section("Context") { FixtureContextView(context: store.fixtureContext) }
            }
            .navigationTitle("Ranch OS")
            .safeAreaInset(edge: .bottom) { Text(FixturePresentationBoundary.tenantDisclosure).font(.caption).foregroundStyle(.secondary).padding(12) }
        } content: { destinationContent } detail: { detailContent }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add animal", systemImage: "plus") { presentingAddAnimal = true }.accessibilityHint("Opens an in-memory DEV fixture form") } }
        .sheet(isPresented: $presentingAddAnimal) { AddAnimalSheet() }
    }
    @ViewBuilder private var destinationContent: some View {
        switch destination ?? .overview {
        case .overview: HerdOverviewView(store: store)
        case .animals: AnimalListView(store: store)
        case .care: FixtureStateView(title: "Care", systemImage: "cross.case", state: .empty(message: "Care records will arrive through an authorized Livestock read model."), ownershipNote: FixturePresentationBoundary.careOwnership)
        case .feed: FixtureStateView(title: "Feed and supplies", systemImage: "leaf", state: .loading, ownershipNote: "Feed, hay, and supplements are read-only fixture placeholders; no inventory transaction is available.")
        case .costs: FixtureStateView(title: "Costs", systemImage: "dollarsign.circle", state: .error(message: "Fixture cost attribution is unavailable until an authorized read model supplies it."), ownershipNote: FixturePresentationBoundary.financeOwnership)
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

struct AnimalDetailView: View {
    let animal: Animal
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) { Text(animal.displayName).font(.largeTitle.bold()); Text("\(animal.status) · fixture read-model record").foregroundStyle(.secondary) }
        DetailSection(title: "Identifiers", icon: "number") { LabeledContent("Primary tag", value: animal.identifier) }
        DetailSection(title: "Routine lifecycle history", icon: "clock.arrow.circlepath") { Text("No routine lifecycle history is connected in this fixture.").foregroundStyle(.secondary) }
        DetailSection(title: "Veterinary care", icon: "cross.case") { Text(FixturePresentationBoundary.careOwnership).foregroundStyle(.secondary) }
        DetailSection(title: "Surgeries and treatments", icon: "stethoscope") { Text("Authorized care history will supply this section; fixture state is empty.").foregroundStyle(.secondary) }
        DetailSection(title: "Supplements", icon: "pills") { Text("No fixture supplement consumption is connected.").foregroundStyle(.secondary) }
        DetailSection(title: "Feed and hay consumption", icon: "leaf") { Text("No fixture feed or hay consumption is connected.").foregroundStyle(.secondary) }
        DetailSection(title: "Operational cost attribution", icon: "dollarsign.circle") { Text(FixturePresentationBoundary.financeOwnership).foregroundStyle(.secondary) }
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
            Picker("Species", selection: Binding(get: { draft.species }, set: { draft.selectSpecies($0) })) { Text("Select species").tag(Species?.none); ForEach(Species.allCases) { Text($0.label).tag(Species?.some($0)) } }
            Picker("Production type", selection: Binding(get: { draft.productionType }, set: { draft.selectProductionType($0) })) { Text("Select production type").tag(ProductionType?.none); ForEach(LivestockCatalog.productionTypes(for: draft.species)) { Text($0.label).tag(ProductionType?.some($0)) } }.disabled(draft.species == nil)
            Picker("Breed", selection: Binding(get: { draft.breed }, set: { draft.selectBreed($0) })) { Text("No breed selected").tag(Breed?.none); ForEach(LivestockCatalog.breeds(for: draft.species)) { Text($0.label).tag(Breed?.some($0)) } }.disabled(draft.species == nil)
        }.formStyle(.grouped)
        if let confirmation { Label(confirmation, systemImage: "info.circle").foregroundStyle(.secondary) }
        HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Show fixture outcome") { confirmation = draft.submitFixturePresentation() }.keyboardShortcut(.defaultAction).disabled(!draft.isValidCatalogSelection) }
    }.padding(24).frame(width: 520) }
}
