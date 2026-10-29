import Foundation

/// One cell on a page: an app (identified by its bundle path) or a folder.
public enum LayoutItem: Codable, Equatable, Identifiable, Sendable {
    case app(String)
    case folder(Folder)

    public var id: String {
        switch self {
        case .app(let path): return path
        case .folder(let folder): return folder.id
        }
    }

    public var appPaths: [String] {
        switch self {
        case .app(let path): return [path]
        case .folder(let folder): return folder.apps
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// Folder contents are a flat list; the UI pages it by the folder grid capacity.
public struct Folder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var apps: [String]

    public init(id: String = UUID().uuidString, name: String, apps: [String]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

public struct Layout: Codable, Equatable, Sendable {
    public var pages: [[LayoutItem]]
    /// Apps the user hid (F-14). They stay installed but are kept out of `pages`.
    public var hidden: [String]

    public init(pages: [[LayoutItem]] = [[]], hidden: [String] = []) {
        self.pages = pages.isEmpty ? [[]] : pages
        self.hidden = hidden
    }

    public static func alphabetical(_ apps: [AppInfo], capacity: Int, hidden: [String] = []) -> Layout {
        let hiddenSet = Set(hidden)
        let items = apps.filter { !hiddenSet.contains($0.path) }.map { LayoutItem.app($0.path) }
        var layout = Layout(pages: chunk(items, capacity), hidden: hidden)
        layout.normalize(capacity: capacity)
        return layout
    }

    public var allAppPaths: [String] {
        pages.flatMap { $0.flatMap(\.appPaths) }
    }

    public func folderLocation(id: String) -> (page: Int, index: Int)? {
        for (p, page) in pages.enumerated() {
            if let i = page.firstIndex(where: { $0.id == id && $0.isFolder }) { return (p, i) }
        }
        return nil
    }

    public func folder(id: String) -> Folder? {
        guard let loc = folderLocation(id: id), case .folder(let f) = pages[loc.page][loc.index] else { return nil }
        return f
    }

    public mutating func updateFolder(id: String, _ body: (inout Folder) -> Void) {
        guard let loc = folderLocation(id: id), case .folder(var f) = pages[loc.page][loc.index] else { return }
        body(&f)
        pages[loc.page][loc.index] = .folder(f)
    }

    /// Removes an app wherever it sits (page or folder).
    public mutating func remove(appPath: String) {
        for p in pages.indices {
            pages[p] = pages[p].compactMap { item in
                switch item {
                case .app(let path): return path == appPath ? nil : item
                case .folder(var f):
                    f.apps.removeAll { $0 == appPath }
                    return .folder(f)
                }
            }
        }
    }

    /// Replaces a folder by its apps, in place.
    public mutating func dissolveFolder(id: String, capacity: Int) {
        guard let loc = folderLocation(id: id), case .folder(let f) = pages[loc.page][loc.index] else { return }
        pages[loc.page].replaceSubrange(loc.index...loc.index, with: f.apps.map { .app($0) })
        normalize(capacity: capacity)
    }

    /// Dissolves folders with fewer than two apps, pushes page overflow onto the next page,
    /// drops empty pages and duplicate apps.
    public mutating func normalize(capacity: Int) {
        let capacity = max(1, capacity)
        var seen = Set<String>()
        for p in pages.indices {
            pages[p] = pages[p].compactMap { item in
                switch item {
                case .app(let path):
                    return seen.insert(path).inserted ? item : nil
                case .folder(var f):
                    f.apps = f.apps.filter { seen.insert($0).inserted }
                    if f.apps.isEmpty { return nil }
                    if f.apps.count == 1 { return .app(f.apps[0]) }
                    return .folder(f)
                }
            }
        }
        var i = 0
        while i < pages.count {
            if pages[i].count > capacity {
                let overflow = Array(pages[i][capacity...])
                pages[i].removeSubrange(capacity...)
                if i + 1 < pages.count {
                    pages[i + 1].insert(contentsOf: overflow, at: 0)
                } else {
                    pages.append(overflow)
                }
            }
            i += 1
        }
        pages.removeAll { $0.isEmpty }
        if pages.isEmpty { pages = [[]] }
    }

    /// Syncs the layout with what is installed (F-08): removed apps disappear,
    /// new apps go to the end of the last page.
    public mutating func reconcile(installed: [AppInfo], capacity: Int) {
        let installedSet = Set(installed.map(\.path))
        hidden = hidden.filter { installedSet.contains($0) }
        let hiddenSet = Set(hidden)
        let keep: (String) -> Bool = { installedSet.contains($0) && !hiddenSet.contains($0) }
        for p in pages.indices {
            pages[p] = pages[p].compactMap { item in
                switch item {
                case .app(let path): return keep(path) ? item : nil
                case .folder(var f):
                    f.apps = f.apps.filter(keep)
                    return .folder(f)
                }
            }
        }
        let present = Set(allAppPaths)
        let newItems = installed.filter { keep($0.path) && !present.contains($0.path) }.map { LayoutItem.app($0.path) }
        if !newItems.isEmpty {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(contentsOf: newItems)
        }
        normalize(capacity: capacity)
    }

    static func chunk<T>(_ items: [T], _ size: Int) -> [[T]] {
        let size = max(1, size)
        guard !items.isEmpty else { return [[]] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

public extension Array {
    func chunked(_ size: Int) -> [[Element]] { Layout.chunk(self, size) }
}

/// Persists the layout as JSON in Application Support. Everything stays on this Mac.
public struct LayoutStore {
    public let url: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Launchpad", isDirectory: true)
        url = base.appendingPathComponent("layout.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() -> Layout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    public func save(_ layout: Layout) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
    }
}
