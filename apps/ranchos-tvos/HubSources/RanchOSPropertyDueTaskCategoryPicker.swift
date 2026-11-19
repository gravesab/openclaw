import SwiftUI

enum RanchOSPropertyDueTaskCategoryPickerProminence {
    case canvas
    case television
}

struct RanchOSPropertyDueTaskCategoryPicker: View {
    let filters: [RanchOSPropertyDueTaskCategoryFilter]
    @Binding var selection: RanchOSPropertyDueTaskCategoryFilter
    var prominence: RanchOSPropertyDueTaskCategoryPickerProminence = .canvas

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Due tasks by category", systemImage: "line.3.horizontal.decrease.circle")
                .font(titleFont)
                .foregroundStyle(titleColor)

            picker
                .labelsHidden()
                .tint(tint)
                .accessibilityLabel("Filter due tasks by category")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var picker: some View {
        Picker("Category", selection: $selection) {
            ForEach(filters) { filter in
                Text(filter.label).tag(filter)
            }
        }
        #if os(iOS) || os(macOS)
        .pickerStyle(.menu)
        #endif
    }

    private var titleFont: Font {
        switch prominence {
        case .canvas: .headline
        case .television: .title3.weight(.semibold)
        }
    }

    private var titleColor: Color {
        switch prominence {
        case .canvas: Color(red: 0.09, green: 0.13, blue: 0.10)
        case .television: .white
        }
    }

    private var tint: Color {
        switch prominence {
        case .canvas: Color(red: 0.30, green: 0.40, blue: 0.25)
        case .television: .mint
        }
    }

    private var cardFill: Color {
        switch prominence {
        case .canvas: Color.white.opacity(0.72)
        case .television: Color.white.opacity(0.12)
        }
    }
}
