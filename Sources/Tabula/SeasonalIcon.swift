import AppKit
import TabulaFoundation

/// Tabula's icon for the time of year. The regular one is the app bundle's icon (scripts/make-icon.swift); a season's
/// icon is drawn here, at any size, and shown in the Dock and wherever the app shows its mark. The icon in Finder
/// stays the regular one, since changing it would modify the signed app.
enum SeasonalIcon {
    /// The icon to show for `season`, or nil for the bundle's own.
    static func image(for season: AppSeason) -> NSImage? {
        switch season {
        case .regular:
            return nil
        case .halloween:
            return halloween
        }
    }

    /// The tile fills this share of the image; the rest is the margin macOS icons keep around their shape.
    static let tileShare: CGFloat = 0.8

    static let halloween = NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else {
            return false
        }
        HalloweenArtwork(context: context, canvas: rect).draw()
        return true
    }

    /// Shows the current season's icon in the Dock, now and whenever the day changes.
    @MainActor
    static func startUpdatingDockIcon() {
        updateDockIcon()
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                updateDockIcon()
            }
        }
    }

    @MainActor
    private static func updateDockIcon() {
        // nil puts the bundle's icon back.
        NSApp.applicationIconImage = image(for: AppSeason.on(Date()))
    }
}

/// The Halloween icon, after the design: a deep purple tile, the grid's header bar with a witch hat resting on its
/// right end, two orange cells and a bat. Coordinates are fractions of the tile, from its top left.
private struct HalloweenArtwork {
    let context: CGContext
    let tile: CGRect

    init(context: CGContext, canvas: CGRect) {
        self.context = context
        let side = canvas.width * SeasonalIcon.tileShare
        tile = CGRect(x: canvas.midX - side / 2, y: canvas.midY - side / 2, width: side, height: side)
    }

    private var unit: CGFloat { tile.width }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * unit, y: tile.minY + y * unit)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: point(x, y), size: CGSize(width: width * unit, height: height * unit))
    }

    private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func gradient(_ colors: [CGColor]) -> CGGradient {
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
        // Two or more sRGB colors with matching locations always make a gradient.
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        )!
    }

    /// Fills `path` with a vertical gradient from `top` to `bottom`.
    private func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let box = path.boundingBox
        let start = CGPoint(x: box.midX, y: box.minY)
        let end = CGPoint(x: box.midX, y: box.maxY)
        context.drawLinearGradient(gradient([top, bottom]), start: start, end: end, options: [])
        context.restoreGState()
    }

    private func roundedRect(_ frame: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: radius * unit, cornerHeight: radius * unit, transform: nil)
    }

    func draw() {
        drawTile()
        drawGrid()
        drawBat()
        drawHat()
    }

    private func drawTile() {
        let shape = roundedRect(tile, radius: 0.225)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: unit * 0.015),
            blur: unit * 0.04,
            color: color(0x000000, alpha: 0.4)
        )
        context.addPath(shape)
        context.setFillColor(color(0x2A0E6B))
        context.fillPath()
        context.restoreGState()

        fill(shape, top: color(0x7A33F0), bottom: color(0x3A118F))
        // A soft light from the top, and the deeper purple of the lower corners.
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let light = gradient([color(0xA57CFF, alpha: 0.45), color(0xA57CFF, alpha: 0)])
        context.drawRadialGradient(
            light,
            startCenter: point(0.45, 0.1),
            startRadius: 0,
            endCenter: point(0.45, 0.1),
            endRadius: unit * 0.75,
            options: []
        )
        context.restoreGState()
    }

    private func drawGrid() {
        let header = roundedRect(rect(0.125, 0.315, 0.745, 0.15), radius: 0.05)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: unit * 0.012),
            blur: unit * 0.03,
            color: color(0x1A0640, alpha: 0.45)
        )
        context.addPath(header)
        context.setFillColor(color(0xF4F0FF))
        context.fillPath()
        context.restoreGState()
        fill(header, top: color(0xFFFFFF), bottom: color(0xE2D9F7))

        let columns: [CGFloat] = [0.13, 0.385, 0.645]
        let rows: [CGFloat] = [0.5, 0.665]
        let cellWidth: CGFloat = 0.22
        let cellHeight: CGFloat = 0.135
        /// The orange cells: the middle of the first row and the start of the second, as in the design.
        let orange: Set<[Int]> = [[0, 1], [1, 0]]
        for (row, top) in rows.enumerated() {
            for (column, left) in columns.enumerated() {
                let cell = roundedRect(rect(left, top, cellWidth, cellHeight), radius: 0.045)
                let isOrange = orange.contains([row, column])
                context.saveGState()
                if isOrange {
                    context.setShadow(offset: .zero, blur: unit * 0.05, color: color(0xFF7A12, alpha: 0.75))
                } else {
                    context.setShadow(
                        offset: CGSize(width: 0, height: unit * 0.01),
                        blur: unit * 0.025,
                        color: color(0x1A0640, alpha: 0.4)
                    )
                }
                context.addPath(cell)
                context.setFillColor(isOrange ? color(0xFF8A1F) : color(0xF1ECFF))
                context.fillPath()
                context.restoreGState()
                if isOrange {
                    fill(cell, top: color(0xFFB04A), bottom: color(0xFF7614))
                } else {
                    fill(cell, top: color(0xFFFFFF), bottom: color(0xDDD3F5))
                }
            }
        }
    }

    private func drawBat() {
        let wing = CGMutablePath()
        // The right wing, from the body outward; the left one is its mirror image.
        wing.move(to: point(0.315, 0.152))
        wing.addCurve(to: point(0.415, 0.118), control1: point(0.34, 0.13), control2: point(0.385, 0.112))
        wing.addCurve(to: point(0.39, 0.148), control1: point(0.405, 0.13), control2: point(0.395, 0.138))
        wing.addCurve(to: point(0.365, 0.15), control1: point(0.382, 0.146), control2: point(0.372, 0.146))
        wing.addCurve(to: point(0.35, 0.168), control1: point(0.36, 0.156), control2: point(0.356, 0.162))
        wing.addCurve(to: point(0.315, 0.17), control1: point(0.338, 0.164), control2: point(0.326, 0.165))
        wing.closeSubpath()

        // Mirrored about the body's centre line.
        var mirror = CGAffineTransform(translationX: point(0.315, 0).x * 2, y: 0).scaledBy(x: -1, y: 1)
        let body = CGMutablePath()
        body.addPath(wing)
        if let left = wing.copy(using: &mirror) {
            body.addPath(left)
        }
        body.addEllipse(in: rect(0.302, 0.138, 0.026, 0.045))
        // Ears.
        body.move(to: point(0.304, 0.145))
        body.addLine(to: point(0.306, 0.126))
        body.addLine(to: point(0.313, 0.14))
        body.addLine(to: point(0.317, 0.14))
        body.addLine(to: point(0.324, 0.126))
        body.addLine(to: point(0.326, 0.145))
        body.closeSubpath()

        context.saveGState()
        context.setShadow(offset: .zero, blur: unit * 0.03, color: color(0xFF7A12, alpha: 0.55))
        context.addPath(body)
        context.setFillColor(color(0x24104A))
        context.fillPath()
        context.restoreGState()

        context.setFillColor(color(0xFF9A2E))
        context.fillEllipse(in: rect(0.306, 0.148, 0.007, 0.007))
        context.fillEllipse(in: rect(0.317, 0.148, 0.007, 0.007))
    }

    private func drawHat() {
        // Orange glow behind the hat.
        context.saveGState()
        context.setShadow(offset: .zero, blur: unit * 0.06, color: color(0xFF7A12, alpha: 0.6))

        // Brim: a wide ellipse, tilted down to the left, resting on the header bar's right end.
        let brimCenter = point(0.705, 0.365)
        var brimTransform = CGAffineTransform(translationX: brimCenter.x, y: brimCenter.y).rotated(by: 0.22)
        let brim = CGPath(
            ellipseIn: CGRect(x: -0.27 * unit, y: -0.07 * unit, width: 0.54 * unit, height: 0.14 * unit),
            transform: &brimTransform
        )
        context.addPath(brim)
        context.setFillColor(color(0x3A1A5C))
        context.fillPath()
        context.restoreGState()
        fill(brim, top: color(0x5A2D84), bottom: color(0x2B1145))

        // Cone, leaning right, its tip bent over.
        let cone = CGMutablePath()
        cone.move(to: point(0.555, 0.340))
        cone.addCurve(to: point(0.735, 0.150), control1: point(0.6, 0.260), control2: point(0.67, 0.180))
        cone.addCurve(to: point(0.86, 0.195), control1: point(0.785, 0.125), control2: point(0.83, 0.150))
        cone.addCurve(to: point(0.875, 0.255), control1: point(0.875, 0.215), control2: point(0.885, 0.240))
        cone.addCurve(to: point(0.825, 0.220), control1: point(0.86, 0.245), control2: point(0.84, 0.228))
        cone.addCurve(to: point(0.815, 0.360), control1: point(0.8, 0.260), control2: point(0.8, 0.320))
        cone.addCurve(to: point(0.555, 0.340), control1: point(0.73, 0.390), control2: point(0.62, 0.380))
        cone.closeSubpath()
        fill(cone, top: color(0x4E2678), bottom: color(0x2E1250))

        // Orange band around the base of the cone.
        let band = CGMutablePath()
        band.move(to: point(0.565, 0.320))
        band.addCurve(to: point(0.81, 0.330), control1: point(0.64, 0.350), control2: point(0.74, 0.355))
        band.addLine(to: point(0.815, 0.365))
        band.addCurve(to: point(0.552, 0.348), control1: point(0.74, 0.392), control2: point(0.625, 0.382))
        band.closeSubpath()
        fill(band, top: color(0xFFA43A), bottom: color(0xF2700F))

        // Gold buckle on the band.
        let buckleCenter = point(0.685, 0.352)
        var buckleTransform = CGAffineTransform(translationX: buckleCenter.x, y: buckleCenter.y).rotated(by: 0.1)
        let buckle = CGPath(
            roundedRect: CGRect(x: -0.032 * unit, y: -0.03 * unit, width: 0.064 * unit, height: 0.06 * unit),
            cornerWidth: 0.012 * unit,
            cornerHeight: 0.012 * unit,
            transform: &buckleTransform
        )
        context.saveGState()
        context.addPath(buckle)
        context.setStrokeColor(color(0xFFC75A))
        context.setLineWidth(unit * 0.013)
        context.strokePath()
        context.restoreGState()
    }
}
