import AppKit
import CoreImage

/// Blurs the desktop picture itself, keeping its colors, as the original Launchpad did.
/// The system behind-window blur washes colors out to grey, so it is only the fallback
/// (e.g. for video wallpapers, which have no still image).
enum WallpaperRenderer {
    private static let context = CIContext()

    static func render(url: URL, screenSize: CGSize, strength: Double) -> NSImage? {
        guard var image = CIImage(contentsOf: url), screenSize.width > 0, screenSize.height > 0 else { return nil }
        // Rendered small: a heavy blur needs no detail, and it keeps memory low.
        let width: CGFloat = 1280, height = width * screenSize.height / screenSize.width
        let scale = max(width / image.extent.width, height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: image.extent.midX - width / 2, y: image.extent.midY - height / 2, width: width, height: height)
        var out = image.clampedToExtent()
        let sigma = 40 * strength
        if sigma > 0.5 { out = out.applyingGaussianBlur(sigma: sigma) }
        out = out.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 + 0.35 * strength,
            kCIInputBrightnessKey: -0.03,
        ])
        guard let cg = context.createCGImage(out.cropped(to: crop), from: crop) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}

extension LauncherController {
    func refreshWallpaper(screen: NSScreen?) {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallpaper = nil
            return
        }
        let strength = settings.blurStrength
        let size = screen.frame.size
        let key = "\(url.path)|\(size.width)x\(size.height)|\(Int(strength * 20))"
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        DispatchQueue.global(qos: .userInitiated).async {
            let image = WallpaperRenderer.render(url: url, screenSize: size, strength: strength)
            DispatchQueue.main.async {
                guard key == self.wallpaperKey else { return }
                self.wallpaper = image
            }
        }
    }
}
