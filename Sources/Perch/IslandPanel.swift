import AppKit
import SwiftUI

/// Borderless panel that floats above the menu bar and hosts the island.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // The panel has to be able to take key focus on demand — the "new task" hot key
        // opens it and puts the caret straight into the field.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Hover-revealed controls depend on mouse-moved events reaching the window.
        acceptsMouseMovedEvents = true
        // Above the menu bar so the island reads as part of the bezel, and above a
        // full-screen app's window so it does not vanish when you zoom something.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
    }
}
