import AppKit
import SwiftUI

/// A menu that costs nothing until it is opened.
///
/// SwiftUI's `Menu` builds an AppKit menu host for every instance, which is fine for one
/// or two but not for one per row of a long list — with seventy tasks on screen it made
/// the whole panel drag. This builds a plain `NSMenu` at click time instead.
enum RowMenu {

    struct Entry {
        let title: String
        let isSeparator: Bool
        let isDestructive: Bool
        let action: () -> Void

        init(_ title: String, destructive: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.isSeparator = false
            self.isDestructive = destructive
            self.action = action
        }

        static var separator: Entry {
            Entry(isSeparator: true)
        }

        private init(isSeparator: Bool) {
            self.title = ""
            self.isSeparator = true
            self.isDestructive = false
            self.action = {}
        }
    }

    /// Pops the menu up under the pointer. Blocks until the user picks or dismisses,
    /// which keeps the target alive for exactly as long as it is needed.
    @MainActor
    static func present(_ entries: [Entry]) {
        let target = Target(entries)
        let menu = NSMenu()
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title,
                                  action: #selector(Target.fire(_:)),
                                  keyEquivalent: "")
            item.tag = index
            item.target = target
            if entry.isDestructive {
                item.attributedTitle = NSAttributedString(
                    string: entry.title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            menu.addItem(item)
        }

        let location = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: location.x, y: location.y),
                       in: nil)
            _ = screen
        }
    }

    private final class Target: NSObject {
        private let entries: [Entry]
        init(_ entries: [Entry]) { self.entries = entries }

        @objc func fire(_ sender: NSMenuItem) {
            guard entries.indices.contains(sender.tag) else { return }
            entries[sender.tag].action()
        }
    }
}
