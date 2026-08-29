import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// `--demo` parks a seeded island off the bottom of the screen so its layout can be
    /// captured for review without disturbing anything the user is looking at.
    private let isDemo = CommandLine.arguments.contains("--demo")
        || CommandLine.arguments.contains("--shoot")
    private lazy var store = AppStore(persists: !isDemo)
    private let ui = UIState()
    private let monitor = SystemMonitor()

    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var hitTestTimer: Timer?
    private var lastPointer = CGPoint(x: -1, y: -1)
    private var lastIslandSize = CGSize.zero
    private var lastAlignment: IslandAlignment = .center
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var keyMonitor: Any?
    private var menuBarLoadSubscribed = false
    private var bag = Set<AnyCancellable>()

    /// Slack around the island so its shadow is never clipped by the window.
    private let margin = CGSize(width: 90, height: 70)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if isDemo { store.seedDemoContent() }
        makePanel()
        if isDemo {
            ui.isPinned = true
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.frame.minX,
                                             y: screen.frame.minY - panel.frame.height - 40))
            }
            if let index = CommandLine.arguments.firstIndex(of: "--shoot") {
                let directory = CommandLine.arguments.count > index + 1
                    ? CommandLine.arguments[index + 1] : "."
                startShooting(into: directory)
            }
            return
        }
        makeStatusItem()
        startHitTesting()
        watchForOutsideClicks()
        watchForKeys()
        registerHotKeys()
        requestNotificationAccess()

        // Keep the menu-bar title in step with the countdown.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncMenuBarLoad()
                self.refreshStatusTitle()
                if self.store.settings.alignment != self.lastAlignment { self.reposition() }
            }
            .store(in: &bag)

        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &bag)

        syncMenuBarLoad()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    // MARK: Offscreen capture

    /// Walks the island through its states and writes each one to a PNG by asking the
    /// hosting view to draw itself. The window stays parked off the bottom of the
    /// screen throughout, so nothing the user is looking at changes and the pointer is
    /// never touched — and unlike `ImageRenderer`, this captures the real AppKit-backed
    /// controls (fields, menus, scroll views).
    private func startShooting(into directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var steps: [(String, () -> Void)] = [
            ("11-tasks-streak", { self.ui.tab = .streak }),
            ("12-tasks-stats", { self.ui.tab = .stats }),
            ("13-tasks-system", { self.ui.tab = .system }),
            ("14-tasks-settings", { self.ui.tab = .settings }),
            ("15-group-collapsed", {
                self.ui.tab = .streak
                if let first = self.store.groups.first { self.store.toggleGroup(first.id) }
            }),
            ("16-search", {
                if let first = self.store.groups.first { self.store.toggleGroup(first.id) }
                self.store.search = "client"
            }),
            ("17-filter-done", {
                self.store.search = ""
                self.store.toggleDone(self.store.tasks[1].id)
            }),
            ("18-running", {
                self.store.start()
            }),
            ("19-collapsed", {
                self.store.pause()
                self.ui.isPinned = false
            })
        ]

        func next(_ delay: Double) {
            guard !steps.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
                return
            }
            let (name, mutate) = steps.removeFirst()
            mutate()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.capture(name: name, into: folder)
                next(0.7)
            }
        }
        next(1.2)
    }

    private func capture(name: String, into folder: URL) {
        guard let host = panel.contentView else { return }
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        print("  ✓ \(name).png")
    }

    // MARK: Panel

    private func makePanel() {
        let size = NSSize(width: Theme.expandedSize.width + margin.width * 2,
                          height: Theme.expandedSize.height + margin.height)
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size))

        let host = NSHostingView(rootView: IslandView(store: store, ui: ui, monitor: monitor)
            .padding(.horizontal, margin.width))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let x: CGFloat
        switch store.settings.alignment {
        case .leading:  x = screen.frame.minX
        case .center:   x = screen.frame.midX - size.width / 2
        case .trailing: x = screen.frame.maxX - size.width
        }
        panel.setFrameOrigin(NSPoint(x: x, y: screen.frame.maxY - size.height))
        lastAlignment = store.settings.alignment
    }

    // MARK: Click-through

    /// The panel is far larger than the island so the shape can spring open without a
    /// window resize, which means everything outside the island body has to stay
    /// click-through.
    ///
    /// This polls the pointer rather than watching mouse-moved events: macOS only
    /// delivers those to applications that ask for them, so a global monitor silently
    /// misses the pointer crossing another app's window. The poll is made almost free by
    /// bailing out the moment it sees the pointer has not actually moved — a still
    /// pointer cannot change the answer.
    private func startHitTesting() {
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hitTestTimer = timer
    }

    private func updateClickThrough() {
        guard let panel else { return }

        let pointer = NSEvent.mouseLocation
        // Nothing moved and nothing resized: there is no work to do.
        if pointer == lastPointer, ui.size == lastIslandSize { return }
        lastPointer = pointer
        lastIslandSize = ui.size

        let inside = islandRect().contains(pointer)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            // The pointer is already inside when the panel becomes interactive, so
            // AppKit delivers no mouseEntered and every hover-revealed control stays
            // hidden until the pointer happens to move again. Nudge it.
            if inside { synthesizeMouseMoved(at: pointer) }
        }
        // Hover is decided here rather than by SwiftUI's .onHover. A pointer that lands
        // on the island in a single jump produces no further mouse-moved event while
        // the window is interactive, so .onHover would miss it entirely; and clicking
        // makes the panel key, which drops SwiftUI's hover state under the pointer.
        if ui.isHovering != inside {
            withAnimation(Theme.openSpring) { ui.isHovering = inside }
        }
    }

    /// Escape closes the panel. This one is local rather than a registered hot key
    /// because Escape belongs to whatever is focused, and the panel is key exactly when
    /// the user is looking at it.
    private func watchForKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Read what is needed here: NSEvent cannot cross into the isolated closure.
            let isEscape = event.keyCode == 53
            let handled = MainActor.assumeIsolated { () -> Bool in
                if isEscape {
                    withAnimation(Theme.openSpring) { self.ui.collapse() }
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    /// The CPU readout only samples while it is actually on the menu bar.
    private func syncMenuBarLoad() {
        let wanted = store.settings.showLoadInMenuBar
        if wanted, !menuBarLoadSubscribed {
            monitor.subscribe()
            menuBarLoadSubscribed = true
        } else if !wanted, menuBarLoadSubscribed {
            monitor.unsubscribe()
            menuBarLoadSubscribed = false
        }
    }

    /// Popover semantics. Clicking the island pins it open; clicking anywhere else
    /// dismisses it. This lives in event monitors rather than a SwiftUI tap gesture
    /// because buttons inside the panel consume taps before the container sees them —
    /// and the click makes the panel key, which drops SwiftUI's hover state.
    private func watchForOutsideClicks() {
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.islandRect().contains(NSEvent.mouseLocation) {
                    withAnimation(Theme.openSpring) { self.ui.isPinned = true }
                }
            }
            return event
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ui.isPinned else { return }
                if !self.islandRect().contains(NSEvent.mouseLocation) {
                    withAnimation(Theme.openSpring) { self.ui.collapse() }
                }
            }
        }
    }

    private func synthesizeMouseMoved(at pointer: CGPoint) {
        guard let panel else { return }
        let local = panel.convertPoint(fromScreen: pointer)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved,
                                             location: local,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 0,
                                             pressure: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func islandRect() -> NSRect {
        let f = panel.frame
        let s = ui.size
        let x: CGFloat
        switch store.settings.alignment {
        case .leading:  x = f.minX + margin.width
        case .center:   x = f.midX - s.width / 2
        case .trailing: x = f.maxX - margin.width - s.width
        }
        return NSRect(x: x, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    // MARK: Hot keys

    private func registerHotKeys() {
        let mods = UInt32(controlKey | optionKey)
        HotKeyCenter.shared.register(key: kVK_Space, modifiers: mods) { [weak self] in
            guard let self else { return }
            withAnimation(Theme.openSpring) { self.ui.togglePin() }
        }
        HotKeyCenter.shared.register(key: kVK_ANSI_P, modifiers: mods) { [weak self] in
            self?.store.toggle()
        }
        HotKeyCenter.shared.register(key: kVK_ANSI_S, modifiers: mods) { [weak self] in
            self?.store.skip()
        }
        HotKeyCenter.shared.register(key: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.store.reset()
        }
        HotKeyCenter.shared.register(key: kVK_ANSI_N, modifiers: mods) { [weak self] in
            guard let self else { return }
            // A non-activating panel will not take key focus on its own, so a hot key
            // that wants the caret has to activate the app first.
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            withAnimation(Theme.openSpring) { self.ui.isPinned = true }
            self.ui.wantsAddFocus = true
        }
    }

    private func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusTitle()

        let menu = NSMenu()
        menu.addItem(item("Start / Pause", #selector(toggleTimer), "p"))
        menu.addItem(item("Skip Phase", #selector(skipPhase), "s"))
        menu.addItem(item("Reset Phase", #selector(resetPhase), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Open Panel", #selector(openPanel), " "))
        menu.addItem(item("Show Island", #selector(showIsland), ""))
        menu.addItem(item("Hide Island", #selector(hideIsland), ""))
        menu.addItem(.separator())
        menu.addItem(item("Export Data…", #selector(exportData), ""))
        menu.addItem(item("Reveal Data Folder", #selector(revealData), ""))
        menu.addItem(item("Clear All Data", #selector(clearData), ""))
        menu.addItem(withTitle: "Quit Perch",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: store.phase.symbol,
                               accessibilityDescription: "Perch")
        button.imagePosition = .imageLeading
        if store.isRunning {
            button.title = " \(store.clockText)"
        } else if store.settings.showLoadInMenuBar {
            button.title = String(format: " %.0f%%", monitor.cpu.value * 100)
        } else {
            button.title = ""
        }
    }

    @objc private func toggleTimer() { store.toggle() }
    @objc private func skipPhase()   { store.skip() }
    @objc private func resetPhase()  { store.reset() }
    @objc private func clearData()   { store.clearAllData() }

    @objc private func exportData() {
        store.save()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "perch-backup.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: Persistence.fileURL, to: destination)
        } catch {
            NSLog("Perch: export failed — \(error.localizedDescription)")
        }
    }

    @objc private func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([Persistence.fileURL])
    }
    @objc private func showIsland()  { panel.orderFrontRegardless() }
    @objc private func hideIsland()  { panel.orderOut(nil) }
    @objc private func openPanel() {
        panel.orderFrontRegardless()
        withAnimation(Theme.openSpring) { ui.isPinned = true }
    }
}

@MainActor
private func runPerch() {
    // Headless modes used by the test harness. Neither shows a window, touches the
    // pointer, nor reads or writes the real state file.
    if CommandLine.arguments.contains("--selftest") {
        exit(SelfTest.run())
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render") {
        let directory = CommandLine.arguments.count > index + 1
            ? CommandLine.arguments[index + 1] : "."
        exit(PreviewRenderer.run(into: directory))
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated { runPerch() }
