import Carbon.HIToolbox
import Foundation

enum HotCorner: String, CaseIterable, Identifiable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("None")
        case .topLeft: return L("Top Left")
        case .topRight: return L("Top Right")
        case .bottomLeft: return L("Bottom Left")
        case .bottomRight: return L("Bottom Right")
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var rows: Int { didSet { defaults.set(rows, forKey: "rows") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "columns") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }
    @Published var blurStrength: Double { didSet { defaults.set(blurStrength, forKey: "blurStrength") } }
    @Published var showStatusItem: Bool { didSet { defaults.set(showStatusItem, forKey: "showStatusItem") } }
    @Published var hotCorner: HotCorner { didSet { defaults.set(hotCorner.rawValue, forKey: "hotCorner") } }
    @Published var pinchGesture: Bool { didSet { defaults.set(pinchGesture, forKey: "pinchGesture") } }
    @Published private(set) var hotKeyCode: UInt32
    @Published private(set) var hotKeyModifiers: UInt32
    @Published private(set) var hotKeyDisplay: String

    var capacity: Int { rows * columns }

    init() {
        defaults.register(defaults: [
            "rows": 5, "columns": 7, "iconSize": 108.0, "blurStrength": 1.0, "showStatusItem": true,
            "hotCorner": HotCorner.none.rawValue, "pinchGesture": false,
            "hotKeyCode": kVK_ANSI_L, "hotKeyModifiers": cmdKey | controlKey, "hotKeyDisplay": "⌃⌘L",
        ])
        rows = defaults.integer(forKey: "rows")
        columns = defaults.integer(forKey: "columns")
        iconSize = defaults.double(forKey: "iconSize")
        blurStrength = defaults.double(forKey: "blurStrength")
        showStatusItem = defaults.bool(forKey: "showStatusItem")
        hotCorner = HotCorner(rawValue: defaults.string(forKey: "hotCorner") ?? "") ?? .none
        pinchGesture = defaults.bool(forKey: "pinchGesture")
        hotKeyCode = UInt32(defaults.integer(forKey: "hotKeyCode"))
        hotKeyModifiers = UInt32(defaults.integer(forKey: "hotKeyModifiers"))
        hotKeyDisplay = defaults.string(forKey: "hotKeyDisplay") ?? ""
    }

    func setHotKey(code: UInt32, modifiers: UInt32, display: String) {
        hotKeyCode = code
        hotKeyModifiers = modifiers
        hotKeyDisplay = display
        defaults.set(Int(code), forKey: "hotKeyCode")
        defaults.set(Int(modifiers), forKey: "hotKeyModifiers")
        defaults.set(display, forKey: "hotKeyDisplay")
    }
}
