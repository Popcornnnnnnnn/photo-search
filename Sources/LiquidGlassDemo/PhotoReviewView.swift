import SwiftUI

struct PhotoReviewView: View {
    @Environment(ThemeStore.self) private var theme
    @State private var store = PhotoReviewStore()
    @State private var viewer = PhotoSearchStore()
    @State private var pendingDeletion: [PhotoReviewCandidate]?
    let encoder: PhotoEncoderStore
    let thumbnailContentMode: ContentMode
    let inspectorWidth: CGFloat
    let onClose: () -> Void
    let onLocate: (RandomBrowsePhoto) -> Void
    let onDeleted: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if viewer.isViewerPresented {
                    PhotoOneUpView(store: viewer, infoVisible: $viewer.viewerInfoVisible)
                } else {
                    filters
                    gridContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                actionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if store.selected != nil && (!viewer.isViewerPresented || viewer.viewerInfoVisible) {
                SidebarTint()
                    .frame(width: inspectorWidth)
                    .overlay {
                        VStack(alignment: .leading, spacing: 0) {
                            if let candidate = store.selected {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(candidate.reason.title).font(.headline)
                                    Text(candidate.reason.explanation)
                                        .font(.callout).foregroundStyle(theme.textSecondary)
                                }.padding(20)
                                Rectangle().fill(theme.divider).frame(height: Layout.hairline)
                                PhotoInspector(store: viewer, showsThumbnail: !viewer.isViewerPresented)
                            } else {
                                Spacer()
                            }
                        }
                    }
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.divider).frame(width: Layout.hairline)
                    }
            }
        }
        .foregroundStyle(theme.textPrimary)
        .background(theme.background)
        .disabled(store.isDeleting)
        .toolbar { reviewToolbar }
        .alert(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { candidates in
            Button(candidates.count == 1 ? "Delete Photo" : "Delete \(candidates.count) Photos", role: .destructive) {
                Task {
                    if await store.delete(candidates) {
                        synchronizeViewer()
                        onDeleted()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidates in
            Text("\(candidates.count == 1 ? candidates[0].photo.filename : "Only these \(candidates.count) marked photos will be deleted. Kept photos are excluded.")\n\nThis deletes the selected originals from your Photos library. With iCloud Photos, it is also deleted from synced devices. You can normally recover it in Photos → Recently Deleted for 30 days.")
        }
        .alert("Photo deletion", isPresented: Binding(
            get: { store.deletionMessage != nil },
            set: { if !$0 { store.deletionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.deletionMessage = nil }
        } message: {
            Text(store.deletionMessage ?? "")
        }
        .onChange(of: store.filter) { _, _ in
            store.selectFirstIfNeeded()
            synchronizeViewer()
        }
        .onChange(of: viewer.selectedID) { _, id in store.selectedID = id }
        .onChange(of: viewer.isViewerPresented) { _, presented in
            if presented { viewer.viewerInfoVisible = true }
        }
        .task { await refresh(selectInitialFilter: true) }
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.count ?? 0
        return count > 1 ? "Delete all \(count) marked photos from Apple Photos?" : "Delete this photo from Apple Photos?"
    }

    @ViewBuilder
    private var gridContent: some View {
        if let error = store.error {
            ContentUnavailableView("Review unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if store.isLoading && viewer.photos.isEmpty {
            ProgressView("Checking photos…")
        } else if viewer.photos.isEmpty {
            ContentUnavailableView {
                Label(store.filter == .marked ? "No photos marked for deletion" : "Nothing here to review",
                      systemImage: "checkmark.rectangle.stack")
            } description: {
                Text(store.filter == .keep ? "Photos you keep will appear here." : "There are no photos in this list.")
            } actions: {
                if store.filter != .marked, store.count(.marked) > 0 {
                    Button("Review \(store.count(.marked)) marked photos") { store.filter = .marked }
                        .buttonStyle(HoverButtonStyle())
                }
            }
        } else {
            PhotoGrid(store: viewer, encoder: encoder, thumbnailContentMode: thumbnailContentMode) {
                viewer.selectedID = $0.id
            }
        }
    }

    @ToolbarContentBuilder
    private var reviewToolbar: some ToolbarContent {
        if !viewer.isViewerPresented {
            ToolbarItem(placement: .navigation) {
                ViewerBackButton(tooltip: "Back to Library (Esc)", action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(store.isDeleting)
            }
            ToolbarItem(placement: .principal) {
                Text("Review photos").font(.headline)
            }
            ToolbarItem(placement: .primaryAction) {
                ViewerToolbarButton(systemImage: "arrow.clockwise", tooltip: "Refresh suggestions") {
                    Task { await refresh() }
                }.disabled(store.isLoading || store.isDeleting)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(PhotoReviewDecision.allCases) { decision in
                Button {
                    store.filter = decision
                } label: {
                    Text("\(decision.title) · \(store.count(decision))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(store.filter == decision ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(store.filter == decision ? theme.selectionFill : .clear,
                                    in: .rect(cornerRadius: Radius.row))
                }
                .buttonStyle(HoverButtonStyle(horizontalPadding: 0, verticalPadding: 0, cornerRadius: Radius.row))
                .accessibilityAddTraits(store.filter == decision ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if store.filter == .marked, !store.markedCandidates.isEmpty {
                Button("Delete all \(store.markedCandidates.count)…", systemImage: "trash", role: .destructive) {
                    pendingDeletion = store.markedCandidates
                }
                .buttonStyle(HoverButtonStyle())
                .font(.caption.weight(.medium))
                .controlSize(.small)
                .tint(.red)
                .disabled(!store.markedCandidates.allSatisfy(\.canDeleteFromPhotos))
                .help("Delete all marked photos in one batch. Kept photos are excluded.")
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.divider).frame(height: Layout.hairline)
            HStack(spacing: 14) {
                if let candidate = store.selected {
                    if store.filter != .keep {
                        Button("Keep", systemImage: "checkmark") {
                            store.mark(candidate, as: .keep)
                            synchronizeViewer()
                        }
                    } else {
                        Button("Review again", systemImage: "arrow.uturn.backward") {
                            store.mark(candidate, as: .pending)
                            synchronizeViewer()
                        }
                    }
                    if store.filter == .pending {
                        Button("Mark for deletion", systemImage: "bookmark") {
                            store.mark(candidate, as: .marked)
                            synchronizeViewer()
                        }
                    }
                    if store.filter == .marked {
                        Button("Undo mark", systemImage: "arrow.uturn.backward") {
                            store.mark(candidate, as: .pending)
                            synchronizeViewer()
                        }
                    }
                    Button("Delete photo…", systemImage: "trash", role: .destructive) {
                        pendingDeletion = [candidate]
                    }
                    .foregroundStyle(candidate.canDeleteFromPhotos ? .red : theme.textSecondary)
                    .disabled(!candidate.canDeleteFromPhotos)
                    .help(candidate.canDeleteFromPhotos ? "Delete the original from Apple Photos" : "No verified Apple Photos original")
                    Spacer(minLength: 0)
                    if store.isDeleting {
                        ProgressView().controlSize(.small)
                        Text("Deleting…").font(.caption)
                    } else {
                        ViewerToolbarButton(systemImage: "calendar", tooltip: "Locate in Library") {
                            let photo = candidate.photo
                            onLocate(RandomBrowsePhoto(id: photo.id, path: candidate.previewPath, fallbackPath: nil,
                                                       filename: photo.filename, capturedAt: photo.capturedAt,
                                                       assetType: photo.assetType, shortCaption: photo.shortCaption))
                        }
                    }
                } else {
                    Text("\(store.checkedCount.formatted()) indexed descriptions checked")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
            }
            .buttonStyle(HoverButtonStyle())
            .font(.callout)
            .padding(.horizontal, 20)
            .frame(height: 46)
        }
    }

    private func refresh(selectInitialFilter: Bool = false) async {
        await store.load(selectInitialFilter: selectInitialFilter)
        synchronizeViewer()
    }

    private func synchronizeViewer() {
        viewer.photos = store.visibleCandidates.map(\.photo)
        viewer.selectedID = store.selectedID
        if viewer.photos.isEmpty { viewer.closeViewer() }
    }
}
