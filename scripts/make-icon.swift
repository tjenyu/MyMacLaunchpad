// Draws the app icon into an .iconset folder: a glass tile holding a 3×3 grid of colorful app tiles.
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)

    // macOS icon grid: 824/1024 body with a soft drop shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset + s * 0.01, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    color(0x1B1F4B).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deep night-sky gradient.
    NSGradient(colors: [color(0x2A2F7A), color(0x4B2C8F), color(0x8A3FA8)])!.draw(in: shape, angle: -70)

    // Grid of colorful tiles.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let tiles: [(UInt32, UInt32)] = [
        (0xFF6B6B, 0xE03A5C), (0xFFB347, 0xF57C1F), (0xFFE066, 0xF2B807),
        (0x5EE38A, 0x1FB45A), (0x4FD1FF, 0x1C8CF0), (0x6E7BFF, 0x4049E8),
        (0xC77DFF, 0x9442E8), (0xFF7EC8, 0xE0479E), (0xF2F4F8, 0xC9CED9),
    ]
    let gridInset = body.width * 0.16
    let grid = body.insetBy(dx: gridInset, dy: gridInset)
    let cell = grid.width / 3
    let tile = cell * 0.74
    for row in 0..<3 {
        for col in 0..<3 {
            let (top, bottom) = tiles[(2 - row) * 3 + col]
            let r = NSRect(x: grid.minX + CGFloat(col) * cell + (cell - tile) / 2,
                           y: grid.minY + CGFloat(row) * cell + (cell - tile) / 2, width: tile, height: tile)
            let path = NSBezierPath(roundedRect: r, xRadius: tile * 0.26, yRadius: tile * 0.26)
            NSGraphicsContext.saveGraphicsState()
            let ts = NSShadow()
            ts.shadowColor = .black.withAlphaComponent(0.3)
            ts.shadowBlurRadius = tile * 0.12
            ts.shadowOffset = NSSize(width: 0, height: -tile * 0.06)
            ts.set()
            color(bottom).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: color(top), ending: color(bottom))!.draw(in: path, angle: -90)
            // Small gloss on each tile.
            let gloss = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2),
                                     xRadius: tile * 0.26, yRadius: tile * 0.26)
            color(0xFFFFFF, 0.18).setFill()
            gloss.fill()
        }
    }

    // Liquid-glass style sheen across the top and a thin rim light.
    let sheen = NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.2, y: body.midY + body.height * 0.05,
                                            width: body.width * 1.4, height: body.height * 0.9))
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0.0)])!.draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.003, dy: s * 0.003), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, s * 0.006)
    color(0xFFFFFF, 0.35).setStroke()
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
