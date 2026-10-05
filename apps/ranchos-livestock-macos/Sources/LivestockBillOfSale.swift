import AppKit
import CoreText

enum LivestockBillOfSale {
    static func pdfData(for animal: Animal) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return Data() }

        let margin: CGFloat = 54
        let contentWidth = media.width - (margin * 2)
        var cursor = media.height - margin
        var pageOpen = false

        func startPage() {
            context.beginPDFPage(nil)
            cursor = media.height - margin
            pageOpen = true
        }

        func draw(_ text: String, font: NSFont, gap: CGFloat) {
            if !pageOpen { startPage() }
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                nil
            )
            let height = max(ceil(suggested.height), font.ascender - font.descender)
            if cursor - height < margin {
                context.endPDFPage()
                startPage()
            }
            let rect = CGRect(x: margin, y: cursor - height, width: contentWidth, height: height)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                CGPath(rect: rect, transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            cursor = rect.minY - gap
        }

        let title = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let heading = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 12)
        for line in lines(for: animal) {
            switch line.kind {
            case .title:
                draw(line.text, font: title, gap: 10)
            case .heading:
                draw(line.text, font: heading, gap: 4)
            case .body:
                draw(line.text, font: body, gap: 3)
            }
        }
        if pageOpen { context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    static func open(_ animal: Animal) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RanchOSLivestock", isDirectory: true)
        let url = directory.appendingPathComponent(filename(for: animal))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pdfData(for: animal).write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    static func filename(for animal: Animal) -> String {
        let stem = animal.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" { return character }
                return "-"
            }
        let cleaned = String(stem).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(cleaned.isEmpty ? "animal" : cleaned)-bill-of-sale.pdf"
    }

    static func lines(for animal: Animal) -> [Line] {
        var lines: [Line] = [
            Line("Bill of sale", kind: .title),
            Line(animal.displayName, kind: .heading),
            Line("Sale", kind: .heading),
        ]
        if let amount = animal.saleAmount, let saleOn = animal.saleOn {
            lines.append(Line("Sale amount: \(LivestockMoney.usd(amount))"))
            lines.append(Line("Sale date: \(day(saleOn))"))
        } else {
            lines.append(Line("No sale recorded"))
        }
        if let retiredAt = animal.retiredOn {
            lines.append(Line("Retired: \(day(retiredAt))"))
        }
        lines.append(Line("Reason: \(animal.retirementDisplay)"))

        lines.append(Line("Animal", kind: .heading))
        lines.append(Line("Species: \(animal.speciesDisplay)"))
        if animal.species != .pet {
            lines.append(Line("Production type: \(animal.productionType.label)"))
        }
        lines.append(Line("Breed: \(animal.breedDisplay)"))
        lines.append(Line("Status: \(animal.status)"))

        lines.append(Line("Herd", kind: .heading))
        if let name = animal.herdName, !name.isEmpty {
            lines.append(Line("Herd: \(name)"))
            if let started = animal.herdStartedAt {
                lines.append(Line("Since: \(started.formatted(date: .abbreviated, time: .shortened))"))
            }
        } else {
            lines.append(Line("No herd"))
        }

        lines.append(Line("Identifiers", kind: .heading))
        if animal.identifiers.isEmpty {
            lines.append(Line(animal.species == .pet ? "No license" : "No identifier"))
        } else {
            for identifier in animal.identifiers {
                var text = "\(identifier.kind.label): \(identifier.value)"
                if let reason = identifier.retirementReason {
                    text += " · \(reason.label)"
                }
                lines.append(Line(text))
            }
        }

        lines.append(Line("Routine lifecycle history", kind: .heading))
        if animal.lifecycleEvents.isEmpty {
            lines.append(Line("No routine lifecycle history"))
        } else {
            for event in animal.lifecycleEvents {
                lines.append(Line("\(event.type.label): \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }

        lines.append(Line("Care", kind: .heading))
        if animal.careEvents.isEmpty {
            lines.append(Line("No care records"))
        } else {
            for event in animal.careEvents {
                lines.append(Line("\(event.type.label): \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }

        lines.append(Line("Feed", kind: .heading))
        if animal.consumptions.isEmpty {
            lines.append(Line("No feed consumption"))
        } else {
            for item in animal.consumptions {
                lines.append(Line("\(item.summary): \(item.observedAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }

        lines.append(Line("Cost", kind: .heading))
        let operational = animal.costs.filter { $0.frequency == nil }
        if operational.isEmpty {
            lines.append(Line("No operational costs"))
        } else {
            for item in operational {
                lines.append(Line(item.summary))
            }
        }
        lines.append(Line("Total Cost: \(LivestockMoney.usd(animal.recordedCostTotal))"))

        lines.append(Line("Costs by date", kind: .heading))
        let days = LivestockCostLedger.days(from: animal.costs)
        if days.isEmpty {
            lines.append(Line("No costs recorded"))
        } else {
            for day in days {
                lines.append(Line("\(self.day(day.day)): \(LivestockMoney.usd(day.total))"))
                for entry in day.lines {
                    lines.append(Line("\(entry.label): \(LivestockMoney.usdSigned(entry.amount))"))
                }
            }
        }

        lines.append(Line("This bill of sale stays with the animal. It does not post to Finance."))
        return lines
    }

    struct Line: Equatable {
        enum Kind { case title, heading, body }
        let text: String
        let kind: Kind

        init(_ text: String, kind: Kind = .body) {
            self.text = text
            self.kind = kind
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
