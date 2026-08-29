import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = AppStore()
    private let ui = UIState()

    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var hitTestTimer: Timer?
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var bag = Set<AnyCancellable>()

    /// Slack around the island so its shadow is never clipped by the window.
    private let margin = CGSize(width: 90, height: 70)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        makeStatusItem()
        startHitTesting()
        watchForOutsideClicks()
        registerHotKeys()
        requestNotificationAccess()

        // Keep the menu-bar title in step with the countdown.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusTitle() }
            .store(in: &bag)

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

    // MARK: Panel

    private func makePanel() {
        let size = NSSize(width: Theme.expandedSize.width + margin.width * 2,
                          height: Theme.expandedSize.height + margin.height)
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size))

        let host = NSHostingView(rootView: IslandView(store: store, ui: ui)
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
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.maxY - size.height))
    }

    // MARK: Click-through

    /// The panel is far larger than the island so the shape can spring open without a
    /// window resize. Everything outside the island body therefore has to stay
    /// click-through: poll the pointer and swallow events only over the body itself.
    private func startHitTesting() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hitTestTimer = timer
    }

    private func updateClickThrough() {
        guard let panel else { return }
        let inside = islandRect().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        // Hover is decided here rather than by SwiftUI's .onHover. A pointer that lands
        // on the island in a single jump produces no further mouse-moved event while
        // the window is interactive, so .onHover would miss it entirely; and clicking
        // makes the panel key, which drops SwiftUI's hover state under the pointer.
        if ui.isHovering != inside {
            withAnimation(Theme.openSpring) { ui.isHovering = inside }
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

    private func islandRect() -> NSRect {
        let f = panel.frame
        let s = ui.size
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height,
                      width: s.width, height: s.height)
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
        button.title = store.isRunning ? " \(store.clockText)" : ""
    }

    @objc private func toggleTimer() { store.toggle() }
    @objc private func skipPhase()   { store.skip() }
    @objc private func resetPhase()  { store.reset() }
    @objc private func clearData()   { store.clearAllData() }
    @objc private func showIsland()  { panel.orderFrontRegardless() }
    @objc private func hideIsland()  { panel.orderOut(nil) }
    @objc private func openPanel() {
        panel.orderFrontRegardless()
        withAnimation(Theme.openSpring) { ui.isPinned = true }
    }
}

@MainActor
private func runPerch() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated { runPerch() }
