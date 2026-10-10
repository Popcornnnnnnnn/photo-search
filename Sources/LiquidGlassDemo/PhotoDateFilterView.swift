import SwiftUI

struct PhotoDateFilterButton: View {
    @Environment(ThemeStore.self) private var theme
    @Binding var selection: PhotoTimeFilter
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: selection == .all ? "calendar" : "calendar.badge.checkmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selection == .all ? theme.textSecondary : theme.accent)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(HoverButtonStyle(horizontalPadding: 8, verticalPadding: 8))
        .help(selection.title)
        .accessibilityLabel(String(localized: "Date range", bundle: .module))
        .accessibilityValue(selection.title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PhotoDateFilterPopover(selection: $selection)
        }
    }
}

private struct PhotoDateFilterPopover: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: PhotoTimeFilter
    @State private var start: Date
    @State private var end: Date

    init(selection: Binding<PhotoTimeFilter>) {
        _selection = selection
        let interval = selection.wrappedValue.interval()
        _start = State(initialValue: interval?.start ?? Date())
        // The query's upper bound is exclusive; calendars select inclusive days.
        _end = State(initialValue: interval.map { $0.end.addingTimeInterval(-1) } ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(PhotoTimeFilter.presets, id: \.self) { filter in
                    Button {
                        selection = filter
                        dismiss()
                    } label: {
                        Text(filter.title)
                            .foregroundStyle(selection == filter ? theme.accent : theme.textPrimary)
                            .background {
                                RoundedRectangle(cornerRadius: Radius.control)
                                    .fill(selection == filter ? theme.accent.opacity(0.10) : .clear)
                                    .padding(-5)
                            }
                    }
                    .buttonStyle(HoverButtonStyle(horizontalPadding: 10, verticalPadding: 6))
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                calendar(title: String(localized: "From", bundle: .module), date: $start)
                calendar(title: String(localized: "To", bundle: .module), date: $end)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                    .buttonStyle(HoverButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply", bundle: .module)) {
                    selection = .custom(start: Calendar.current.startOfDay(for: start),
                                        end: Calendar.current.startOfDay(for: end))
                    dismiss()
                }
                .buttonStyle(HoverButtonStyle(horizontalPadding: 14))
                .foregroundStyle(theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .fixedSize()
        .onChange(of: start) { _, value in if value > end { end = value } }
        .onChange(of: end) { _, value in if value < start { start = value } }
    }

    private func calendar(title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(title, selection: date, displayedComponents: .date)
                .datePickerStyle(.field)
            DatePicker(title, selection: date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
        }
    }
}
