import AppKit
import Carbon.HIToolbox
import CoreServices

/// Global keyboard shortcut via Carbon hot keys (needs no permission).
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4C504144), id: 1) // 'LPAD'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    static func display(for event: NSEvent) -> String {
        let flags = event.modifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = functionKeys[event.keyCode] ?? special[event.keyCode] {
            s += name
        } else {
            s += (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        return s
    }
}

/// Opens Launchpad when the pointer rests in a screen corner (F-11).
final class HotCornerMonitor {
    var corner: HotCorner = .none { didSet { if corner != oldValue { update() } } }
    var onTrigger: (() -> Void)?
    private var monitors: [Any] = []
    private var inCorner = false
    private var pending: DispatchWorkItem?

    private func update() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard corner != .none else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in self?.check() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in self?.check(); return e }) {
            monitors.append(l)
        }
    }

    private func isInCorner(_ p: NSPoint) -> Bool {
        let t: CGFloat = 3
        return NSScreen.screens.contains { s in
            let f = s.frame
            switch corner {
            case .none: return false
            case .topLeft: return p.x <= f.minX + t && p.y >= f.maxY - t
            case .topRight: return p.x >= f.maxX - t && p.y >= f.maxY - t
            case .bottomLeft: return p.x <= f.minX + t && p.y <= f.minY + t
            case .bottomRight: return p.x >= f.maxX - t && p.y <= f.minY + t
            }
        }
    }

    private func check() {
        let hit = isInCorner(NSEvent.mouseLocation)
        if hit, !inCorner {
            inCorner = true
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isInCorner(NSEvent.mouseLocation) else { return }
                self.onTrigger?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else if !hit, inCorner {
            inCorner = false
            pending?.cancel()
        }
    }
}

/// Thumb + three finger pinch on the trackpad (F-11), read from the private
/// MultitouchSupport framework (this build is not sandboxed).
final class PinchGestureMonitor {
    typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    static let shared = PinchGestureMonitor()
    var onPinchIn: (() -> Void)?
    var onPinchOut: (() -> Void)?
    private(set) var isAvailable = false
    private var devices: [UnsafeMutableRawPointer] = []
    private var running = false

    // Gesture state; only touched on the multitouch thread.
    private var startSpread: Float = 0
    private var fired = false

    private lazy var symbols: (CreateList, Register, Register, Start, Start)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(h, "MTDeviceCreateList"), let r = dlsym(h, "MTRegisterContactFrameCallback"),
              let u = dlsym(h, "MTUnregisterContactFrameCallback"), let s = dlsym(h, "MTDeviceStart"),
              let st = dlsym(h, "MTDeviceStop") else { return nil }
        return (unsafeBitCast(c, to: CreateList.self), unsafeBitCast(r, to: Register.self),
                unsafeBitCast(u, to: Register.self), unsafeBitCast(s, to: Start.self), unsafeBitCast(st, to: Start.self))
    }()

    private static let callback: ContactCallback = { _, data, count, _, _ in
        PinchGestureMonitor.shared.handle(data, Int(count))
        return 0
    }

    func start() {
        guard !running, let (createList, register, _, startDevice, _) = symbols,
              let list = createList()?.takeRetainedValue() else { isAvailable = false; return }
        devices = (0..<CFArrayGetCount(list)).compactMap { UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, $0)) }
        isAvailable = !devices.isEmpty
        for d in devices {
            register(d, Self.callback)
            startDevice(d, 0)
        }
        running = true
    }

    func stop() {
        guard running, let (_, _, unregister, _, stopDevice) = symbols else { return }
        for d in devices {
            unregister(d, Self.callback)
            stopDevice(d, 0)
        }
        devices = []
        running = false
    }

    /// Finger records are 96 bytes; normalized x/y floats sit at offsets 32/36.
    private func handle(_ data: UnsafeMutableRawPointer?, _ count: Int) {
        guard let data, count >= 4 else {
            startSpread = 0
            fired = false
            return
        }
        var xs: [Float] = [], ys: [Float] = []
        for i in 0..<count {
            let base = data + i * 96
            xs.append(base.load(fromByteOffset: 32, as: Float.self))
            ys.append(base.load(fromByteOffset: 36, as: Float.self))
        }
        let cx = xs.reduce(0, +) / Float(count), cy = ys.reduce(0, +) / Float(count)
        let spread = zip(xs, ys).map { hypotf($0 - cx, $1 - cy) }.reduce(0, +) / Float(count)
        if startSpread == 0 { startSpread = spread; return }
        guard !fired, startSpread > 0 else { return }
        if spread < startSpread * 0.6 {
            fired = true
            DispatchQueue.main.async { self.onPinchIn?() }
        } else if spread > startSpread * 1.45 {
            fired = true
            DispatchQueue.main.async { self.onPinchOut?() }
        }
    }
}

/// Watches application folders for installs and removals (F-08).
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init(paths: [String], handler: @escaping () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard let stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// App icons rasterized once at the display size, loaded off the main thread.
final class IconCache: ObservableObject {
    @Published private(set) var version = 0
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "launchpad.icons", qos: .userInitiated)
    private var publishScheduled = false
    private var generation = 0

    private(set) var pointSize: CGFloat = 88

    func setPointSize(_ size: CGFloat) {
        let bucket = (size / 16).rounded(.up) * 16
        guard bucket != pointSize else { return }
        pointSize = bucket
        generation += 1
        images.removeAll()
        loading.removeAll()
        version += 1
    }

    func image(for path: String) -> NSImage? {
        if let image = images[path] { return image }
        if loading.insert(path).inserted {
            let size = pointSize, gen = generation
            queue.async {
                let image = autoreleasepool { Self.render(path: path, pointSize: size) }
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.images[path] = image
                    self.loading.remove(path)
                    self.schedulePublish()
                }
            }
        }
        return nil
    }

    func prune(keeping paths: Set<String>) {
        images = images.filter { paths.contains($0.key) }
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.publishScheduled = false
            self.version += 1
        }
    }

    private static func render(path: String, pointSize: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let px = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
