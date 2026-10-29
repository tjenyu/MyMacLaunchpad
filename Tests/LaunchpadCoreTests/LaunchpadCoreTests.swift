import Foundation
import SQLite3
import Testing
@testable import LaunchpadCore

private func app(_ name: String, english: String? = nil, bundle: String? = nil) -> AppInfo {
    AppInfo(path: "/Applications/\(english ?? name).app", name: name, englishName: english ?? name, bundleID: bundle, category: nil)
}

@Suite struct SearchTests {
    let music = app("音樂", english: "Music")
    let calc = app("計算機", english: "Calculator")
    let qt = app("QuickTime Player")

    @Test func matchesLocalizedAndEnglishNames() {
        #expect(music.search.score("音") == 0)
        #expect(music.search.score("music") == 0)
        #expect(qt.search.score("player") == 2)
        #expect(qt.search.score("QUICK") == 0)
    }

    @Test func matchesPinyinAndInitials() {
        #expect(music.search.score("yl") == 1)
        #expect(music.search.score("yinle") == 1)
        #expect(calc.search.score("jsj") == 1)
        #expect(qt.search.score("qp") == 1)
    }

    @Test func matchesZhuyinInitialsAndKeys() {
        #expect(music.search.score("ㄧㄌ") == 1)
        #expect(calc.search.score("ㄐㄙㄐ") == 1)
        // ㄐ=r ㄙ=n on the standard zhuyin keyboard.
        #expect(calc.search.score("rnr") == 1)
    }

    @Test func rejectsNonMatches() {
        #expect(music.search.score("xyz") == nil)
        #expect(music.search.score("") == nil)
    }

    @Test func ordersByScore() {
        let results = Search.filter([qt, music, calc], query: "m")
        #expect(results.first == music)
    }
}

@Suite struct LayoutTests {
    @Test func normalizeReflowsAndDissolves() {
        var layout = Layout(pages: [
            [.app("a"), .app("b"), .app("c")],
            [.folder(Folder(name: "F", apps: ["d"])), .folder(Folder(name: "E", apps: []))],
            [],
        ])
        layout.normalize(capacity: 2)
        #expect(layout.pages == [[.app("a"), .app("b")], [.app("c"), .app("d")]])
    }

    @Test func reconcileRemovesAndAppendsApps() {
        let a = app("A"), b = app("B"), c = app("C")
        var layout = Layout(pages: [[.app(a.path), .folder(Folder(name: "F", apps: [b.path, "/gone.app"]))]])
        layout.reconcile(installed: [a, b, c], capacity: 2)
        #expect(layout.pages == [[.app(a.path), .app(b.path)], [.app(c.path)]])
    }

    @Test func hiddenAppsStayOut() {
        let a = app("A"), b = app("B")
        var layout = Layout(pages: [[.app(a.path)]], hidden: [b.path])
        layout.reconcile(installed: [a, b], capacity: 10)
        #expect(layout.allAppPaths == [a.path])
        #expect(layout.hidden == [b.path])
    }

    @Test func storeRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let layout = Layout(pages: [[.app("x"), .folder(Folder(id: "f", name: "F", apps: ["y", "z"]))]], hidden: ["h"])
        try store.save(layout)
        #expect(store.load() == layout)
    }
}

@Suite struct LegacyImporterTests {
    /// Builds a minimal database with the same schema the old Dock used.
    func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        INSERT INTO items VALUES (1,'ROOTPAGE',0,1,0,0),(2,'HOLDINGPAGE',0,3,1,0),(10,'p1',0,3,1,1),(11,'p2',0,3,1,2);
        INSERT INTO items VALUES (20,'a',0,4,10,1),(21,'f',0,2,10,0),(22,'fp',0,3,21,0),(23,'b',0,4,22,0),(24,'c',0,4,22,1);
        INSERT INTO items VALUES (25,'gone',0,4,11,0),(26,'d',0,4,11,1),(27,'held',0,4,2,0);
        INSERT INTO apps VALUES (20,'A','com.a',NULL,0,0,NULL),(23,'B','com.b',NULL,0,0,NULL),(24,'C','com.c',NULL,0,0,NULL);
        INSERT INTO apps VALUES (25,'Gone','com.gone',NULL,0,0,NULL),(26,'D',NULL,NULL,0,0,NULL),(27,'Held','com.held',NULL,0,0,NULL);
        INSERT INTO groups VALUES (21,0,'工具');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func readsPagesAndFolders() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let pages = try LegacyImporter.read(databaseAt: url)
        #expect(pages.count == 2)
        guard case .folder(let title, let apps) = pages[0][0] else { Issue.record("expected folder first"); return }
        #expect(title == "工具")
        #expect(apps.map(\.title) == ["B", "C"])
    }

    @Test func mapsToInstalledApps() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = app("A", bundle: "com.a"), b = app("B", bundle: "com.b"), c = app("C", bundle: "com.c")
        let d = app("D"), e = app("E", bundle: "com.e")
        let result = LegacyImporter.makeLayout(from: try LegacyImporter.read(databaseAt: url),
                                               installed: [a, b, c, d, e], capacity: 10)
        #expect(result.importedFolders == 1)
        #expect(result.missingApps == 1)
        guard case .folder(let f) = result.layout.pages[0][0] else { Issue.record("expected folder"); return }
        #expect(f.apps == [b.path, c.path])
        // Page 2's D plus the never-seen E are appended after page 1, then reflowed onto one page.
        #expect(result.layout.allAppPaths == [b.path, c.path, a.path, d.path, e.path])
    }
}
