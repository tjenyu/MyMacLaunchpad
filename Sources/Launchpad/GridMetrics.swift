import CoreGraphics

/// Slot geometry for one page of icons, in root view coordinates (top-left origin).
struct GridMetrics {
    static let labelHeight: CGFloat = 19
    static let labelSpacing: CGFloat = 8

    let gridRect: CGRect
    let rows: Int
    let cols: Int
    let iconSize: CGFloat

    init(gridRect: CGRect, rows: Int, cols: Int, preferredIconSize: CGFloat) {
        self.gridRect = gridRect
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        let cw = gridRect.width / CGFloat(self.cols), ch = gridRect.height / CGFloat(self.rows)
        iconSize = max(24, min(preferredIconSize, cw * 0.8, ch - Self.labelHeight - Self.labelSpacing - 10))
    }

    /// Main launcher grid for a window of `size`.
    init(size: CGSize, rows: Int, cols: Int, preferredIconSize: CGFloat) {
        let hInset = max(60, size.width * 0.09)
        let top: CGFloat = 110, bottom: CGFloat = 100
        let rect = CGRect(x: hInset, y: top, width: max(100, size.width - 2 * hInset),
                          height: max(100, size.height - top - bottom))
        self.init(gridRect: rect, rows: rows, cols: cols, preferredIconSize: preferredIconSize)
    }

    var capacity: Int { rows * cols }
    var cellSize: CGSize { CGSize(width: gridRect.width / CGFloat(cols), height: gridRect.height / CGFloat(rows)) }
    var labelWidth: CGFloat { cellSize.width - 10 }
    /// Distance from the icon center to the center of icon + label.
    static var itemCenterOffset: CGFloat { (labelHeight + labelSpacing) / 2 }

    func iconCenter(_ slot: Int) -> CGPoint {
        let slot = max(0, slot)
        let col = slot % cols, row = (slot / cols) % rows
        return CGPoint(x: gridRect.minX + (CGFloat(col) + 0.5) * cellSize.width,
                       y: gridRect.minY + (CGFloat(row) + 0.5) * cellSize.height - Self.itemCenterOffset)
    }

    /// The slot under a point, or nil when the point is outside the grid.
    func slot(at p: CGPoint) -> Int? {
        guard gridRect.insetBy(dx: -cellSize.width * 0.3, dy: -cellSize.height * 0.3).contains(p) else { return nil }
        let col = min(cols - 1, max(0, Int((p.x - gridRect.minX) / cellSize.width)))
        let row = min(rows - 1, max(0, Int((p.y - gridRect.minY) / cellSize.height)))
        return row * cols + col
    }

    /// True when the point is on the icon or its label.
    func hitsItem(_ p: CGPoint, slot: Int) -> Bool {
        let c = iconCenter(slot)
        let halfWidth = max(iconSize * 0.55, min(labelWidth / 2, iconSize * 0.7))
        return abs(p.x - c.x) <= halfWidth && p.y >= c.y - iconSize * 0.55
            && p.y <= c.y + iconSize / 2 + Self.labelSpacing + Self.labelHeight + 2
    }

    /// The center of the icon, where dropping makes or fills a folder.
    func nearCenter(_ p: CGPoint, slot: Int) -> Bool {
        let c = iconCenter(slot)
        return hypot(p.x - c.x, p.y - c.y) < iconSize * 0.45
    }

    func badgeCenter(_ slot: Int) -> CGPoint {
        let c = iconCenter(slot)
        return CGPoint(x: c.x - iconSize / 2 + 4, y: c.y - iconSize / 2 + 4)
    }
}

struct FolderGeometry {
    let panel: CGRect
    let grid: GridMetrics
    static let titleHeight: CGFloat = 76
    static let dotsHeight: CGFloat = 40

    init(size: CGSize, main: GridMetrics) {
        let cols = main.cols, rows = min(3, main.rows)
        let cell = main.cellSize
        let pad: CGFloat = 28
        let gridWidth = min(cell.width * CGFloat(cols), size.width - 80 - 2 * pad)
        let gridHeight = cell.height * CGFloat(rows)
        let panelSize = CGSize(width: gridWidth + 2 * pad, height: Self.titleHeight + gridHeight + Self.dotsHeight)
        panel = CGRect(x: (size.width - panelSize.width) / 2, y: (size.height - panelSize.height) / 2,
                       width: panelSize.width, height: panelSize.height)
        let gridRect = CGRect(x: panel.minX + pad, y: panel.minY + Self.titleHeight, width: gridWidth, height: gridHeight)
        grid = GridMetrics(gridRect: gridRect, rows: rows, cols: cols, preferredIconSize: main.iconSize)
    }
}
