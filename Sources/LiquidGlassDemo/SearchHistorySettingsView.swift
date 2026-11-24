import SwiftUI

struct SearchHistorySettingsView: View {
    let history: SearchHistoryStore
    let onSearch: (SearchHistoryEntry) -> Void

    @Environment(ThemeStore.self) private var theme
    @State private var filter = ""
    @State private var dateRange = SearchHistoryDateRange.all
    @State private var expansion: [SearchHistoryDay.ID: Bool] = [:]
    @State private var confirmsClear = false

    private var isFiltering: Bool {
        dateRange != .all || !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let groups = SearchHistoryDay.groups(for: history.entries, range: dateRange, query: filter)
        let matchCount = groups.reduce(0) { $0 + $1.entries.count }
        let hasExpandedGroup = groups.contains { isExpanded($0, in: groups) }
        VStack(alignment: .leading, spacing: 14) {
            searchField

            HStack(spacing: 8) {
                ForEach(SearchHistoryDateRange.allCases) { range in
                    Button {
                        dateRange = range
                    } label: {
                        Text(range.rawValue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HistoryButtonStyle(tone: dateRange == range ? .selected : .neutral))
                    .accessibilityAddTraits(dateRange == range ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search dates")

            HStack(spacing: 8) {
                Text(isFiltering
                     ? "\(matchCount) of \(history.entries.count) \(history.entries.count == 1 ? "search" : "searches")"
                     : "\(history.entries.count) \(history.entries.count == 1 ? "search" : "searches")")
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    for group in groups { expansion[group.id] = !hasExpandedGroup }
                } label: {
                    Label(hasExpandedGroup ? "Collapse All" : "Expand All",
                          systemImage: hasExpandedGroup ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(HistoryButtonStyle())
                .disabled(groups.isEmpty)
                Menu {
                    Button("Clear History…", role: .destructive) { confirmsClear = true }
                        .disabled(history.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Typography.control)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 32, height: 32)
                .modifier(HistoryControlSurface())
                .accessibilityLabel("History actions")
                .help("History actions")
            }
            .font(Typography.caption)

            if groups.isEmpty {
                ContentUnavailableView {
                    Label(history.entries.isEmpty ? "No Search History" : "No Matching Searches",
                          systemImage: history.entries.isEmpty ? "clock" : "magnifyingglass")
                } description: {
                    Text(history.entries.isEmpty
                         ? "Your searches will appear here."
                         : "Try another keyword or date range.")
                } actions: {
                    if isFiltering {
                        Button("Reset Filters") {
                            filter = ""
                            dateRange = .all
                        }
                        .buttonStyle(HistoryButtonStyle(tone: .accent))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollableContent {
                        LazyVStack(spacing: 10) {
                            Color.clear.frame(height: 0).id("history-top")
                            ForEach(groups) { group in
                                SearchHistoryDaySection(
                                    group: group,
                                    isExpanded: Binding(
                                        get: { isExpanded(group, in: groups) },
                                        set: { expansion[group.id] = $0 }
                                    ),
                                    onSearch: onSearch,
                                    onRemove: { history.remove(id: $0) }
                                )
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 6)
                    }
                    .onChange(of: filter) { proxy.scrollTo("history-top", anchor: .top) }
                    .onChange(of: dateRange) { proxy.scrollTo("history-top", anchor: .top) }
                }
            }

            if dateRange != .all, history.entries.contains(where: { $0.createdAt == nil }) {
                HStack(spacing: 4) {
                    Text("Undated searches are shown in")
                        .foregroundStyle(theme.textSecondary)
                    Button("All Time") { dateRange = .all }
                        .buttonStyle(HoverButtonStyle(horizontalPadding: 4, verticalPadding: 2))
                        .foregroundStyle(theme.accent)
                        .pointerStyle(.link)
                }
                .font(Typography.footnote)
            }
        }
        .onChange(of: filter) { expansion = [:] }
        .onChange(of: dateRange) { expansion = [:] }
        .confirmationDialog("Clear all search history?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("This removes all saved searches, including those hidden by the filters.")
        }
    }

    private func isExpanded(_ group: SearchHistoryDay, in groups: [SearchHistoryDay]) -> Bool {
        expansion[group.id] ?? (isFiltering || (group.date != nil && group.id == groups.first?.id))
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textSecondary)
            TextField("Filter history", text: $filter)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter history")
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(HoverButtonStyle(horizontalPadding: 4, verticalPadding: 2))
                .accessibilityLabel("Clear history filter")
            }
        }
        .font(Typography.body)
        .padding(12)
        .background(theme.hoverFill, in: RoundedRectangle(cornerRadius: Radius.field))
    }
}

private struct SearchHistoryDaySection: View {
    let group: SearchHistoryDay
    @Binding var isExpanded: Bool
    let onSearch: (SearchHistoryEntry) -> Void
    let onRemove: (UUID) -> Void

    @Environment(ThemeStore.self) private var theme
    @State private var visibleCount = 10

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if group.date == nil {
                    Text("Saved before search dates were recorded.")
                        .font(Typography.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 8)
                }
                ForEach(group.entries.prefix(visibleCount)) { entry in
                    SearchHistorySettingsRow(entry: entry,
                                             onSearch: { onSearch(entry) },
                                             onRemove: { onRemove(entry.id) })
                        .overlay(alignment: .bottom) { Divider() }
                }
                if group.entries.count > visibleCount {
                    Button {
                        visibleCount += 10
                    } label: {
                        Label("Show \(min(10, group.entries.count - visibleCount)) more · \(group.entries.count - visibleCount) remaining",
                              systemImage: "chevron.down")
                    }
                    .buttonStyle(HistoryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(group.title())
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                if let date = group.date, group.title() == "Today" || group.title() == "Yesterday" {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(Typography.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                Text("\(group.entries.count)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.hoverFill, in: Capsule())
            }
            .padding(.vertical, 4)
        }
        .tint(theme.textSecondary)
        .padding(12)
        .background(theme.hoverFill.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.field))
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { visibleCount = 10 }
        }
    }
}

private struct SearchHistorySettingsRow: View {
    let entry: SearchHistoryEntry
    let onSearch: () -> Void
    let onRemove: () -> Void

    @Environment(ThemeStore.self) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSearch) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.query)
                            .font(Typography.body)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if entry.createdAt != nil || entry.section != .all {
                            HStack(spacing: 8) {
                                if let date = entry.createdAt {
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                }
                                if entry.section != .all {
                                    Text(entry.section.title)
                                }
                            }
                            .font(Typography.footnote)
                            .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Search again: \(entry.query)")
            .accessibilityHint("Search again")

            Button(action: onSearch) {
                Label("Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(HistoryButtonStyle(tone: .accent))
            .help("Search again: \(entry.query)")
            .accessibilityLabel("Search again: \(entry.query)")

            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(HistoryButtonStyle(tone: .destructive, iconOnly: true))
            .help("Remove this search")
            .accessibilityLabel("Remove \(entry.query) from history")
        }
        .padding(.horizontal, 10)
        .background(hovering ? theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
        .onHover { hovering = $0 }
    }
}

private enum HistoryControlTone {
    case neutral, accent, selected, destructive
}

private struct HistoryButtonStyle: ButtonStyle {
    var tone: HistoryControlTone = .neutral
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.control)
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? 32 : nil, height: 32)
            .modifier(HistoryControlSurface(tone: tone, pressed: configuration.isPressed))
    }
}

private struct HistoryControlSurface: ViewModifier {
    var tone: HistoryControlTone = .neutral
    var pressed = false

    @Environment(ThemeStore.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var foreground: Color {
        switch tone {
        case .selected: .white
        case .accent: theme.accent
        case .destructive: hovering ? theme.danger : theme.textSecondary
        case .neutral: theme.textPrimary
        }
    }

    private var fill: Color {
        switch tone {
        case .selected: theme.accent.opacity(pressed ? 0.80 : hovering ? 0.90 : 1)
        case .accent: theme.accent.opacity(hovering || pressed ? 0.16 : 0.09)
        case .destructive where hovering || pressed: theme.danger.opacity(0.10)
        default: hovering || pressed ? theme.hoverFill.opacity(0.65) : theme.background.opacity(0.85)
        }
    }

    private var border: Color {
        switch tone {
        case .selected: .clear
        case .accent: theme.accent.opacity(hovering ? 0.30 : 0.16)
        case .destructive where hovering || pressed: theme.danger.opacity(0.28)
        default: theme.divider.opacity(hovering ? 1 : 0.85)
        }
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
            .shadow(color: .black.opacity(tone == .selected ? 0.08 : 0.025), radius: 2, y: 1)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
    }
}
