import Foundation
import SQLite3

/// Reads the pre-Tahoe Launchpad database (F-09):
/// `$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db`.
///
/// items.type: 1 root, 2 folder, 3 page, 4 app. Pages hang off ROOTPAGE,
/// apps and folders hang off pages, folders hold their own pages of apps.
public enum LegacyImporter {
    public struct App: Equatable, Sendable {
        public var title: String
        public var bundleID: String?
        public var bookmark: Data?
    }

    public enum Entry: Equatable, Sendable {
        case app(App)
        case folder(title: String, apps: [App])
    }

    public struct Result: Sendable {
        public var layout: Layout
        public var importedApps: Int
        public var importedFolders: Int
        public var missingApps: Int
    }

    public enum ImportError: LocalizedError {
        case notFound
        case unreadable(String)
        case noRootPage

        public var errorDescription: String? {
            switch self {
            case .notFound: return "Launchpad database not found."
            case .unreadable(let msg): return "Could not read the Launchpad database: \(msg)"
            case .noRootPage: return "The file is not a Launchpad database."
            }
        }
    }

    public static var defaultDatabaseURL: URL? {
        let len = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        confstr(_CS_DARWIN_USER_DIR, &buf, len)
        let url = URL(fileURLWithPath: String(cString: buf))
            .appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Reads pages in order. Works on a temporary copy so the original (and its WAL) is never touched.
    public static func read(databaseAt url: URL) throws -> [[Entry]] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.notFound }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("launchpad-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("db")
        try FileManager.default.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        struct Item { var id: Int64; var uuid: String; var type: Int; var parent: Int64; var ordering: Int }
        var items: [Item] = []
        try query(db, "SELECT rowid, uuid, type, parent_id, ordering FROM items") { s in
            items.append(Item(id: sqlite3_column_int64(s, 0), uuid: text(s, 1) ?? "", type: Int(sqlite3_column_int(s, 2)),
                              parent: sqlite3_column_int64(s, 3), ordering: Int(sqlite3_column_int(s, 4))))
        }
        var apps: [Int64: App] = [:]
        try query(db, "SELECT item_id, title, bundleid, bookmark FROM apps") { s in
            var bookmark: Data?
            if let bytes = sqlite3_column_blob(s, 3) {
                bookmark = Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 3)))
            }
            apps[sqlite3_column_int64(s, 0)] = App(title: text(s, 1) ?? "", bundleID: text(s, 2), bookmark: bookmark)
        }
        var groups: [Int64: String] = [:]
        try query(db, "SELECT item_id, title FROM groups") { s in
            groups[sqlite3_column_int64(s, 0)] = text(s, 1) ?? ""
        }

        let children = Dictionary(grouping: items, by: \.parent).mapValues { $0.sorted { $0.ordering < $1.ordering } }
        guard let root = items.first(where: { $0.uuid == "ROOTPAGE" }) else { throw ImportError.noRootPage }

        let pages = (children[root.id] ?? []).filter { $0.type == 3 && $0.uuid != "HOLDINGPAGE" }
        return pages.map { page in
            (children[page.id] ?? []).compactMap { item -> Entry? in
                switch item.type {
                case 4:
                    return apps[item.id].map(Entry.app)
                case 2:
                    let folderApps = (children[item.id] ?? []).filter { $0.type == 3 }
                        .flatMap { children[$0.id] ?? [] }
                        .compactMap { apps[$0.id] }
                    return .folder(title: groups[item.id] ?? "", apps: folderApps)
                default:
                    return nil
                }
            }
        }.filter { !$0.isEmpty }
    }

    /// Maps legacy entries onto installed apps; anything installed but missing is appended (F-08).
    public static func makeLayout(from pages: [[Entry]], installed: [AppInfo], capacity: Int, hidden: [String] = []) -> Result {
        let installedPaths = Set(installed.map(\.path))
        var byBundle: [String: String] = [:]
        var byName: [String: String] = [:]
        for app in installed {
            if let b = app.bundleID, byBundle[b] == nil { byBundle[b] = app.path }
            for n in [app.name, app.englishName] where byName[n.lowercased()] == nil { byName[n.lowercased()] = app.path }
        }
        var used = Set<String>()
        var missing = 0
        func resolve(_ app: App) -> String? {
            var path: String?
            if let data = app.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
                   installedPaths.contains(url.standardizedFileURL.path) {
                    path = url.standardizedFileURL.path
                }
            }
            if path == nil, let b = app.bundleID { path = byBundle[b] }
            if path == nil { path = byName[app.title.lowercased()] }
            guard let p = path, used.insert(p).inserted else {
                if path == nil { missing += 1 }
                return nil
            }
            return p
        }

        var appCount = 0
        var folderCount = 0
        let layoutPages: [[LayoutItem]] = pages.map { entries in
            entries.compactMap { entry in
                switch entry {
                case .app(let app):
                    guard let p = resolve(app) else { return nil }
                    appCount += 1
                    return .app(p)
                case .folder(let title, let apps):
                    let paths = apps.compactMap(resolve)
                    appCount += paths.count
                    if paths.count > 1 { folderCount += 1 }
                    return .folder(Folder(name: title, apps: paths))
                }
            }
        }
        var layout = Layout(pages: layoutPages, hidden: hidden)
        layout.reconcile(installed: installed, capacity: capacity)
        return Result(layout: layout, importedApps: appCount, importedFolders: folderCount, missingApps: missing)
    }

    private static func text(_ s: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(s, col).map { String(cString: $0) }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
