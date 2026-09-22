import SwiftUI
import AppKit

/// Hosts a SwiftUI view as a native titlebar accessory (chrome-free), on the
/// leading or trailing edge — so header icons sit on the traffic-light row.
final class HeaderAccessoryController: NSTitlebarAccessoryViewController {
    init(edge: NSLayoutConstraint.Attribute, width: CGFloat, content: AnyView) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = edge
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: Layout.accessoryHeight)
        view = hosting
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Leading accessory: the collapsible-sidebar toggle (right of the traffic lights).
struct LeadingAccessoryView: View {
    @Bindable var ui: UIState

    var body: some View {
        Group {
            if ui.leftSidebarVisible {
                IconButton(systemName: "rectangle.lefthalf.inset.filled",
                           tooltip: "Hide sidebar") {
                    ui.leftSidebarVisible = false
                }
                .padding(.leading, 6)
            }
        }
        .frame(width: Layout.leadingAccessoryWidth, height: Layout.accessoryHeight)
    }
}

/// Trailing accessory: the settings cog and the right-panel toggle (rightmost).
struct TrailingAccessoryView: View {
    @Bindable var ui: UIState
    let store: PhotoSearchStore

    var body: some View {
        Group {
            if panelVisible {
                HStack(spacing: 2) {
                    IconButton(systemName: "gearshape",
                               tooltip: "Open settings") {
                        ui.showSettings.toggle()
                    }
                    if !store.isViewerPresented {
                        IconButton(systemName: "rectangle.righthalf.inset.filled",
                                   tooltip: "Hide info") {
                            ui.rightSidebarVisible = false
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .frame(width: Layout.trailingAccessoryWidth, height: Layout.accessoryHeight)
    }

    private var panelVisible: Bool {
        store.isViewerPresented ? store.viewerInfoVisible : ui.rightSidebarVisible
    }
}
