import Foundation

public struct AppInfo: Identifiable, Hashable, Sendable {
    public let path: String
    /// Localized name as Finder shows it (e.g. 計算機).
    public let name: String
    /// Non-localized bundle name (e.g. Calculator).
    public let englishName: String
    public let bundleID: String?
    /// LSApplicationCategoryType, e.g. public.app-category.productivity.
    public let category: String?
    public let search: SearchKeys

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    /// System apps (SIP-protected) cannot be moved to the Trash.
    public var isRemovable: Bool {
        !path.hasPrefix("/System/") && bundleID != "com.apple.Safari"
    }

    public init(path: String, name: String, englishName: String, bundleID: String?, category: String?) {
        self.path = path
        self.name = name
        self.englishName = englishName
        self.bundleID = bundleID
        self.category = category
        let fileName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        self.search = SearchKeys(names: [name, englishName, fileName])
    }
}

public enum AppScanner {
    /// /Applications (incl. Utilities and vendor subfolders), system apps and ~/Applications.
    public static var defaultRoots: [String] {
        ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    }

    public static func scan(roots: [String] = defaultRoots, excluding: Set<String> = []) -> [AppInfo] {
        var seen = Set<String>()
        var result: [AppInfo] = []
        for root in roots {
            walk(URL(fileURLWithPath: root), depth: 0) { url in
                let resolved = url.resolvingSymlinksInPath().path
                guard !excluding.contains(url.path), !excluding.contains(resolved),
                      seen.insert(resolved).inserted,
                      let info = info(at: url) else { return }
                result.append(info)
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func walk(_ dir: URL, depth: Int, found: (URL) -> Void) {
        guard depth <= 3,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return }
        for entry in entries {
            if entry.pathExtension == "app" {
                found(entry)
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                walk(entry, depth: depth + 1, found: found)
            }
        }
    }

    public static func info(at url: URL) -> AppInfo? {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // iOS apps on Apple Silicon have no Contents/Info.plist; they are still listed by name.
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let fileName = url.deletingPathExtension().lastPathComponent
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = fileName }
        let english = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleName"] as? String) ?? fileName
        return AppInfo(
            path: path,
            name: name,
            englishName: english.isEmpty ? fileName : english,
            bundleID: plist?["CFBundleIdentifier"] as? String,
            category: plist?["LSApplicationCategoryType"] as? String
        )
    }
}
