import AppKit
import LaunchpadCore
import SwiftUI

enum DragContext: Equatable {
    case main
    case folder(String)
}

enum HoverCandidate: Equatable {
    case none
    case gap(Int)
    case merge(String)
}

struct DragState {
    var item: LayoutItem
    var location: CGPoint
    var grabOffset: CGSize
    var context: DragContext
    /// Page of `context` the gap lives on (main pages only; folder gaps are global indices).
    var page: Int
    var gapIndex: Int?
    var mergeTargetID: String?
    var hover: HoverCandidate = .none
    var hoverSince = Date()
    var edgeSince: Date?
    var outsideSince: Date?
    /// After a spring-loaded open the pointer is usually outside the panel; leaving only counts
    /// once it has been inside, or after it lingers outside.
    var exitArmed = true
    var origin: (context: DragContext, page: Int, index: Int)

    var iconCenter: CGPoint { CGPoint(x: location.x - grabOffset.width, y: location.y - grabOffset.height) }
}

struct Selection: Equatable {
    var page: Int
    var index: Int
}

enum HitResult {
    case item(context: DragContext, page: Int, index: Int, item: LayoutItem, iconCenter: CGPoint)
    case deleteBadge(String)
    case searchResult(Int)
    case folderPanel
    case background
}

struct RenderedItem: Identifiable {
    let id: String
    let item: LayoutItem
    let iconCenter: CGPoint
    var selected = false
    var mergeTarget = false
    var visible = true
}

/// All launcher state and interaction logic. Views render from it; the window forwards events to it.
final class LauncherController: ObservableObject {
    let settings: AppSettings
    let icons: IconCache
    private let store = LayoutStore()

    @Published private(set) var apps: [String: AppInfo] = [:]
    @Published var layout = LaunchpadCore.Layout()
    @Published var currentPage = 0
    @Published var scrollOffset: CGFloat = 0
    @Published var openFolderID: String?
    @Published var folderPage = 0
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var results: [AppInfo] = []
    @Published var searchPage = 0
    @Published var selection: Selection?
    @Published var editMode = false
    @Published private(set) var drag: DragState?
    @Published var pendingTrash: AppInfo?
    @Published var alertMessage: String?
    @Published var appeared = false
    @Published var focusSearchToken = 0
    @Published var focusFolderNameToken = 0
    /// Where the open folder's icon sits; the folder zooms out of and back into this point.
    @Published private(set) var folderOrigin: CGPoint = .zero
    @Published var wallpaper: NSImage?
    var wallpaperKey = ""

    var isEditingFolderName = false
    var viewSize: CGSize = CGSize(width: 1440, height: 900)
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var press: (start: CGPoint, hit: HitResult, longPressed: Bool, scrolling: Bool)?
    private var longPressWork: DispatchWorkItem?
    private var dragTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var scanWork: DispatchWorkItem?
    private var scanning = false
    private var lastWheelEvent = Date.distantPast
    private var trackpadScrolling = false
    @Published private(set) var isSettling = false
    /// The item just dropped; it replaces the settled ghost in place instead of fading in.
    private(set) var lastDroppedID: String?

    init(settings: AppSettings, icons: IconCache) {
        self.settings = settings
        self.icons = icons
        if let saved = store.load() { layout = saved }
    }

    // MARK: Derived state

    var capacity: Int { settings.capacity }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var animation: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }
    /// Page flips glide rather than snap.
    var pageAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.62, dampingFraction: 0.9) }
    /// Icons making room for a dragged app move slowly enough to follow, with a little overshoot.
    var reorderAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.72) }
    var folderAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.82) }
    /// Closing (including dragging an app out) runs 0.1 s longer than opening.
    var folderCloseAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.82) }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var openFolder: Folder? { openFolderID.flatMap { layout.folder(id: $0) } }

    func metrics(for size: CGSize) -> GridMetrics {
        GridMetrics(size: size, rows: settings.rows, cols: settings.columns, preferredIconSize: settings.iconSize)
    }

    var metrics: GridMetrics { metrics(for: viewSize) }
    func folderGeometry(for size: CGSize) -> FolderGeometry { FolderGeometry(size: size, main: metrics(for: size)) }
    var folderGeometry: FolderGeometry { folderGeometry(for: viewSize) }

    var searchPages: [[AppInfo]] { results.chunked(capacity) }

    func folderPages(_ folder: Folder) -> [[String]] { folder.apps.chunked(folderGeometry.grid.capacity) }

    /// Page count and current page of whatever is showing: an open folder, search results or the main grid.
    var contextPageCount: Int {
        if let f = openFolder { return folderPages(f).count }
        if isSearching { return searchPages.count }
        return layout.pages.count
    }

    var contextPage: Int {
        get { openFolder != nil ? folderPage : isSearching ? searchPage : currentPage }
        set {
            if openFolder != nil { folderPage = newValue } else if isSearching { searchPage = newValue } else { currentPage = newValue }
        }
    }

    var contextPageWidth: CGFloat { openFolder != nil ? folderGeometry.panel.width : viewSize.width }

    func name(for path: String) -> String { apps[path]?.name ?? (path as NSString).lastPathComponent }

    // MARK: Apps and persistence

    func rescan(initial: Bool = false) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performScan(initial: initial) }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (initial ? 0 : 0.5), execute: work)
    }

    private func performScan(initial: Bool) {
        guard !scanning else { rescan(); return }
        scanning = true
        let exclude: Set<String> = [Bundle.main.bundlePath]
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppScanner.scan(excluding: exclude)
            DispatchQueue.main.async {
                self.scanning = false
                self.apply(scanned: found, initial: initial)
            }
        }
    }

    private func apply(scanned: [AppInfo], initial: Bool) {
        apps = Dictionary(scanned.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        if initial, !store.exists {
            // First run: rebuild the old Launchpad layout when this Mac still has it, else alphabetical.
            if let url = LegacyImporter.defaultDatabaseURL, let pages = try? LegacyImporter.read(databaseAt: url),
               !pages.isEmpty {
                layout = LegacyImporter.makeLayout(from: pages, installed: scanned, capacity: capacity).layout
            } else {
                layout = .alphabetical(scanned, capacity: capacity)
            }
        } else if drag == nil {
            layout.reconcile(installed: scanned, capacity: capacity)
        }
        clampPages()
        refreshResults()
        icons.prune(keeping: Set(apps.keys))
        for path in apps.keys { _ = icons.image(for: path) }
        save()
    }

    /// Orders apps by name, the same way new layouts are built.
    var sortedApps: [AppInfo] {
        apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save() {
        saveWork?.cancel()
        let snapshot = layout
        let work = DispatchWorkItem { [store] in try? store.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func replaceLayout(_ new: LaunchpadCore.Layout) {
        withAnimation(animation) {
            layout = new
            openFolderID = nil
            currentPage = 0
            normalize()
        }
        save()
    }

    func capacityChanged() {
        withAnimation(animation) { normalize() }
        icons.setPointSize(metrics.iconSize)
        save()
    }

    private func normalize() {
        layout.normalize(capacity: capacity)
        clampPages()
    }

    private func clampPages() {
        currentPage = min(max(0, currentPage), max(0, layout.pages.count - 1))
        if let id = openFolderID {
            if let f = layout.folder(id: id) {
                folderPage = min(folderPage, max(0, folderPages(f).count - 1))
            } else {
                openFolderID = nil
            }
        }
    }

    // MARK: Show / hide

    func willShow() {
        query = ""
        openFolderID = nil
        editMode = false
        drag = nil
        press = nil
        selection = nil
        scrollOffset = 0
        pendingTrash = nil
        alertMessage = nil
        appeared = false
        focusSearchToken += 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) { appeared = true }
    }

    func willHide() {
        if drag != nil { cancelDrag() }
        stopDragTimer()
        if openFolderID != nil { closeFolder() }
        // Mirror of the opening: the grid drifts back out while fading.
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.32)) {
            editMode = false
            appeared = false
        }
    }

    // MARK: Search

    private func queryChanged() {
        refreshResults()
        searchPage = 0
        scrollOffset = 0
        if isSearching {
            if openFolderID != nil { openFolderID = nil }
            editMode = false
        }
        selection = isSearching && !results.isEmpty ? Selection(page: 0, index: 0) : nil
    }

    private func refreshResults() {
        guard isSearching else { results = []; return }
        let hidden = Set(layout.hidden)
        results = Search.filter(sortedApps.filter { !hidden.contains($0.path) }, query: query)
    }

    // MARK: Rendering

    func renderedMain(size: CGSize) -> [RenderedItem] {
        guard !layout.pages.isEmpty else { return [] }
        let m = metrics(for: size)
        let offset = openFolderID == nil ? scrollOffset : 0
        var out: [RenderedItem] = []
        // Behind an open folder only the current page shows; neighbours are needed only while paging.
        let spread = openFolderID == nil ? 1 : 0
        let range = max(0, currentPage - spread)...min(layout.pages.count - 1, currentPage + spread)
        for p in range {
            let gap = drag?.context == .main && drag?.page == p ? drag?.gapIndex : nil
            for (i, item) in layout.pages[p].enumerated() {
                let slot = gap.map { i >= $0 ? i + 1 : i } ?? i
                var c = m.iconCenter(min(slot, m.capacity - 1))
                c.x += CGFloat(p - currentPage) * size.width + offset
                out.append(RenderedItem(
                    id: item.id, item: item, iconCenter: c,
                    selected: !isSearching && openFolderID == nil && selection == Selection(page: p, index: i),
                    mergeTarget: drag?.mergeTargetID == item.id,
                    visible: slot < m.capacity))
            }
        }
        return out
    }

    func renderedSearch(size: CGSize) -> [(app: AppInfo, center: CGPoint, selected: Bool)] {
        let m = metrics(for: size)
        let pages = searchPages
        guard !results.isEmpty else { return [] }
        var out: [(AppInfo, CGPoint, Bool)] = []
        for p in max(0, searchPage - 1)...min(pages.count - 1, searchPage + 1) {
            for (i, app) in pages[p].enumerated() {
                var c = m.iconCenter(i)
                c.x += CGFloat(p - searchPage) * size.width + scrollOffset
                out.append((app, c, selection == Selection(page: p, index: i)))
            }
        }
        return out
    }

    func renderedFolder(_ folder: Folder, size: CGSize) -> [RenderedItem] {
        let g = folderGeometry(for: size)
        let cap = g.grid.capacity
        let gap: Int? = drag?.context == .folder(folder.id) ? drag?.gapIndex : nil
        return folder.apps.enumerated().map { i, path in
            let slot = gap.map { i >= $0 ? i + 1 : i } ?? i
            let page = slot / cap
            var c = g.grid.iconCenter(slot % cap)
            c.x += CGFloat(page - folderPage) * g.panel.width + scrollOffset
            return RenderedItem(id: path, item: .app(path), iconCenter: c,
                                selected: selection == Selection(page: i / cap, index: i % cap))
        }
    }

    // MARK: Hit testing

    func hitTest(_ p: CGPoint) -> HitResult {
        if isSearching {
            let m = metrics
            if let s = m.slot(at: p), m.hitsItem(p, slot: s) {
                let index = searchPage * m.capacity + s
                if index < results.count { return .searchResult(index) }
            }
            return .background
        }
        if let folder = openFolder {
            let g = folderGeometry
            guard g.panel.contains(p) else { return .background }
            if let s = g.grid.slot(at: p) {
                let index = folderPage * g.grid.capacity + s
                if index < folder.apps.count {
                    let path = folder.apps[index]
                    if editMode, apps[path]?.isRemovable == true,
                       hypot(p.x - g.grid.badgeCenter(s).x, p.y - g.grid.badgeCenter(s).y) < 14 {
                        return .deleteBadge(path)
                    }
                    if g.grid.hitsItem(p, slot: s) {
                        return .item(context: .folder(folder.id), page: folderPage, index: index,
                                     item: .app(path), iconCenter: g.grid.iconCenter(s))
                    }
                }
            }
            return .folderPanel
        }
        let m = metrics
        guard layout.pages.indices.contains(currentPage), let s = m.slot(at: p) else { return .background }
        let page = layout.pages[currentPage]
        guard s < page.count else { return .background }
        if editMode, case .app(let path) = page[s], apps[path]?.isRemovable == true,
           hypot(p.x - m.badgeCenter(s).x, p.y - m.badgeCenter(s).y) < 14 {
            return .deleteBadge(path)
        }
        guard m.hitsItem(p, slot: s) else { return .background }
        return .item(context: .main, page: currentPage, index: s, item: page[s], iconCenter: m.iconCenter(s))
    }

    // MARK: Pointer

    func pointerChanged(_ p: CGPoint) {
        guard pendingTrash == nil, alertMessage == nil, !isSettling else { return }
        if drag != nil { updateDrag(p); return }
        guard var pr = press else { pointerDown(p); return }
        let dx = p.x - pr.start.x
        if pr.scrolling {
            scrollOffset = rubberBand(dx)
            return
        }
        guard hypot(dx, p.y - pr.start.y) > 6 else { return }
        longPressWork?.cancel()
        switch pr.hit {
        case let .item(context, page, index, item, iconCenter) where !isSearching:
            beginDrag(item: item, context: context, page: page, index: index, iconCenter: iconCenter, at: p)
        case .item, .background, .folderPanel, .searchResult:
            // Click-dragging empty space flips pages, as in the original Launchpad.
            pr.scrolling = true
            press = pr
        case .deleteBadge:
            break
        }
    }

    private func pointerDown(_ p: CGPoint) {
        let hit = hitTest(p)
        press = (p, hit, false, false)
        longPressWork?.cancel()
        if case .item = hit, !isSearching {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.press != nil, self.drag == nil else { return }
                self.press?.longPressed = true
                withAnimation(self.animation) { self.editMode = true }
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    func pointerEnded(_ p: CGPoint) {
        longPressWork?.cancel()
        defer { press = nil }
        if drag != nil { endDrag(); return }
        guard let pr = press else { return }
        if pr.scrolling { finishScroll(); return }
        if pr.longPressed { return }
        click(pr.hit)
    }

    private func click(_ hit: HitResult) {
        switch hit {
        case .item(_, _, _, .app(let path), _):
            if !editMode { launch(path) }
        case .item(_, _, _, .folder(let f), _):
            openFolder(f.id)
        case .deleteBadge(let path):
            pendingTrash = apps[path]
        case .searchResult(let i):
            launch(results[i].path)
        case .folderPanel:
            break
        case .background:
            backgroundClicked()
        }
    }

    private func backgroundClicked() {
        if openFolderID != nil {
            closeFolder()
        } else if editMode {
            withAnimation(animation) { editMode = false }
        } else {
            onHide?()
        }
    }

    // MARK: Paging

    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let page = contextPage, count = contextPageCount
        if (page == 0 && dx > 0) || (page >= count - 1 && dx < 0) { return dx * 0.3 }
        return dx
    }

    private func finishScroll() {
        let threshold = contextPageWidth * 0.12
        var target = contextPage
        if scrollOffset < -threshold { target += 1 } else if scrollOffset > threshold { target -= 1 }
        target = min(max(0, target), contextPageCount - 1)
        withAnimation(pageAnimation) {
            contextPage = target
            scrollOffset = 0
        }
    }

    func goToPage(_ page: Int) {
        let page = min(max(0, page), contextPageCount - 1)
        withAnimation(pageAnimation) {
            contextPage = page
            scrollOffset = 0
        }
        if !isSearching { selection = nil }
    }

    func flipPage(_ delta: Int) { goToPage(contextPage + delta) }

    /// Two-finger swipes follow the fingers; mouse wheels flip one page per notch burst (F-02).
    func handleScroll(_ e: NSEvent) {
        guard drag == nil, press == nil, pendingTrash == nil else { return }
        if e.hasPreciseScrollingDeltas {
            guard e.momentumPhase.isEmpty else { return }
            let delta = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            switch e.phase {
            case .began:
                trackpadScrolling = true
            case .changed where trackpadScrolling:
                scrollOffset = rubberBand(scrollOffset + delta)
            case .ended, .cancelled:
                if trackpadScrolling { finishScroll() }
                trackpadScrolling = false
            default:
                break
            }
        } else {
            let delta = abs(e.deltaX) > abs(e.deltaY) ? e.deltaX : e.deltaY
            guard abs(delta) > 0.1 else { return }
            // One spin of the wheel arrives as a burst of events: flip once at its start and ignore
            // the rest, so the page slide is never restarted halfway.
            let now = Date()
            defer { lastWheelEvent = now }
            guard now.timeIntervalSince(lastWheelEvent) > 0.18 else { return }
            flipPage(delta < 0 ? 1 : -1)
        }
    }

    // MARK: Drag and drop (F-03, F-04)

    private func beginDrag(item: LayoutItem, context: DragContext, page: Int, index: Int, iconCenter: CGPoint, at p: CGPoint) {
        withAnimation(reorderAnimation) {
            editMode = true
            selection = nil
            switch context {
            case .main: layout.pages[page].remove(at: index)
            case .folder(let id): layout.updateFolder(id: id) { $0.apps.remove(at: index) }
            }
            drag = DragState(item: item, location: p,
                             grabOffset: CGSize(width: p.x - iconCenter.x, height: p.y - iconCenter.y),
                             context: context, page: page, gapIndex: index, origin: (context, page, index))
        }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tickDrag() }
    }

    private func updateDrag(_ p: CGPoint) {
        drag?.location = p
        tickDrag()
    }

    private func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func setHover(_ d: inout DragState, _ candidate: HoverCandidate, now: Date) {
        if d.hover != candidate {
            d.hover = candidate
            d.hoverSince = now
        }
    }

    private func tickDrag() {
        guard var d = drag else { return }
        let now = Date()
        let center = d.iconCenter
        // Changes are applied to a copy and published once, inside the matching animation,
        // so icons visibly slide aside instead of jumping.
        var change: Animation?? = nil
        var newFolderID: String?? = nil
        var newFolderPage: Int?
        var newPage: Int?
        var dissolve: (page: Int, index: Int, app: String)?

        switch d.context {
        case .folder(let id):
            guard let folder = layout.folder(id: id) else { return }
            let g = folderGeometry
            // The folder's "inside" is its icon grid; the title strip and padding already count as outside,
            // so dragging toward any edge of the panel leaves the folder.
            let inside = g.grid.gridRect.insetBy(dx: -g.grid.cellSize.width * 0.2, dy: -g.grid.cellSize.height * 0.15)
                .intersection(g.panel)
            if !inside.contains(d.location) {
                // Dragging out of an open folder closes it and continues on the main grid.
                if d.outsideSince == nil { d.outsideSince = now }
                let outsideFor = now.timeIntervalSince(d.outsideSince!)
                let leave = d.exitArmed ? (!g.panel.contains(d.location) || outsideFor > 0.12) : outsideFor > 1.0
                if leave {
                    // Find the icon first, so the folder shrinks back into it even if it turns into an app.
                    updateFolderOrigin(id)
                    // A folder left with a single app turns back into that app, in the same animated
                    // update as the close, so the folder still visibly shrinks back into its icon.
                    if folder.apps.count == 1, let loc = layout.folderLocation(id: id) {
                        dissolve = (loc.page, loc.index, folder.apps[0])
                    }
                    newFolderID = .some(nil)
                    d.context = .main
                    d.page = currentPage
                    d.gapIndex = nil
                    d.outsideSince = nil
                    d.hover = .none
                    d.exitArmed = true
                    change = .some(folderCloseAnimation)
                }
                break
            }
            d.outsideSince = nil
            d.exitArmed = true
            let cap = g.grid.capacity
            let edge = center.x < g.panel.minX + 30 ? -1 : center.x > g.panel.maxX - 30 ? 1 : 0
            if edge != 0 {
                if d.edgeSince == nil { d.edgeSince = now }
                let target = folderPage + edge
                if now.timeIntervalSince(d.edgeSince!) > 0.6, target >= 0, target <= folder.apps.count / cap {
                    d.edgeSince = now
                    newFolderPage = target
                    change = .some(pageAnimation)
                }
            } else {
                d.edgeSince = nil
            }
            if change == nil, let s = g.grid.slot(at: center) {
                let gap = min(folderPage * cap + s, folder.apps.count)
                if d.gapIndex != gap {
                    d.gapIndex = gap
                    change = .some(reorderAnimation)
                }
            }

        case .main:
            let m = metrics
            let edge = d.location.x < 28 ? -1 : d.location.x > viewSize.width - 28 ? 1 : 0
            if edge != 0 {
                if d.edgeSince == nil { d.edgeSince = now }
                if now.timeIntervalSince(d.edgeSince!) > 0.55 {
                    d.edgeSince = now
                    var target = currentPage + edge
                    if target >= layout.pages.count, let last = layout.pages.last, !last.isEmpty {
                        layout.pages.append([])
                    }
                    target = min(max(0, target), layout.pages.count - 1)
                    if target != currentPage {
                        newPage = target
                        d.page = target
                        d.gapIndex = nil
                        d.mergeTargetID = nil
                        change = .some(pageAnimation)
                    }
                }
                break
            }
            d.edgeSince = nil
            guard layout.pages.indices.contains(d.page), let slot = m.slot(at: center) else { break }
            let items = layout.pages[d.page]
            var rendered: Int? = slot
            if let gap = d.gapIndex { rendered = slot == gap ? nil : slot > gap ? slot - 1 : slot }
            if let r = rendered, r < items.count, case .app = d.item, m.nearCenter(center, slot: slot) {
                setHover(&d, .merge(items[r].id), now: now)
            } else {
                setHover(&d, .gap(min(slot, items.count)), now: now)
            }
            let elapsed = now.timeIntervalSince(d.hoverSince)
            switch d.hover {
            // Gaps open only after a short pause, so moving across icons toward a folder target
            // does not push the target away first.
            case .gap(let g) where elapsed > 0.22:
                if d.gapIndex != g || d.mergeTargetID != nil {
                    d.gapIndex = g
                    d.mergeTargetID = nil
                    change = .some(reorderAnimation)
                }
            // Hovering on longer opens the folder (or a new one) so the app can be placed inside.
            case .merge(let id) where elapsed > 0.9:
                if let index = items.firstIndex(where: { $0.id == id }), case .app(let dragged) = d.item {
                    let folder: Folder
                    switch items[index] {
                    case .folder(let f):
                        folder = f
                    case .app(let target):
                        let name = FolderNaming.suggestedName(categories: [apps[target]?.category, apps[dragged]?.category])
                        folder = Folder(name: name, apps: [target])
                        layout.pages[d.page][index] = .folder(folder)
                    }
                    let renderedSlot = d.gapIndex.map { index >= $0 ? index + 1 : index } ?? index
                    folderOrigin = m.iconCenter(renderedSlot)
                    newFolderID = .some(folder.id)
                    newFolderPage = folder.apps.count / folderGeometry.grid.capacity
                    d.context = .folder(folder.id)
                    d.gapIndex = folder.apps.count
                    d.mergeTargetID = nil
                    d.hover = .none
                    d.outsideSince = nil
                    d.exitArmed = false
                    change = .some(folderAnimation)
                }
            case .merge(let id) where elapsed > 0.25:
                if d.mergeTargetID != id {
                    d.mergeTargetID = id
                    change = .some(reorderAnimation)
                }
            default:
                break
            }
        }

        let apply = {
            if let x = dissolve { self.layout.pages[x.page][x.index] = .app(x.app) }
            if let id = newFolderID { self.openFolderID = id }
            if let p = newFolderPage { self.folderPage = p }
            if let p = newPage { self.currentPage = p }
            self.drag = d
        }
        if let anim = change { withAnimation(anim, apply) } else { apply() }
    }

    private func endDrag() {
        stopDragTimer()
        guard let d = drag, !isSettling else { return }
        // Let the lifted icon glide into its slot before the layout changes under it.
        guard let target = dropTarget(d), !reduceMotion else { commitDrop(); return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            isSettling = true
            drag?.location = CGPoint(x: target.x + d.grabOffset.width, y: target.y + d.grabOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            self.isSettling = false
            self.commitDrop()
        }
    }

    private func dropTarget(_ d: DragState) -> CGPoint? {
        switch d.context {
        case .main:
            guard layout.pages.indices.contains(d.page) else { return nil }
            let m = metrics
            if let id = d.mergeTargetID, let i = layout.pages[d.page].firstIndex(where: { $0.id == id }) {
                return m.iconCenter(d.gapIndex.map { i >= $0 ? i + 1 : i } ?? i)
            }
            let gap = d.gapIndex ?? layout.pages[d.page].count
            return gap < m.capacity ? m.iconCenter(gap) : nil
        case .folder:
            let g = folderGeometry.grid
            guard let gap = d.gapIndex, gap / g.capacity == folderPage else { return nil }
            return g.iconCenter(gap % g.capacity)
        }
    }

    private func commitDrop() {
        guard let d = drag else { return }
        lastDroppedID = d.item.id
        withAnimation(reorderAnimation) {
            switch d.context {
            case .main:
                if !layout.pages.indices.contains(d.page) { layout.pages.append([]) }
                let page = layout.pages.indices.contains(d.page) ? d.page : layout.pages.count - 1
                if let target = d.mergeTargetID, case .app(let path) = d.item,
                   let index = layout.pages[page].firstIndex(where: { $0.id == target }) {
                    switch layout.pages[page][index] {
                    case .folder(var f):
                        f.apps.append(path)
                        layout.pages[page][index] = .folder(f)
                    case .app(let targetPath):
                        let name = FolderNaming.suggestedName(categories: [apps[targetPath]?.category, apps[path]?.category])
                        layout.pages[page][index] = .folder(Folder(name: name, apps: [targetPath, path]))
                    }
                } else {
                    let index = min(d.gapIndex ?? layout.pages[page].count, layout.pages[page].count)
                    layout.pages[page].insert(d.item, at: index)
                }
            case .folder(let id):
                layout.updateFolder(id: id) { f in
                    f.apps.insert(contentsOf: d.item.appPaths, at: min(d.gapIndex ?? f.apps.count, f.apps.count))
                }
            }
            drag = nil
            if openFolderID == nil { normalize() }
        }
        save()
    }

    func cancelDrag() {
        stopDragTimer()
        isSettling = false
        guard let d = drag else { return }
        withAnimation(reorderAnimation) {
            switch d.origin.context {
            case .main:
                let p = min(d.origin.page, layout.pages.count - 1)
                layout.pages[p].insert(d.item, at: min(d.origin.index, layout.pages[p].count))
            case .folder(let id):
                if layout.folder(id: id) != nil {
                    layout.updateFolder(id: id) { $0.apps.insert(contentsOf: d.item.appPaths, at: min(d.origin.index, $0.apps.count)) }
                } else {
                    layout.pages[min(currentPage, layout.pages.count - 1)].append(d.item)
                }
            }
            drag = nil
            normalize()
        }
        save()
    }

    // MARK: Folders

    private func updateFolderOrigin(_ id: String) {
        if let loc = layout.folderLocation(id: id), loc.page == currentPage {
            folderOrigin = metrics.iconCenter(loc.index)
        } else {
            folderOrigin = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        }
    }

    func openFolder(_ id: String) {
        updateFolderOrigin(id)
        withAnimation(folderAnimation) {
            openFolderID = id
            folderPage = 0
            scrollOffset = 0
            selection = nil
        }
    }

    func closeFolder() {
        guard let id = openFolderID else { return }
        layout.updateFolder(id: id) { f in
            if f.name.trimmingCharacters(in: .whitespaces).isEmpty { f.name = L("Untitled Folder") }
        }
        updateFolderOrigin(id)
        withAnimation(folderCloseAnimation) {
            openFolderID = nil
            scrollOffset = 0
            selection = nil
            normalize()
        }
        focusSearchToken += 1
        save()
    }

    func renameFolder(_ id: String, to name: String) {
        layout.updateFolder(id: id) { $0.name = name }
        save()
    }

    func ungroupFolder(_ id: String) {
        withAnimation(animation) {
            if openFolderID == id { openFolderID = nil }
            layout.dissolveFolder(id: id, capacity: capacity)
            clampPages()
        }
        save()
    }

    // MARK: Actions

    func launch(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { NSSound.beep() }
        }
        onHide?()
    }

    /// F-14: hidden apps stay installed but leave the layout.
    func hide(_ path: String) {
        withAnimation(animation) {
            layout.remove(appPath: path)
            if !layout.hidden.contains(path) { layout.hidden.append(path) }
            normalize()
        }
        refreshResults()
        save()
    }

    func unhide(_ path: String) {
        layout.hidden.removeAll { $0 == path }
        layout.reconcile(installed: sortedApps, capacity: capacity)
        refreshResults()
        save()
    }

    /// F-13: move to Trash after confirmation.
    func confirmTrash() {
        guard let app = pendingTrash else { return }
        pendingTrash = nil
        NSWorkspace.shared.recycle([app.url]) { _, error in
            DispatchQueue.main.async {
                if error != nil {
                    self.alertMessage = L("Could not move “%@” to the Trash.", app.name)
                } else {
                    withAnimation(self.animation) {
                        self.layout.remove(appPath: app.path)
                        self.normalize()
                    }
                    self.save()
                    self.rescan()
                }
            }
        }
    }

    // MARK: Keyboard (non-functional: full keyboard operation)

    /// Returns true when the key was handled and should not reach the search field.
    func handleKey(_ e: NSEvent) -> Bool {
        if let editor = e.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case 53: // Esc
            escape()
            return true
        case 36, 76: // Return
            if isEditingFolderName { focusSearchToken += 1; return true }
            activateSelection()
            return true
        case 123, 124, 125, 126:
            if isEditingFolderName { return false }
            if pendingTrash != nil || alertMessage != nil { return true }
            let dx = e.keyCode == 123 ? -1 : e.keyCode == 124 ? 1 : 0
            let dy = e.keyCode == 126 ? -1 : e.keyCode == 125 ? 1 : 0
            if flags.contains(.command) || (selection == nil && dx != 0) {
                flipPage(dx)
            } else {
                moveSelection(dx: dx, dy: dy)
            }
            return true
        default:
            return false
        }
    }

    func escape() {
        if pendingTrash != nil { pendingTrash = nil; return }
        if alertMessage != nil { alertMessage = nil; return }
        if drag != nil { cancelDrag(); return }
        if isEditingFolderName { focusSearchToken += 1; return }
        if openFolderID != nil { closeFolder(); return }
        if isSearching { query = ""; return }
        if editMode { withAnimation(animation) { editMode = false }; return }
        onHide?()
    }

    private var contextPages: [Int] {
        if let f = openFolder { return folderPages(f).map(\.count) }
        if isSearching { return searchPages.map(\.count) }
        return layout.pages.map(\.count)
    }

    private func moveSelection(dx: Int, dy: Int) {
        let counts = contextPages
        guard counts.contains(where: { $0 > 0 }) else { return }
        guard var sel = selection, counts.indices.contains(sel.page) else {
            let page = min(contextPage, counts.count - 1)
            selection = Selection(page: page, index: 0)
            return
        }
        let cols = openFolder != nil ? folderGeometry.grid.cols : settings.columns
        if dx != 0 {
            sel.index += dx
            if sel.index < 0 {
                if sel.page > 0 { sel.page -= 1; sel.index = counts[sel.page] - 1 } else { sel.index = 0 }
            } else if sel.index >= counts[sel.page] {
                if sel.page + 1 < counts.count, counts[sel.page + 1] > 0 { sel.page += 1; sel.index = 0 } else { sel.index = counts[sel.page] - 1 }
            }
        }
        if dy != 0 {
            let n = sel.index + dy * cols
            if n >= 0, n < counts[sel.page] { sel.index = n }
        }
        selection = sel
        if sel.page != contextPage { goToPage(sel.page) }
    }

    private func activateSelection() {
        if pendingTrash != nil { confirmTrash(); return }
        if alertMessage != nil { alertMessage = nil; return }
        if isSearching {
            let i = selection.map { $0.page * capacity + $0.index } ?? 0
            if results.indices.contains(i) { launch(results[i].path) }
            return
        }
        guard let sel = selection else { return }
        if let f = openFolder {
            let i = sel.page * folderGeometry.grid.capacity + sel.index
            if f.apps.indices.contains(i) { launch(f.apps[i]) }
            return
        }
        guard layout.pages.indices.contains(sel.page), layout.pages[sel.page].indices.contains(sel.index) else { return }
        switch layout.pages[sel.page][sel.index] {
        case .app(let path): launch(path)
        case .folder(let f): openFolder(f.id)
        }
    }

    // MARK: Context menu

    func contextMenu(at p: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        switch hitTest(p) {
        case .item(_, _, _, .app(let path), _), .deleteBadge(let path):
            add(L("Open")) { [weak self] in self?.launch(path) }
            add(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            menu.addItem(.separator())
            add(L("Hide")) { [weak self] in self?.hide(path) }
            if let app = apps[path], app.isRemovable {
                add(L("Move to Trash…")) { [weak self] in self?.pendingTrash = app }
            }
        case .searchResult(let i):
            let path = results[i].path
            add(L("Open")) { [weak self] in self?.launch(path) }
            add(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            add(L("Hide")) { [weak self] in self?.hide(path) }
        case .item(_, _, _, .folder(let f), _):
            add(L("Open")) { [weak self] in self?.openFolder(f.id) }
            add(L("Rename")) { [weak self] in
                self?.openFolder(f.id)
                self?.focusFolderNameToken += 1
            }
            add(L("Ungroup Folder")) { [weak self] in self?.ungroupFolder(f.id) }
        case .folderPanel, .background:
            add(editMode ? L("Done Editing") : L("Edit Layout")) { [weak self] in
                guard let self else { return }
                withAnimation(self.animation) { self.editMode.toggle() }
            }
            add(L("Settings…")) { [weak self] in self?.onOpenSettings?() }
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
