import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

struct LivestockPackageReading: Equatable, Sendable {
    var barcode: String
    var labelText: String
}

enum LivestockProductNameSource: String, Equatable, Sendable {
    case appleIntelligence
    case labelText
    case none
}

struct LivestockNamedProduct: Equatable, Sendable {
    var name: String
    var kind: String
    var feedType: LivestockInputType?
    var source: LivestockProductNameSource

    static let unnamed = LivestockNamedProduct(name: "", kind: "", feedType: nil, source: .none)
}

protocol LivestockOnDeviceProductNaming: Sendable {
    func name(
        from reading: LivestockPackageReading,
        category: LivestockProductCategory,
        feedChoices: [LivestockInputType]
    ) async -> LivestockNamedProduct?
}

enum LivestockPackageScan {
    static func read(_ image: CGImage) -> LivestockPackageReading {
        LivestockPackageReading(
            barcode: barcodes(in: image).first ?? "",
            labelText: recognizedText(in: image)
        )
    }

    static func barcodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [
            .ean8, .ean13, .upce, .code39, .code128, .itf14, .qr, .dataMatrix, .pdf417,
        ]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { result in
            LivestockProductDirectory.cleanedBarcode(result.payloadStringValue ?? "")
        }.filter { !$0.isEmpty }
    }

    static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return LivestockProductNamer.cleanedLabel(lines.joined(separator: "\n"))
    }
}

enum LivestockProductNamer {
    static func name(
        _ reading: LivestockPackageReading,
        category: LivestockProductCategory,
        feedChoices: [LivestockInputType],
        using model: (any LivestockOnDeviceProductNaming)? = LivestockAppleIntelligenceProductNamer()
    ) async -> LivestockNamedProduct {
        if let model,
           let named = await model.name(from: reading, category: category, feedChoices: feedChoices),
           !LivestockProductDirectory.cleanedName(named.name).isEmpty
        {
            return named
        }
        return draft(from: reading, category: category, feedChoices: feedChoices)
    }

    static func draft(
        from reading: LivestockPackageReading,
        category: LivestockProductCategory,
        feedChoices: [LivestockInputType]
    ) -> LivestockNamedProduct {
        let barcode = LivestockProductDirectory.cleanedBarcode(reading.barcode)
        let lines = labelLines(reading.labelText, ignoringBarcode: barcode)
        let name = LivestockProductDirectory.cleanedName(productName(from: lines))
        guard !name.isEmpty else { return .unnamed }
        return LivestockNamedProduct(
            name: name,
            kind: category == .medication ? guessedKind(in: reading.labelText) : "",
            feedType: category == .feed ? guessedFeedType(in: reading.labelText, choices: feedChoices) : nil,
            source: .labelText
        )
    }

    static func cleanedLabel(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func labelLines(_ raw: String, ignoringBarcode barcode: String) -> [String] {
        let ignored = barcode.uppercased()
        return cleanedLabel(raw)
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { line in
                let cleaned = LivestockProductDirectory.cleanedName(line)
                guard cleaned.count >= 3 else { return false }
                let compact = LivestockProductDirectory.cleanedBarcode(line)
                if !ignored.isEmpty, compact == ignored { return false }
                if compact.count >= 8, compact.allSatisfy(\.isNumber) { return false }
                return !isNoise(cleaned)
            }
    }

    static func productName(from lines: [String]) -> String {
        guard let first = lines.first else { return "" }
        if first.count <= 16, lines.count > 1, lines[1].count <= 40 {
            return "\(first) \(lines[1])"
        }
        return first
    }

    static func guessedKind(in text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("tablet") || lowered.contains("caplet") || lowered.contains("capsule") {
            return "Pills"
        }
        if lowered.contains("paste") || lowered.contains("gel") {
            return "Paste"
        }
        if lowered.contains("inject") || lowered.contains("vaccine") || lowered.contains("vaccination") {
            return "Injection"
        }
        if lowered.contains("liquid") || lowered.contains("solution") || lowered.contains("syrup") || lowered.contains("suspension") {
            return "Liquid"
        }
        return ""
    }

    static func guessedFeedType(in text: String, choices: [LivestockInputType]) -> LivestockInputType? {
        guard !choices.isEmpty else { return nil }
        let lowered = text.lowercased()
        var best: (LivestockInputType, Int)?
        for choice in choices {
            for token in feedTokens(choice) where lowered.contains(token) {
                let score = token.count
                if score > (best?.1 ?? 0) {
                    best = (choice, score)
                }
            }
        }
        return best?.0
    }

    private static func isNoise(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let skipped = [
            "net wt", "net weight", "ingredients", "guaranteed analysis", "nutrition facts",
            "keep refrigerated", "manufactured", "distributed by", "best by", "exp.", "lot ",
            "www.", ".com", "calories", "serving size", "warning", "keep out of reach",
        ]
        return skipped.contains { lowered.contains($0) }
    }

    private static func feedTokens(_ type: LivestockInputType) -> [String] {
        switch type {
        case .grassHay: return ["grass hay", "timothy"]
        case .alfalfaHay: return ["alfalfa hay", "alfalfa"]
        case .cornSilage: return ["corn silage", "silage"]
        case .preparedMeal: return ["prepared meal", "complete feed", "cattle cubes", "horse feed"]
        case .dryFood: return ["dry food", "kibble"]
        case .wetFood: return ["wet food", "canned"]
        case .oysterShell: return ["oyster shell"]
        case .corn: return ["corn"]
        case .oats: return ["oats"]
        case .hay: return ["hay"]
        case .mineral: return ["mineral"]
        case .supplement: return ["supplement"]
        case .pellets: return ["pellets", "pellet"]
        case .seed: return ["seed"]
        case .scratch: return ["scratch"]
        case .grit: return ["grit"]
        case .pasture: return ["pasture"]
        case .feed: return ["feed"]
        case .browse: return ["browse"]
        case .insects: return ["insects"]
        case .greens: return ["greens"]
        }
    }
}

struct LivestockAppleIntelligenceProductNamer: LivestockOnDeviceProductNaming {
    func name(
        from reading: LivestockPackageReading,
        category: LivestockProductCategory,
        feedChoices: [LivestockInputType]
    ) async -> LivestockNamedProduct? {
#if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else { return nil }
            let allowedFeed = feedChoices.map(\.rawValue).joined(separator: ", ")
            let session = LanguageModelSession(instructions: """
                You name a livestock product from package label text already read on this device.
                Use only that label text. Do not invent a name from the barcode digits.
                If the label does not include a product name, leave name empty.
                name: short brand plus product.
                kind: Pills, liquid, paste, injection, or empty.
                feedType: one of [\(allowedFeed)], or empty.
                """)
            do {
                let prompt = """
                    Category: \(category.rawValue)
                    Barcode digits (not a name): \(reading.barcode)
                    Label text:
                    \(reading.labelText)
                    """
                let response = try await session.respond(
                    to: prompt,
                    generating: LivestockGenerableProduct.self,
                    options: GenerationOptions(temperature: 0.1)
                )
                let content = response.content
                let name = LivestockProductDirectory.cleanedName(content.name)
                guard !name.isEmpty else { return nil }
                let feedType = feedChoices.first { $0.rawValue == content.feedType || $0.label.caseInsensitiveCompare(content.feedType) == .orderedSame }
                return LivestockNamedProduct(
                    name: name,
                    kind: category == .medication ? LivestockProductDirectory.cleanedName(content.kind) : "",
                    feedType: category == .feed ? feedType : nil,
                    source: .appleIntelligence
                )
            } catch {
                return nil
            }
        }
#endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable(description: "A product name copied from package label text.")
struct LivestockGenerableProduct {
    @Guide(description: "Brand plus product as written on the label, or empty when the label does not name a product.")
    var name: String

    @Guide(description: "Pills, liquid, paste, injection, or empty.")
    var kind: String

    @Guide(description: "Allowed feed type raw value, or empty.")
    var feedType: String
}
#endif
