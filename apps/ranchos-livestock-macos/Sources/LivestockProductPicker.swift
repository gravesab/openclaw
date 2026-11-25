import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

struct LivestockProductFields: View {
    let category: LivestockProductCategory
    var fieldTitle: String
    var kindTitle: String? = nil
    var feedChoices: [LivestockInputType] = []
    @Binding var name: String
    @Binding var kind: String
    var feedType: Binding<LivestockInputType>? = nil
    @Binding var catalog: LivestockProductDirectory

    @State private var pickedID = ""
    @State private var scanning = false
    @State private var pickingPhoto = false
    @State private var naming = false
    @State private var lookingUp = false
    @State private var pendingBarcode = ""
    @State private var draftName = ""
    @State private var draftKind = ""
    @State private var draftFeedType: LivestockInputType = .feed
    @State private var notice: String?
    @State private var lookupGeneration = 0

    private var listed: [LivestockProduct] { catalog.products(in: category) }

    var body: some View {
        Group {
            if !listed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.pickerTitle)
                        .foregroundStyle(.secondary)
                    Picker(category.pickerTitle, selection: $pickedID) {
                        Text(category.emptyPickerLabel).tag("")
                        ForEach(listed) { product in
                            Text(pickerLabel(product)).tag(product.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .onChange(of: pickedID) { _, id in
                    guard let product = listed.first(where: { $0.id.uuidString == id }) else { return }
                    name = product.name
                    if category == .medication { kind = product.kind }
                    if category == .feed, let type = product.feedType, feedChoices.contains(type) {
                        feedType?.wrappedValue = type
                    }
                }
            }
            if category != .feed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fieldTitle)
                        .foregroundStyle(.secondary)
                    TextField(fieldTitle, text: $name)
                        .appleIntelligenceDictation($name)
                }
            }
            if let kindTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kindTitle)
                        .foregroundStyle(.secondary)
                    TextField(kindTitle, text: $kind, prompt: Text("Pills, liquid, paste"))
                        .appleIntelligenceDictation($kind)
                }
            }
            HStack {
                Button(category.scanLabel) { startScan() }
                    .disabled(lookingUp)
                Button("Enter barcode") {
                    pendingBarcode = ""
                    draftName = name
                    draftKind = kind
                    draftFeedType = feedType?.wrappedValue ?? feedChoices.first ?? .feed
                    notice = "A barcode number is not a product name. Name it here, or scan the package so this device can read the label."
                    naming = true
                }
                .disabled(lookingUp)
            }
            if lookingUp {
                ProgressView("Reading the package on this device…")
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The camera reads the barcode and label on this device. Nothing is sent to a lookup service. Choose a scanned product if you want to use it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $scanning) {
            LivestockBarcodeScanSheet { barcode, labelText in
                scanning = false
                handlePackage(barcode: barcode, labelText: labelText)
            } onCancel: {
                scanning = false
            }
        }
        .fileImporter(isPresented: $pickingPhoto, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                handlePhoto(url)
            case .failure:
                notice = "That photo could not be opened."
            }
        }
        .sheet(isPresented: $naming) {
            NavigationStack {
                Form {
                    TextField("Name", text: $draftName)
                        .appleIntelligenceDictation($draftName)
                    if category == .medication {
                        TextField("Kind", text: $draftKind, prompt: Text("Pills, liquid, paste"))
                            .appleIntelligenceDictation($draftKind)
                    }
                    if category == .feed, !feedChoices.isEmpty {
                        Picker("Feed type", selection: $draftFeedType) {
                            ForEach(feedChoices) { item in
                                Text(item.label).tag(item)
                            }
                        }
                    }
                    TextField("Barcode", text: $pendingBarcode)
                        .appleIntelligenceDictation($pendingBarcode)
                    Text("Name stays on this device. The barcode is stored with the product so a later scan can find it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle(category.scanLabel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { naming = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add to list") { saveNamedProduct() }
                            .disabled(LivestockProductDirectory.cleanedName(draftName).isEmpty)
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 280)
            #endif
        }
    }

    private func pickerLabel(_ product: LivestockProduct) -> String {
        if category == .medication, !product.kind.isEmpty {
            return "\(product.name) · \(product.kind)"
        }
        if category == .feed, let type = product.feedType {
            return "\(product.name) · \(type.label)"
        }
        return product.name
    }

    private func startScan() {
        notice = nil
        #if os(iOS)
        scanning = true
        #else
        pickingPhoto = true
        #endif
    }

    private func handlePhoto(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let image = cgImage(from: url) else {
            notice = "That photo could not be read."
            return
        }
        let reading = LivestockPackageScan.read(image)
        guard !reading.barcode.isEmpty else {
            notice = "No barcode was found in that photo. Include the code, or enter it."
            return
        }
        handlePackage(barcode: reading.barcode, labelText: reading.labelText)
    }

    private func handlePackage(barcode raw: String, labelText: String) {
        let code = LivestockProductDirectory.cleanedBarcode(raw)
        guard !code.isEmpty else {
            notice = "That barcode could not be read."
            return
        }
        if let existing = catalog.product(barcode: code, in: category) {
            notice = "\(existing.name) is already in the list. Choose it if you want to use it."
            catalog.save()
            return
        }
        lookupGeneration += 1
        let generation = lookupGeneration
        lookingUp = true
        notice = nil
        Task {
            let named = await LivestockProductNamer.name(
                LivestockPackageReading(barcode: code, labelText: labelText),
                category: category,
                feedChoices: feedChoices
            )
            await MainActor.run {
                guard generation == lookupGeneration else { return }
                lookingUp = false
                applyNamed(named, barcode: code)
            }
        }
    }

    private func applyNamed(_ named: LivestockNamedProduct, barcode: String) {
        let cleaned = LivestockProductDirectory.cleanedName(named.name)
        if named.source == .appleIntelligence, !cleaned.isEmpty {
            remember(
                name: cleaned,
                kind: named.kind,
                barcode: barcode,
                feedType: named.feedType,
                notice: "Apple Intelligence read this as \(cleaned). Choose it if you want to use it."
            )
            return
        }
        pendingBarcode = barcode
        draftName = cleaned.isEmpty ? name : cleaned
        draftKind = named.kind.isEmpty ? kind : named.kind
        draftFeedType = named.feedType ?? feedType?.wrappedValue ?? feedChoices.first ?? .feed
        naming = true
        notice = cleaned.isEmpty
            ? "The barcode was read, but this device could not name the product from the label. Name it to add it to the list."
            : "Read from the label. Confirm the name to add it to the list."
    }

    private func saveNamedProduct() {
        let named = LivestockProductDirectory.cleanedName(draftName)
        guard !named.isEmpty else { return }
        remember(
            name: named,
            kind: draftKind,
            barcode: pendingBarcode,
            feedType: category == .feed ? draftFeedType : nil,
            notice: "\(named) is in the list. Choose it if you want to use it."
        )
        naming = false
        pendingBarcode = ""
        draftName = ""
        draftKind = ""
    }

    private func remember(
        name: String,
        kind: String,
        barcode: String,
        feedType: LivestockInputType?,
        notice message: String
    ) {
        catalog.remember(
            LivestockProduct(
                category: category,
                name: name,
                kind: category == .medication ? kind : "",
                barcode: barcode,
                feedType: category == .feed ? feedType : nil
            )
        )
        catalog.save()
        notice = message
    }

    private func cgImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct LivestockBarcodeScanSheet: View {
    var onPackage: (String, String) -> Void
    var onCancel: () -> Void

    var body: some View {
        #if os(iOS)
        LivestockDataScannerView(onPackage: onPackage, onCancel: onCancel)
            .ignoresSafeArea()
        #else
        VStack(spacing: 16) {
            Text("Choose a photo of the barcode and the product name on the package.")
                .multilineTextAlignment(.center)
            Button("Cancel", action: onCancel)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 160)
        #endif
    }
}

#if os(iOS)
private struct LivestockDataScannerView: UIViewControllerRepresentable {
    var onPackage: (String, String) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            context.coordinator.fail()
            return UIViewController()
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean8, .ean13, .upce, .code39, .code128, .itf14, .qr, .dataMatrix, .pdf417]),
                .text(),
            ],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.fail()
        }
        return scanner
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        (uiViewController as? DataScannerViewController)?.stopScanning()
        coordinator.cancelPending()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPackage: onPackage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPackage: (String, String) -> Void
        let onCancel: () -> Void
        private var handled = false
        private var pendingBarcode = ""
        private var pendingText: [String] = []
        private var finishTask: Task<Void, Never>?

        init(onPackage: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
            self.onPackage = onPackage
            self.onCancel = onCancel
        }

        func cancelPending() {
            finishTask?.cancel()
        }

        func fail() {
            guard !handled else { return }
            handled = true
            finishTask?.cancel()
            Task { @MainActor in
                self.onCancel()
            }
        }

        func dataScanner(
            _: DataScannerViewController,
            didAdd _: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !handled else { return }
            collect(allItems)
            guard !pendingBarcode.isEmpty else { return }
            finishTask?.cancel()
            finishTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, !self.handled else { return }
                self.handled = true
                self.onPackage(self.pendingBarcode, self.pendingText.joined(separator: "\n"))
            }
        }

        func dataScanner(_: DataScannerViewController, didRemove _: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            collect(allItems)
        }

        func dataScanner(
            _: DataScannerViewController,
            becameUnavailableWithError _: DataScannerViewController.ScanningUnavailable
        ) {
            fail()
        }

        private func collect(_ items: [RecognizedItem]) {
            var barcodes: [String] = []
            var lines: [String] = []
            for item in items {
                switch item {
                case let .barcode(barcode):
                    let code = LivestockProductDirectory.cleanedBarcode(barcode.payloadStringValue ?? "")
                    if !code.isEmpty { barcodes.append(code) }
                case let .text(text):
                    let line = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { lines.append(line) }
                @unknown default:
                    continue
                }
            }
            if let code = barcodes.first {
                pendingBarcode = code
            }
            if !lines.isEmpty {
                pendingText = lines
            }
        }
    }
}
#endif
