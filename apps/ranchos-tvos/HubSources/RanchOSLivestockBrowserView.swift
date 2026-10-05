#if !os(tvOS)
import SwiftUI

enum RanchOSLivestockBrowserColumnStyle: Equatable {
    /// List and detail share the Hub detail column. The Hub keeps the only sidebar.
    case embedded
    /// Animal detail is the next destination on the Hub's existing compact stack.
    case stacked
}

struct RanchOSLivestockBrowserView: View {
    var style: RanchOSLivestockBrowserColumnStyle
    var onRevealSidebar: () -> Void = {}
    var onReturnHome: () -> Void
    var onCloseBrowser: () -> Void = {}
    var onOpenAnimal: ((String) -> Void)? = nil
    var onAnimalCleared: (() -> Void)? = nil

    @State private var model = RanchOSLivestockBrowserModel()

    var body: some View {
        @Bindable var model = model
        Group {
            switch style {
            case .embedded:
                HStack(spacing: 0) {
                    RanchOSLivestockSampleListView(model: model, style: style)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                        .frame(maxHeight: .infinity)
                    Divider()
                    RanchOSLivestockSampleDetailContainer(animal: model.selectedAnimal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .stacked:
                RanchOSLivestockSampleListView(
                    model: model,
                    style: style,
                    onOpenAnimal: onOpenAnimal)
            }
        }
        .navigationTitle("Sample animals")
        .toolbar {
            if style == .embedded {
                ToolbarItem(placement: .navigation) {
                    Button {
                        onRevealSidebar()
                    } label: {
                        Label("Show sidebar", systemImage: "sidebar.left")
                    }
                    .accessibilityHint("Shows the RanchOS sidebar")
                }
                ToolbarItem(placement: .automatic) {
                    Button("Livestock", systemImage: "pawprint") {
                        onCloseBrowser()
                    }
                    .accessibilityHint("Returns to the herd overview")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onReturnHome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .accessibilityHint("Returns to RanchOS Home")
            }
        }
        .onAppear {
            if style == .embedded {
                onRevealSidebar()
            }
        }
        .onChange(of: model.selectedAnimalID) { oldID, newID in
            if style == .stacked, oldID != nil, newID == nil {
                onAnimalCleared?()
            }
        }
    }
}

private struct RanchOSLivestockSampleListView: View {
    @Bindable var model: RanchOSLivestockBrowserModel
    var style: RanchOSLivestockBrowserColumnStyle
    var onOpenAnimal: ((String) -> Void)? = nil

    var body: some View {
        Group {
            switch style {
            case .embedded:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fixtureBanner
                        speciesPicker
                        animalResults
                    }
                    .padding(16)
                }
            case .stacked:
                List {
                    Section { fixtureBanner }
                    Section { speciesPicker }
                    stackedResults
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Name or identifier")
        .accessibilityLabel("Search sample animals by name or identifier")
    }

    private var fixtureBanner: some View {
        Label(RanchOSLivestockBrowserModel.fixtureLabel, systemImage: "testtube.2")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel(RanchOSLivestockBrowserModel.fixtureLabel)
    }

    private var speciesPicker: some View {
        Picker("Species", selection: $model.speciesFilter) {
            ForEach(RanchOSLivestockSpeciesFilter.pickerChoices) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .accessibilityLabel("Filter sample animals by species")
    }

    @ViewBuilder
    private var animalResults: some View {
        switch model.listState {
        case .emptyCatalog:
            ContentUnavailableView(
                "No sample animals",
                systemImage: "pawprint",
                description: Text("This DEV fixture catalog has no sample animals."))
        case .noMatches:
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No sample animals match the current name, identifier, or species filter."))
        case .results(let animals):
            ForEach(animals) { animal in
                animalButton(animal)
                    .background(
                        model.selectedAnimalID == animal.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var stackedResults: some View {
        switch model.listState {
        case .emptyCatalog:
            ContentUnavailableView(
                "No sample animals",
                systemImage: "pawprint",
                description: Text("This DEV fixture catalog has no sample animals."))
        case .noMatches:
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No sample animals match the current name, identifier, or species filter."))
        case .results(let animals):
            Section {
                ForEach(animals) { animal in
                    animalButton(animal)
                        .listRowBackground(
                            model.selectedAnimalID == animal.id
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear)
                }
            }
        }
    }

    private func animalButton(_ animal: RanchOSLivestockSampleAnimal) -> some View {
        Button {
            model.selectAnimal(id: animal.id)
            if style == .stacked {
                onOpenAnimal?(animal.id)
            }
        } label: {
            RanchOSLivestockSampleRow(animal: animal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibilityLabel(for: animal))
        .accessibilityAddTraits(model.selectedAnimalID == animal.id ? .isSelected : [])
    }

    private func rowAccessibilityLabel(for animal: RanchOSLivestockSampleAnimal) -> String {
        var parts = [animal.displayName, animal.species.label, animal.lifecycleStatus.label]
        if let identifier = animal.identifier {
            parts.append(identifier.summary)
        }
        return parts.joined(separator: ", ")
    }
}

struct RanchOSLivestockSampleDetailContainer: View {
    let animal: RanchOSLivestockSampleAnimal?
    var onReturnHome: (() -> Void)? = nil
    var showsNavigationTitle = false

    var body: some View {
        Group {
            if let animal {
                RanchOSLivestockSampleDetailView(
                    animal: animal,
                    showsNavigationTitle: showsNavigationTitle)
            } else {
                ContentUnavailableView(
                    "Select a sample animal",
                    systemImage: "pawprint",
                    description: Text(RanchOSLivestockBrowserModel.fixtureLabel))
            }
        }
        .toolbar {
            if let onReturnHome {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onReturnHome()
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    .accessibilityHint("Returns to RanchOS Home")
                }
            }
        }
    }
}

private struct RanchOSLivestockSampleRow: View {
    let animal: RanchOSLivestockSampleAnimal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(animal.displayName)
                .font(.headline)
            Text(rowDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        var parts = [animal.species.label, animal.productionType.label, animal.lifecycleStatus.label]
        if let identifier = animal.identifier {
            parts.append(identifier.summary)
        }
        return parts.joined(separator: " · ")
    }
}

private struct RanchOSLivestockSampleDetailView: View {
    let animal: RanchOSLivestockSampleAnimal
    var showsNavigationTitle = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(RanchOSLivestockBrowserModel.fixtureLabel, systemImage: "testtube.2")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(RanchOSLivestockBrowserModel.fixtureLabel)

                VStack(alignment: .leading, spacing: 6) {
                    Text(animal.displayName)
                        .font(.largeTitle.bold())
                    Text("\(animal.lifecycleStatus.label) · sample animal")
                        .foregroundStyle(.secondary)
                }

                detailGroup(title: "Animal details", systemImage: "leaf") {
                    LabeledContent("Species", value: animal.species.label)
                    LabeledContent("Production type", value: animal.productionType.label)
                    LabeledContent("Breed", value: animal.breed?.label ?? "Breed not recorded")
                }

                detailGroup(title: "Record status", systemImage: "circle.lefthalf.filled") {
                    LabeledContent("Status", value: animal.lifecycleStatus.label)
                }

                detailGroup(title: "Animal identification", systemImage: "tag") {
                    if let identifier = animal.identifier {
                        LabeledContent(identificationLabel(for: identifier), value: identifier.value)
                    } else {
                        Text("No tag, band, or other ID recorded.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ranchOSNavigationTitle(showsNavigationTitle ? animal.displayName : nil)
    }

    private func identificationLabel(for identifier: RanchOSLivestockSampleIdentifier) -> String {
        switch identifier.kind.lowercased() {
        case "tag": "Tag"
        case "band": "Band"
        case "brand": "Brand"
        default: identifier.kind
        }
    }

    private func detailGroup<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private extension View {
    @ViewBuilder
    func ranchOSNavigationTitle(_ title: String?) -> some View {
        if let title {
            navigationTitle(title)
        } else {
            self
        }
    }
}
#endif
