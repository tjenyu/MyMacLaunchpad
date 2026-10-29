import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The full-screen launcher window (F-01, F-06). It is built once and only ordered in and out,
/// so opening it stays well under the 200 ms target.
final class LauncherWindowController {
    let panel: LauncherPanel
    private let controller: LauncherController
    private var monitors: [Any] = []
    private(set) var isVisible = false

    init(controller: LauncherController) {
        self.controller = controller
        panel = LauncherPanel(contentRect: NSScreen.main?.frame ?? .zero,
                              styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        // Above the Dock, menu bar and other apps' floating panels, like the original Launchpad,
        // but just below pop-up menus so right-click menus still appear on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        // Dark blur, glass and menus regardless of the system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: LauncherView(c: controller, settings: controller.settings, icons: controller.icons))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.frame { panel.setFrame(frame, display: false) }
        controller.refreshWallpaper(screen: screen)
        controller.viewSize = panel.frame.size
        controller.willShow()
        panel.alphaValue = 0
        NSApp.unhideWithoutActivation()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = controller.reduceMotion ? 0.1 : 0.26
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// `restoreFocus` hides the app so the previously active app gets focus back.
    func hide(restoreFocus: Bool) {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        controller.willHide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = controller.reduceMotion ? 0.08 : 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            if restoreFocus, !NSApp.windows.contains(where: { $0 !== self.panel && $0.isVisible && $0.canBecomeMain }) {
                NSApp.hide(nil)
            }
        })
    }

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.controller.handleKey(e) ? nil : e
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            self.controller.handleScroll(e)
            return nil
        }
        let rightClick = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            guard let self, e.window === self.panel, let view = self.panel.contentView else { return e }
            let p = CGPoint(x: e.locationInWindow.x, y: view.bounds.height - e.locationInWindow.y)
            self.controller.contextMenu(at: p)?.popUp(positioning: nil, at: e.locationInWindow, in: view)
            return nil
        }
        monitors = [keys, scroll, rightClick].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
