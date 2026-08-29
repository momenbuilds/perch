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
        || CommandLine.arguments.contains("--record")
    private lazy var store = AppStore(persists: !isDemo)
    private let ui = UIState()
    private let monitor = SystemMonitor()

    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var hitTestTimer: Timer?
    private var lastPointer = CGPoint(x: -1, y: -1)
    private var lastIslandSize = CGSize.zero
    private var lastAlignment: IslandAlignment = .center
    private var statusMenu: NSMenu?
    private var addFocusObserver: NSObjectProtocol?
    private var shrinkWork: DispatchWorkItem?
    private var lastHidden = false
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
            // Nothing resizes the window in this mode, so give it the full panel size up
            // front — otherwise the island is drawn clipped and the capture comes out
            // empty.
            let size = panelSize(expanded: true)
            if let screen = NSScreen.main {
                // On screen, but at the back of the stack: window capture needs a window
                // that is actually on a display, and sitting behind everything means the
                // user never sees it and nothing of theirs is ever in frame.
                panel.level = .normal
                panel.setFrame(NSRect(x: screen.frame.minX,
                                      y: screen.frame.minY,
                                      width: size.width, height: size.height),
                               display: true)
                panel.orderBack(nil)
            }
            if let index = CommandLine.arguments.firstIndex(of: "--record") {
                let directory = CommandLine.arguments.count > index + 1
                    ? CommandLine.arguments[index + 1] : "frames"
                startRecording(into: directory)
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
                if self.store.settings.isIslandHidden != self.lastHidden {
                    self.lastHidden = self.store.settings.isIslandHidden
                    self.applyIslandVisibility()
                }
            }
            .store(in: &bag)

        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &bag)

        ui.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanelSize() }
            .store(in: &bag)

        // The countdown lives apart from the store so it cannot rebuild the task list
        // every second; the menu-bar title still needs it.
        store.ticker.objectWillChange
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

    // MARK: Offscreen recording

    /// Drives the island through a scripted demo and writes one PNG per frame, by
    /// asking the hosting view to draw itself.
    ///
    /// The window stays parked off the bottom of the screen throughout, so nothing on
    /// screen changes, the pointer is never touched, and everything outside the island
    /// is transparent rather than a picture of somebody's desktop. The script is keyed
    /// to frame numbers rather than the clock: encoding a frame costs more than the
    /// frame budget, so a wall-clock script would race ahead of the capture.
    private func startRecording(into directory: String) {
        Theme.captureMode = true
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        ui.isPinned = false
        store.select(store.tasks[0].id)

        let script: [Int: () -> Void] = [
            4:  { withAnimation(Theme.openSpring) { self.ui.isPinned = true } },
            10: { withAnimation(Theme.snappy) { self.store.toggleDone(self.store.tasks[5].id) } },
            13: { withAnimation(Theme.snappy) { self.store.togglePriority(self.store.tasks[3].id) } },
            16: { withAnimation(Theme.snappy) { self.store.toggleGroup(self.store.groups[1].id) } },
            19: { withAnimation(Theme.snappy) { self.store.toggleGroup(self.store.groups[1].id) } },
            22: { withAnimation(Theme.snappy) { self.ui.tab = .stats } },
            28: { withAnimation(Theme.snappy) { self.ui.tab = .system } },
            33: { self.monitor.subscribeProcessesForDemo() },
            40: { withAnimation(Theme.snappy) { self.ui.tab = .settings } },
            43: { withAnimation(Theme.snappy) { self.store.settings.accentIndex = 4 } },
            45: { withAnimation(Theme.snappy) { self.store.settings.accentIndex = 5 } },
            47: { withAnimation(Theme.snappy) { self.store.settings.accentIndex = 0 } },
            50: { withAnimation(Theme.snappy) { self.ui.tab = .streak } },
            54: { self.store.select(self.store.tasks[0].id); self.store.start() },
            57: { withAnimation(Theme.openSpring) { self.ui.collapse() } }
        ]
        let total = 63

        var frame = 0
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                script[frame]?()
                self.writeFrame(index: frame, into: folder)
                frame += 1
                if frame % 10 == 0 { NSLog("PBREC %d/%d", frame, total) }
                if frame >= total {
                    timer.invalidate()
                    print("wrote \(frame) frames to \(folder.path)")
                    exit(0)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The island, cropped out of the hosting view and scaled down before encoding —
    /// a full-size PNG per frame costs more than the frame budget allows.
    /// Asks the system to capture our own window.
    ///
    /// Rendering the layer tree by hand takes seconds a frame — the CPU rasteriser has
    /// to redo the whole SwiftUI graph — whereas the window server already has this
    /// window composited and can hand it over in a fraction of that. Only our window is
    /// in the image, so nothing of the user's screen is ever captured.
    private func writeFrame(index: Int, into folder: URL) {
        let url = folder.appendingPathComponent(String(format: "f%04d.png", index))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(panel.windowNumber)", url.path]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: Panel

    /// The window is only ever as big as the island needs, because it is transparent and
    /// always on top: every point of it is blended by the window server on every frame
    /// drawn beneath it. Collapsed, that is a 404-point pill rather than a 872-point
    /// panel — about an eighth of the area to composite.
    private func panelSize(expanded: Bool) -> NSSize {
        let island = expanded ? Theme.expandedSize : Theme.collapsedSize
        return NSSize(width: island.width + margin.width * 2,
                      height: island.height + margin.height)
    }

    private func makePanel() {
        let size = panelSize(expanded: false)
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size))

        let host = NSHostingView(rootView: IslandView(store: store, ui: ui, monitor: monitor)
            .padding(.horizontal, margin.width))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        reposition()
        lastHidden = store.settings.isIslandHidden
        if !store.settings.isIslandHidden { panel.orderFrontRegardless() }
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        applyPanelFrame(expanded: ui.isExpanded, screen: screen)
        lastAlignment = store.settings.alignment
    }

    private func applyPanelFrame(expanded: Bool, screen: NSScreen? = nil) {
        guard let panel,
              let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panelSize(expanded: expanded)
        let x: CGFloat
        switch store.settings.alignment {
        case .leading:  x = screen.frame.minX
        case .center:   x = screen.frame.midX - size.width / 2
        case .trailing: x = screen.frame.maxX - size.width
        }
        let frame = NSRect(x: x, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    /// Grow before the island opens so nothing is clipped; shrink only once it has
    /// finished closing.
    private func syncPanelSize() {
        guard panel != nil else { return }
        shrinkWork?.cancel()
        if ui.isExpanded {
            applyPanelFrame(expanded: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.ui.isExpanded else { return }
                self.applyPanelFrame(expanded: false)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
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
        guard let panel, !store.settings.isIslandHidden else { return }

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
        // Belt and braces: the window should never sit at panel size while the island
        // is only showing the pill.
        syncPanelSize()
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
            if self.store.settings.isIslandHidden { self.toggleIslandHidden() }
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
        // Reachable even over a full-screen app, where the menu bar itself is hidden.
        HotKeyCenter.shared.register(key: kVK_ANSI_H, modifiers: mods) { [weak self] in
            self?.toggleIslandHidden()
        }
        HotKeyCenter.shared.register(key: kVK_ANSI_N, modifiers: mods) { [weak self] in
            guard let self else { return }
            // A non-activating panel will not take key focus on its own, so a hot key
            // that wants the caret has to activate the app first.
            if self.store.settings.isIslandHidden { self.toggleIslandHidden() }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            withAnimation(Theme.openSpring) { self.ui.isPinned = true }
            self.requestAddFocus()
        }
    }

    /// Asking for the caret before the panel is key silently does nothing — SwiftUI
    /// records the focus and AppKit then hands the responder chain elsewhere as the app
    /// finishes activating. So wait for the window to actually become key, then ask.
    private func requestAddFocus() {
        guard let panel else { return }
        if panel.isKeyWindow {
            ui.wantsAddFocus = true
            return
        }
        if let existing = addFocusObserver {
            NotificationCenter.default.removeObserver(existing)
            addFocusObserver = nil
        }
        addFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.addFocusObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.addFocusObserver = nil
                }
                self.ui.wantsAddFocus = true
            }
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

        // Left click tucks the island away and brings it back — the island covers the
        // middle of the menu bar, so there has to be a one-click way to get rid of it.
        // Right click opens the menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshStatusTitle()

        let menu = NSMenu()
        menu.addItem(item("Show / Hide Island", #selector(toggleIslandHidden), ""))
        menu.addItem(.separator())
        menu.addItem(item("Start / Pause", #selector(toggleTimer), "p"))
        menu.addItem(item("Skip Phase", #selector(skipPhase), "s"))
        menu.addItem(item("Reset Phase", #selector(resetPhase), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Open Panel", #selector(openPanel), " "))
        menu.addItem(.separator())
        menu.addItem(item("Export Data…", #selector(exportData), ""))
        menu.addItem(item("Reveal Data Folder", #selector(revealData), ""))
        menu.addItem(item("Clear All Data", #selector(clearData), ""))
        menu.addItem(withTitle: "Quit Perch",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            guard let menu = statusMenu, let button = statusItem.button else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        } else {
            toggleIslandHidden()
        }
    }

    @objc private func toggleIslandHidden() {
        store.settings.isIslandHidden.toggle()
        applyIslandVisibility()
    }

    private func applyIslandVisibility() {
        guard let panel else { return }
        if store.settings.isIslandHidden {
            ui.collapse()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        refreshStatusTitle()
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        let symbol = store.settings.isIslandHidden ? "eye.slash" : store.phase.symbol
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Perch")
        button.toolTip = store.settings.isIslandHidden
            ? "Perch — click to show the island"
            : "Perch — click to hide the island, right-click for more" 
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
