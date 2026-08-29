import Combine
import CoreGraphics
import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case streak, stats, settings

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .streak:   return "flame.fill"
        case .stats:    return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var title: String {
        switch self {
        case .streak:   return "Journey Streak"
        case .stats:    return "Statistics"
        case .settings: return "Settings"
        }
    }
}

/// Open/closed state of the island, shared between SwiftUI and the panel hosting it.
@MainActor
final class UIState: ObservableObject {
    /// Pointer is over the island body.
    @Published var isHovering = false
    /// Clicked open, so it stays open until dismissed.
    @Published var isPinned = false
    @Published var tab: PanelTab = .streak
    /// Set while a text field has focus so a stray pointer move cannot close the panel.
    @Published var isEditing = false

    var isExpanded: Bool { isHovering || isPinned || isEditing }

    var size: CGSize { isExpanded ? Theme.expandedSize : Theme.collapsedSize }

    func togglePin() {
        isPinned.toggle()
        if !isPinned {
            isHovering = false
            isEditing = false
        }
    }

    func collapse() {
        isPinned = false
        isHovering = false
        isEditing = false
    }
}
