#if !os(tvOS)
import SwiftUI

struct RanchOSLivestockBrowserView: View {
    @State private var model = RanchOSLivestockBrowserModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack {
                    RanchOSLivestockSampleListView(model: model)
                        .navigationDestination(item: $model.selectedAnimalID) { _ in
                            RanchOSLivestockSampleDetailContainer(animal: model.selectedAnimal)
                        }
                }
            } else {
                NavigationSplitView {
                    RanchOSLivestockSampleListView(model: model)
                } detail: {
                    RanchOSLivestockSampleDetailContainer(animal: model.selectedAnimal)
                }
            }
        }
        .navigationTitle("Sample animals")
    }
}

private struct RanchOSLivestockSampleListView: View {
    @Bindable var model: RanchOSLivestockBrowserModel

    var body: some View {
        List(selection: $model.selectedAnimalID) {
            Section {
                Label(RanchOSLivestockBrowserModel.fixtureLabel, systemImage: "testtube.2")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(RanchOSLivestockBrowserModel.fixtureLabel)
            }

            Section {
                Picker("Species", selection: $model.speciesFilter) {
                    ForEach(RanchOSLivestockSpeciesFilter.pickerChoices) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .accessibilityLabel("Filter sample animals by species")
            }

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
                        RanchOSLivestockSampleRow(animal: animal)
                            .tag(Optional.some(animal.id))
                            .accessibilityLabel(rowAccessibilityLabel(for: animal))
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Name or identifier")
        .accessibilityLabel("Search sample animals by name or identifier")
    }

    private func rowAccessibilityLabel(for animal: RanchOSLivestockSampleAnimal) -> String {
        var parts = [animal.displayName, animal.species.label, animal.lifecycleStatus.label]
        if let identifier = animal.identifier {
            parts.append(identifier.summary)
        }
        return parts.joined(separator: ", ")
    }
}

private struct RanchOSLivestockSampleDetailContainer: View {
    let animal: RanchOSLivestockSampleAnimal?

    var body: some View {
        if let animal {
            RanchOSLivestockSampleDetailView(animal: animal)
        } else {
            ContentUnavailableView(
                "Select a sample animal",
                systemImage: "pawprint",
                description: Text(RanchOSLivestockBrowserModel.fixtureLabel))
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

                detailGroup(title: "Catalog", systemImage: "leaf") {
                    LabeledContent("Species", value: animal.species.label)
                    LabeledContent("Production type", value: animal.productionType.label)
                    LabeledContent("Breed", value: animal.breed?.label ?? "No breed")
                }

                detailGroup(title: "Lifecycle status", systemImage: "circle.lefthalf.filled") {
                    LabeledContent("Animal status", value: animal.lifecycleStatus.label)
                    Text("Lifecycle status is the animal record state. It is not fact freshness.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                detailGroup(title: "Fact freshness", systemImage: "clock") {
                    LabeledContent("Confidence", value: animal.factFreshness.label)
                    Text("Freshness describes sample-fact confidence only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                detailGroup(title: "Identifiers", systemImage: "number") {
                    if let identifier = animal.identifier {
                        LabeledContent(identifier.kind, value: identifier.value)
                    } else {
                        Text("No identifier")
                            .foregroundStyle(.secondary)
                    }
                }

                detailGroup(title: "Provenance", systemImage: "doc.text") {
                    Text(animal.provenance.label)
                        .foregroundStyle(.secondary)
                    Text(RanchOSLivestockSampleCatalog.unavailableHistoriesNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(animal.displayName)
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
#endif
