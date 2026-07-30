import SwiftUI

enum CategoryStyle {
    static func icon(for name: String) -> String {
        switch name {
        case "Pool":
            return "drop.fill"
        case "Hot Tub":
            return "figure.pool.swim"
        case "Grounds":
            return "leaf.fill"
        case "Equipment":
            return "wrench.adjustable.fill"
        case "House":
            return "house.fill"
        case "Safety":
            return "exclamationmark.shield.fill"
        case "Property":
            return "map.fill"
        default:
            return "folder.fill"
        }
    }

    static func color(for name: String) -> Color {
        switch colorName(for: name) {
        case "blue":
            return .blue
        case "purple":
            return .purple
        case "green":
            return .green
        case "orange":
            return .orange
        case "teal":
            return .teal
        case "red":
            return .red
        case "brown":
            return .brown
        default:
            return .gray
        }
    }

    static func colorName(for name: String) -> String {
        switch name {
        case "Pool":
            return "blue"
        case "Hot Tub":
            return "purple"
        case "Grounds":
            return "green"
        case "Equipment":
            return "orange"
        case "House":
            return "teal"
        case "Safety":
            return "red"
        case "Property":
            return "brown"
        default:
            return "gray"
        }
    }

    static let builtInNames = [
        "Pool", "Hot Tub", "Grounds", "Equipment", "House", "Safety", "Property"
    ]
}
