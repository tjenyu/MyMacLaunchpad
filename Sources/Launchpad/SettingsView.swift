import AppKit
import LaunchpadCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: LauncherController
    let hotKey: HotKeyManager

    var body: some View {
        TabView {
            GeneralSettings(settings: settings, hotKey: hotKey)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            AppearanceSettings(settings: settings)
                .tabItem { Label(L("Appearance"), systemImage: "square.grid.3x3") }
            GestureSettings(settings: settings)
                .tabItem { Label(L("Gestures"), systemImage: "hand.draw") }
            HiddenAppsSettings(controller: controller)
                .tabItem { Label(L("Hidden Apps"), systemImage: "eye.slash") }
            LayoutSettings(controller: controller)
                .tabItem { Label(L("Layout"), systemImage: "square.and.arrow.down") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    let hotKey: HotKeyManager
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent(L("Keyboard shortcut")) {
                HotKeyRecorder(settings: settings, hotKey: hotKey)
            }
            Toggle(L("Show icon in menu bar"), isOn: $settings.showStatusItem)
            Toggle(L("Open at login"), isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .formStyle(.grouped)
    }
}

private struct HotKeyRecorder: View {
    @ObservedObject var settings: AppSettings
    let hotKey: HotKeyManager
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? L("Type a shortcut…") : settings.hotKeyDisplay) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
            if hint {
                Text(L("Shortcuts need ⌘, ⌃ or ⌥, or a function key."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = HotKeyManager.functionKeys[e.keyCode] != nil
            guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else {
                hint = true
                NSSound.beep()
                return nil
            }
            hint = false
            settings.setHotKey(code: UInt32(e.keyCode), modifiers: HotKeyManager.carbonModifiers(flags),
                               display: HotKeyManager.display(for: e))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { hotKey.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) }
        recording = false
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Stepper("\(L("Rows")): \(settings.rows)", value: $settings.rows, in: 3...10)
            Stepper("\(L("Columns")): \(settings.columns)", value: $settings.columns, in: 4...14)
            LabeledContent(L("Icon size")) {
                Slider(value: $settings.iconSize, in: 56...160, step: 4)
                Text("\(Int(settings.iconSize))").monospacedDigit().frame(width: 34)
            }
            LabeledContent(L("Background blur")) {
                Slider(value: $settings.blurStrength, in: 0...1)
                Text("\(Int(settings.blurStrength * 100))%").monospacedDigit().frame(width: 40)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GestureSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(L("Pinch with thumb and three fingers"), isOn: $settings.pinchGesture)
                Text(L("Pinch in to open, spread out to close. Turn off the system gesture for Apps in System Settings › Trackpad › More Gestures to avoid conflicts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.pinchGesture, !PinchGestureMonitor.shared.isAvailable {
                    Text(L("Trackpad gestures are unavailable on this Mac."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(L("Open Trackpad Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                }
            }
            Section {
                Picker(L("Hot corner"), selection: $settings.hotCorner) {
                    ForEach(HotCorner.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HiddenAppsSettings: View {
    @ObservedObject var controller: LauncherController

    var body: some View {
        Form {
            Section {
                if controller.layout.hidden.isEmpty {
                    Text(L("No hidden apps.")).foregroundStyle(.secondary)
                }
                ForEach(controller.layout.hidden, id: \.self) { path in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(controller.name(for: path))
                        Spacer()
                        Button(L("Show")) { controller.unhide(path) }
                    }
                }
            } footer: {
                Text(L("Hidden apps stay installed; they just don’t appear in Launchpad."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutSettings: View {
    @ObservedObject var controller: LauncherController

    var body: some View {
        Form {
            Section {
                Text(L("Import the page and folder layout from the Launchpad of macOS 15 or earlier. To import from a Time Machine backup or an old Mac, choose its file at /private/var/folders/…/0/com.apple.dock.launchpad/db/db."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("Import from this Mac")) { LegacyImport.run(controller: controller, url: nil) }
                    Button(L("Import from a File…")) { LegacyImport.chooseFile(controller: controller) }
                }
            }
            Section {
                Button(L("Reset to Alphabetical")) {
                    guard LegacyImport.confirmReplace() else { return }
                    controller.replaceLayout(.alphabetical(controller.sortedApps, capacity: controller.capacity,
                                                           hidden: controller.layout.hidden))
                    LegacyImport.inform(L("Layout reset."), nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// F-09: import the pre-Tahoe Launchpad database.
enum LegacyImport {
    static func chooseFile(controller: LauncherController) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(controller: controller, url: url)
    }

    static func run(controller: LauncherController, url: URL?) {
        guard let url = url ?? LegacyImporter.defaultDatabaseURL else {
            inform(L("Import Failed"), L("No old Launchpad database was found on this Mac."))
            return
        }
        do {
            let pages = try LegacyImporter.read(databaseAt: url)
            guard confirmReplace() else { return }
            let result = LegacyImporter.makeLayout(from: pages, installed: controller.sortedApps,
                                                   capacity: controller.capacity, hidden: controller.layout.hidden)
            controller.replaceLayout(result.layout)
            var detail = L("Imported %d apps and %d folders.", result.importedApps, result.importedFolders)
            if result.missingApps > 0 { detail += "\n" + L("%d apps from the old layout are no longer installed.", result.missingApps) }
            inform(L("Import Complete"), detail)
        } catch {
            inform(L("Import Failed"), error.localizedDescription)
        }
    }

    static func confirmReplace() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Replace the current layout?")
        alert.informativeText = L("Your current pages and folders will be replaced.")
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func inform(_ title: String, _ message: String?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.runModal()
    }
}
