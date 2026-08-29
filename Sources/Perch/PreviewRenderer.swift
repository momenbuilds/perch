import AppKit
import SwiftUI

/// Renders the island's states to PNGs offscreen, with `Perch --render <directory>`.
///
/// Nothing is shown on screen and the pointer is never touched, so the layout of every
/// pane can be reviewed without driving the live app. Uses an in-memory store, so the
/// real state file is untouched.
@MainActor
enum PreviewRenderer {

    static func run(into directory: String) -> Int32 {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = populatedStore()
        let monitor = SystemMonitor()
        monitor.sample()
        monitor.subscribeProcesses()
        Thread.sleep(forTimeInterval: 0.5)
        monitor.sample()

        var written = 0

        func shoot(_ name: String, configure: (UIState) -> Void) {
            let ui = UIState()
            configure(ui)
            let size = ui.size
            let view = IslandView(store: store, ui: ui, monitor: monitor)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.10))

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("  ✗ \(name)")
                return
            }
            let url = folder.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            written += 1
            print("  ✓ \(name).png  \(Int(size.width))×\(Int(size.height))")
        }

        print("Rendering island states into \(folder.path)")

        shoot("01-collapsed-idle") { _ in }

        store.select(store.tasks[0].id)
        store.start()
        store.remaining = store.phaseLength * 0.45
        shoot("02-collapsed-focus") { _ in }

        store.switchTo(.shortBreak)
        store.remaining = store.phaseLength * 0.7
        shoot("03-collapsed-break") { _ in }

        store.switchTo(.focus)
        store.remaining = store.phaseLength * 0.35
        shoot("04-expanded-streak") { $0.isPinned = true; $0.tab = .streak }
        shoot("05-expanded-stats") { $0.isPinned = true; $0.tab = .stats }
        shoot("06-expanded-system") { $0.isPinned = true; $0.tab = .system }
        shoot("07-expanded-settings") { $0.isPinned = true; $0.tab = .settings }

        // A collapsed group, to check the list keeps its shape.
        if let first = store.groups.first {
            store.toggleGroup(first.id)
            shoot("08-group-collapsed") { $0.isPinned = true; $0.tab = .streak }
            store.toggleGroup(first.id)
        }

        store.search = "invoice"
        shoot("09-search") { $0.isPinned = true; $0.tab = .streak }
        store.search = ""

        let empty = AppStore(persists: false)
        let emptyUI = UIState()
        emptyUI.isPinned = true
        let emptyView = IslandView(store: empty, ui: emptyUI, monitor: monitor)
            .frame(width: emptyUI.size.width, height: emptyUI.size.height)
            .background(Color(white: 0.10))
        let renderer = ImageRenderer(content: emptyView)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("10-empty.png"))
            written += 1
            print("  ✓ 10-empty.png")
        }

        monitor.unsubscribeProcesses()
        print("\n\(written) images written")
        return written > 0 ? 0 : 1
    }

    /// A believable working set: two groups, a loose task, some history.
    private static func populatedStore() -> AppStore {
        let store = AppStore(persists: false)

        let client = store.addGroup("Client work")
        let study = store.addGroup("Study")

        store.addTask("Draft the Q3 proposal", note: "Two pages, no fluff",
                      estimate: 4, groupID: client?.id)
        store.addTask("Invoice the client", note: "Net 14", estimate: 1, groupID: client?.id)
        store.addTask("Client call prep", estimate: 2, groupID: client?.id)
        store.addTask("Study SwiftUI layout", note: "Chapter 4", estimate: 3, groupID: study?.id)
        store.addTask("Read the concurrency guide", estimate: 2, groupID: study?.id)
        store.addTask("Review pull requests", note: "Three open", estimate: 2)
        store.addTask("Write release notes", estimate: 1)
        store.addTask("Plan next sprint", estimate: 2)

        store.togglePriority(store.tasks[0].id)
        store.toggleDone(store.tasks[6].id)
        store.tasks[0].completed = 2

        // Some finished sessions so the streak, stats and log have something to draw.
        let calendar = Calendar.current
        for offset in [0, 1, 2, 4, 5, 9, 12, 13, 14, 20, 27] {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let sessions = (offset % 3) + 1
            store.seedForPreview(day: day, sessions: sessions,
                                 title: store.tasks[offset % store.tasks.count].title)
        }
        return store
    }
}
