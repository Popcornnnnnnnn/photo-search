import SwiftUI

struct PhotoCard: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: IndexedPhoto
    let selected: Bool
    let contentMode: ContentMode

    @State private var hovering = false
    @State private var previewing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PhotoThumbnailView(
                    path: photo.thumbnailPath,
                    contentMode: contentMode,
                    maxPixelSize: 560,
                    animatesContentMode: true
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(previewing && !reduceMotion ? 1.055 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.38), value: previewing)

                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.55), location: 0),
                            .init(color: .clear, location: 0.30),
                            .init(color: .clear, location: 0.47),
                            .init(color: .black.opacity(0.82), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: Layout.photoCardTextSpacing) {
                            Text(verbatim: photo.displayAssetType)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.48), in: .rect(cornerRadius: 6))
                            Spacer(minLength: 0)
                            if let date = photo.cardDate {
                                Text(verbatim: date)
                                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                            }
                        }
                        .font(Typography.footnote)
                        .lineLimit(1)

                        Spacer(minLength: 0)

                        if let evidence = photo.matchEvidence, !evidence.label.isEmpty {
                            Text(evidence.label)
                                .font(Typography.footnote)
                                .lineLimit(1)
                                .padding(.bottom, 4)
                        }
                        Text(verbatim: photo.cardTitle)
                            .font(Typography.label)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, photo.isVideo ? 60 : 0)
                            .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if photo.isVideo {
                            Label(photo.displayDuration ?? "", systemImage: "play.fill")
                                .font(.caption.monospacedDigit())
                                .padding(5)
                                .background(.black.opacity(0.65), in: .rect(cornerRadius: 5))
                        }
                    }
                    .padding(Layout.photoCardInset)
                    .foregroundStyle(.white)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(previewing ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: previewing)
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(height: Layout.photoPreviewHeight)
        .background(theme.textPrimary.opacity(0.035))
        .clipShape(.rect(cornerRadius: Radius.content))
        .themedBorder(
            Radius.content,
            color: selected ? theme.accent : (hovering ? theme.accent.opacity(0.45) : nil),
            width: selected ? 1.5 : Layout.hairline
        )
        .shadow(color: .black.opacity(selected ? 0.10 : 0.035), radius: selected ? 6 : 2, y: 2)
        .contentShape(.rect(cornerRadius: Radius.content))
        .pointerStyle(.link)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(photo.cardTitle), \(photo.displayAssetType)\(photo.cardDate.map { ", \($0)" } ?? "")\(photo.matchEvidence.map { ", \($0.label)" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .task(id: hovering) {
            guard hovering else {
                previewing = false
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            previewing = true
        }
    }
}

private extension IndexedPhoto {
    var cardTitle: String {
        // Reuse existing labels without rewriting the stored caption or inventing a summary.
        let candidates = assetType == "photo" ? annotation?.entities : annotation?.topics
        var labels: [String] = []
        for candidate in candidates ?? [] {
            let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 24,
                  !labels.contains(where: { $0.localizedCaseInsensitiveCompare(label) == .orderedSame }) else { continue }
            labels.append(label)
            if labels.count == 2 { break }
        }
        return labels.isEmpty
            ? (shortCaption.isEmpty ? filename : shortCaption)
            : labels.joined(separator: " · ")
    }

    var cardDate: String? {
        guard let capturedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: capturedAt) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: capturedAt)?.formatted(date: .abbreviated, time: .omitted)
    }
}
