import AppKit
import Combine
import LaunchpadCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let icons = IconCache()
    let hotKey = HotKeyManager()
    let hotCorner = HotCornerMonitor()
    private(set) var controller: LauncherController!
    private var launcher: LauncherWindowController!
    private var statusItem: NSStatusItem?
    private var watcher: FSWatcher?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        controller = LauncherController(settings: settings, icons: icons)
        icons.setPointSize(controller.metrics.iconSize)
        controller.onHide = { [weak self] in self?.launcher.hide(restoreFocus: true) }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        launcher = LauncherWindowController(controller: controller)
        controller.refreshWallpaper(screen: NSScreen.main)

        controller.rescan(initial: true)
        watcher = FSWatcher(paths: AppScanner.defaultRoots) { [weak self] in self?.controller.rescan() }

        // F-07 / F-11 entry points.
        hotKey.onPress = { [weak self] in self?.toggle() }
        hotCorner.onTrigger = { [weak self] in self?.show() }
        PinchGestureMonitor.shared.onPinchIn = { [weak self] in self?.show() }
        PinchGestureMonitor.shared.onPinchOut = { [weak self] in self?.launcher.hide(restoreFocus: true) }
        observeSettings()

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.launcher.hide(restoreFocus: false)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.pinchGesture else { return }
            PinchGestureMonitor.shared.stop()
            PinchGestureMonitor.shared.start()
        }

        if !launchedAsLoginItem { show() }
    }

    /// Clicking the Dock icon toggles the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func show() {
        settingsWindow?.orderOut(nil)
        launcher.show()
    }

    func toggle() {
        launcher.isVisible ? launcher.hide(restoreFocus: true) : show()
    }

    // MARK: Settings

    private func observeSettings() {
        settings.$hotKeyCode.combineLatest(settings.$hotKeyModifiers)
            .sink { [weak self] code, mods in self?.hotKey.register(keyCode: code, modifiers: mods) }
            .store(in: &cancellables)
        settings.$showStatusItem.removeDuplicates()
            .sink { [weak self] show in self?.updateStatusItem(show) }
            .store(in: &cancellables)
        settings.$hotCorner
            .sink { [weak self] corner in self?.hotCorner.corner = corner }
            .store(in: &cancellables)
        settings.$blurStrength.dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.controller.refreshWallpaper(screen: NSScreen.main) }
            .store(in: &cancellables)
        settings.$pinchGesture.removeDuplicates()
            .sink { on in on ? PinchGestureMonitor.shared.start() : PinchGestureMonitor.shared.stop() }
            .store(in: &cancellables)
        // F-12: grid changes reflow the pages; icon size changes re-render icons once the slider settles.
        Publishers.CombineLatest3(settings.$rows, settings.$columns, settings.$iconSize)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.controller.capacityChanged() }
            .store(in: &cancellables)
    }

    private func updateStatusItem(_ show: Bool) {
        guard show else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Launchpad")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("Open Launchpad")) { [weak self] in self?.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Import Old Launchpad Layout…")) { [weak self] in
            guard let self else { return }
            NSApp.activate()
            LegacyImport.run(controller: self.controller, url: nil)
        })
        menu.addItem(ClosureMenuItem(title: L("Settings…")) { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Quit Launchpad")) { NSApp.terminate(nil) })
        item.menu = menu
        statusItem = item
    }

    @objc func openSettings() {
        launcher.hide(restoreFocus: false)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, controller: controller, hotKey: hotKey))
            let window = NSWindow(contentViewController: host)
            window.title = L("Settings…").replacingOccurrences(of: "…", with: "")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Launchpad"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Launchpad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
