import AppKit
import LaunchpadCore
import SwiftUI

struct LauncherView: View {
    @ObservedObject var c: LauncherController
    @ObservedObject var settings: AppSettings
    @ObservedObject var icons: IconCache
    @FocusState private var focus: Field?

    enum Field { case search, folderName }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let m = c.metrics(for: size)
            let folder = c.openFolder
            ZStack {
                if let wallpaper = c.wallpaper {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    // Gentle dim that keeps the wallpaper's own colors, like the original Launchpad.
                    LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.26)], startPoint: .top, endPoint: .bottom)
                } else {
                    BlurBackground(strength: settings.blurStrength)
                    LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                }

                // One gesture layer under everything: the controller hit-tests icons itself,
                // which lets a single drag move between pages and in and out of folders.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                            .onChanged { c.pointerChanged($0.location) }
                            .onEnded {
                                c.pointerEnded($0.location)
                                if c.openFolderID == nil || focus == .folderName { focus = .search }
                            }
                    )

                ZStack {
                    Group {
                        if c.isSearching {
                            searchResults(size: size, metrics: m)
                        } else {
                            mainGrid(size: size, metrics: m)
                        }
                    }
                    .opacity(folder == nil ? 1 : 0.3)
                    .blur(radius: folder == nil || c.reduceMotion ? 0 : 8)
                    .scaleEffect(folder == nil || c.reduceMotion ? 1 : 0.95)
                    .allowsHitTesting(false)

                    pageDots(count: c.isSearching ? c.searchPages.count : c.layout.pages.count,
                             current: c.isSearching ? c.searchPage : c.currentPage)
                        .position(x: size.width / 2, y: size.height - 50)
                        .opacity(folder == nil ? 1 : 0)

                    searchField
                        .position(x: size.width / 2, y: 54)
                }
                .scaleEffect(c.appeared || c.reduceMotion ? 1 : 1.06)
                .opacity(c.appeared ? 1 : 0)

                if let folder {
                    // The folder grows out of its icon and shrinks back into it.
                    folderOverlay(folder, size: size)
                        .transition(c.reduceMotion ? .opacity : .scale(scale: 0.12, anchor: UnitPoint(
                            x: c.folderOrigin.x / max(size.width, 1), y: c.folderOrigin.y / max(size.height, 1)))
                            .combined(with: .opacity))
                }

                if let d = c.drag {
                    ItemView(item: d.item, c: c, metrics: folder != nil ? c.folderGeometry(for: size).grid : m,
                             jiggle: false, showBadge: false, mergeTarget: false, selected: false, showLabel: false)
                        .scaleEffect(c.isSettling ? 1 : 1.12)
                        .shadow(color: .black.opacity(c.isSettling ? 0 : 0.35), radius: 12, y: 6)
                        .position(x: d.iconCenter.x, y: d.iconCenter.y + GridMetrics.itemCenterOffset)
                        .allowsHitTesting(false)
                        // Swapped for the real icon at the same spot on drop, with no fade.
                        .transition(.identity)
                }

                if let app = c.pendingTrash {
                    ConfirmDialog(
                        icon: icons.image(for: app.path),
                        title: L("Move “%@” to the Trash?", app.name),
                        message: L("The app will be removed from this Mac. You can restore it from the Trash."),
                        confirmTitle: L("Move to Trash"), destructive: true,
                        onCancel: { c.pendingTrash = nil }, onConfirm: { c.confirmTrash() })
                } else if let message = c.alertMessage {
                    ConfirmDialog(icon: nil, title: message, message: nil, confirmTitle: L("OK"), destructive: false,
                                  onCancel: nil, onConfirm: { c.alertMessage = nil })
                }
            }
            .coordinateSpace(name: "root")
            .onAppear { c.viewSize = size }
            .onChange(of: size) { _, new in c.viewSize = new }
        }
        .ignoresSafeArea()
        .onChange(of: c.focusSearchToken) { focus = .search }
        .onChange(of: c.focusFolderNameToken) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .folderName }
        }
        .onChange(of: focus) { _, new in c.isEditingFolderName = new == .folderName }
        .onAppear { focus = .search }
    }

    // MARK: Pieces

    private func mainGrid(size: CGSize, metrics m: GridMetrics) -> some View {
        ZStack {
            ForEach(c.renderedMain(size: size)) { r in
                ItemView(item: r.item, c: c, metrics: m, jiggle: c.editMode && !c.reduceMotion,
                         showBadge: c.editMode && r.item.isRemovableApp(in: c), mergeTarget: r.mergeTarget,
                         selected: r.selected)
                    .position(x: r.iconCenter.x, y: r.iconCenter.y + GridMetrics.itemCenterOffset)
                    .opacity(r.visible ? 1 : 0)
                    // Scale about the icon itself (the positioned view spans the whole screen, so the default
                    // anchor would make icons fly in from the screen center). A new folder pops in from the
                    // enlarged hover state; a dropped app simply replaces its settled ghost.
                    .transition(.asymmetric(
                        insertion: r.item.isFolder
                            ? .scale(scale: 1.25, anchor: UnitPoint(x: r.iconCenter.x / max(size.width, 1),
                                                                    y: r.iconCenter.y / max(size.height, 1)))
                                .combined(with: .opacity)
                            : r.id == c.lastDroppedID ? .identity : .opacity,
                        removal: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func searchResults(size: CGSize, metrics m: GridMetrics) -> some View {
        ZStack {
            let rendered = c.renderedSearch(size: size)
            if rendered.isEmpty {
                Text(L("No Results"))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(x: size.width / 2, y: size.height / 2)
            }
            ForEach(rendered, id: \.app.path) { r in
                ItemView(item: .app(r.app.path), c: c, metrics: m, jiggle: false, showBadge: false,
                         mergeTarget: false, selected: r.selected)
                    .position(x: r.center.x, y: r.center.y + GridMetrics.itemCenterOffset)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            TextField(text: $c.query, prompt: Text(L("Search")).foregroundStyle(.white.opacity(0.6))) {
                Text(L("Search"))
            }
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focus, equals: .search)
                .accessibilityLabel(L("Search"))
            if !c.query.isEmpty {
                Button { c.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 38)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    private func pageDots(count: Int, current: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == current ? 0.95 : 0.35))
                    .frame(width: 8, height: 8)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { c.goToPage(i) }
                    .accessibilityLabel("\(i + 1) / \(count)")
                    .accessibilityAddTraits(i == current ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .opacity(count > 1 ? 1 : 0)
    }

    private func folderOverlay(_ folder: Folder, size: CGSize) -> some View {
        let g = c.folderGeometry(for: size)
        let pages = c.folderPages(folder).count
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        return ZStack {
            Color.clear
                .frame(width: g.panel.width, height: g.panel.height)
                .glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
                .position(x: g.panel.midX, y: g.panel.midY)
                .allowsHitTesting(false)

            ZStack {
                ForEach(c.renderedFolder(folder, size: size)) { r in
                    ItemView(item: r.item, c: c, metrics: g.grid, jiggle: c.editMode && !c.reduceMotion,
                             showBadge: c.editMode && r.item.isRemovableApp(in: c), mergeTarget: false,
                             selected: r.selected)
                        .position(x: r.iconCenter.x, y: r.iconCenter.y + GridMetrics.itemCenterOffset)
                        .transition(r.id == c.lastDroppedID ? .identity : .opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .mask(shape.frame(width: g.panel.width, height: g.panel.height).position(x: g.panel.midX, y: g.panel.midY))
            .allowsHitTesting(false)

            TextField("", text: Binding(get: { c.openFolder?.name ?? "" },
                                        set: { c.renameFolder(folder.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .focused($focus, equals: .folderName)
                .frame(width: max(120, g.panel.width - 140))
                .position(x: g.panel.midX, y: g.panel.minY + FolderGeometry.titleHeight / 2)
                .accessibilityLabel(L("Rename"))

            HStack(spacing: 10) {
                ForEach(0..<pages, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(i == c.folderPage ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                        .onTapGesture { c.goToPage(i) }
                }
            }
            .opacity(pages > 1 ? 1 : 0)
            .position(x: g.panel.midX, y: g.panel.maxY - FolderGeometry.dotsHeight / 2)
        }
    }
}

extension LayoutItem {
    func isRemovableApp(in c: LauncherController) -> Bool {
        guard case .app(let path) = self else { return false }
        return c.apps[path]?.isRemovable == true
    }
}

struct ItemView: View {
    let item: LayoutItem
    let c: LauncherController
    let metrics: GridMetrics
    var jiggle: Bool
    var showBadge: Bool
    var mergeTarget: Bool
    var selected: Bool
    var showLabel = true
    /// Captured at init so the view re-renders when names change (the controller reference alone never changes).
    private let title: String

    init(item: LayoutItem, c: LauncherController, metrics: GridMetrics, jiggle: Bool, showBadge: Bool,
         mergeTarget: Bool, selected: Bool, showLabel: Bool = true) {
        self.item = item
        self.c = c
        self.metrics = metrics
        self.jiggle = jiggle
        self.showBadge = showBadge
        self.mergeTarget = mergeTarget
        self.selected = selected
        self.showLabel = showLabel
        switch item {
        case .app(let path): title = c.name(for: path)
        case .folder(let f): title = f.name
        }
    }

    private var size: CGFloat { metrics.iconSize }

    var body: some View {
        VStack(spacing: GridMetrics.labelSpacing) {
            icon
                .frame(width: size, height: size)
                .overlay(alignment: .topLeading) {
                    if showBadge {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black.opacity(0.75))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white.opacity(0.92)))
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .offset(x: -7, y: -7)
                    }
                }
                .background {
                    // Preview of the folder that dropping here will create.
                    if mergeTarget, !item.isFolder {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .fill(.white.opacity(0.3))
                            .padding(-size * 0.14)
                    }
                }
                .scaleEffect(mergeTarget ? 1.12 : 1)
                .modifier(Jiggle(active: jiggle, seed: Double(abs(item.id.hashValue % 997))))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .frame(width: metrics.labelWidth, height: GridMetrics.labelHeight)
                .opacity(showLabel ? 1 : 0)
        }
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.2))
                    .padding(-8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate() }
    }

    private func activate() {
        switch item {
        case .app(let path): c.launch(path)
        case .folder(let f): c.openFolder(f.id)
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .app(let path):
            AppIcon(path: path, icons: c.icons)
        case .folder(let f):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(.white.opacity(mergeTarget ? 0.32 : 0.22))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                let mini = size * 0.24, gap = size * 0.055
                VStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<3, id: \.self) { col in
                                let i = row * 3 + col
                                if i < f.apps.count {
                                    AppIcon(path: f.apps[i], icons: c.icons).frame(width: mini, height: mini)
                                } else {
                                    Color.clear.frame(width: mini, height: mini)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AppIcon: View {
    let path: String
    @ObservedObject var icons: IconCache

    var body: some View {
        if let image = icons.image(for: path) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12))
        }
    }
}

private struct Jiggle: ViewModifier {
    let active: Bool
    let seed: Double

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                content
                    .rotationEffect(.degrees(sin(t * 20 + seed) * 3.5))
                    .offset(x: sin(t * 17 + seed * 1.7) * 0.8, y: cos(t * 19 + seed) * 1.2)
            }
        } else {
            content
        }
    }
}

struct ConfirmDialog: View {
    let icon: NSImage?
    let title: String
    let message: String?
    let confirmTitle: String
    let destructive: Bool
    let onCancel: (() -> Void)?
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { (onCancel ?? onConfirm)() }
            VStack(spacing: 14) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    if let onCancel {
                        Button(L("Cancel"), action: onCancel)
                            .keyboardShortcut(.cancelAction)
                            .frame(maxWidth: .infinity)
                    }
                    Button(confirmTitle, role: destructive ? .destructive : nil, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
            }
            .padding(24)
            .frame(width: 300)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

struct BlurBackground: NSViewRepresentable {
    let strength: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.appearance = NSAppearance(named: .darkAqua)
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.alphaValue = CGFloat(strength)
    }
}
