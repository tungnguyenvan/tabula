// Renders Resources/AppIcon.icns: the Tabula mark (a grid on a blue→violet tile), matching AppMark in Theme.swift.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: the tile is inset ~10% with a soft drop shadow.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset * 1.15, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.29, green: 0.36, blue: 0.95, alpha: 1).cgColor, NSColor(red: 0.55, green: 0.27, blue: 0.86, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Grid: a solid header bar and 3×3 cells.
    let padding = tile.width * 0.2
    let content = tile.insetBy(dx: padding, dy: padding)
    let gap = tile.width * 0.06
    let headerHeight = tile.width * 0.12
    let cellHeight = tile.width * 0.08
    var y = content.maxY - headerHeight
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: content.minX, y: y, width: content.width, height: headerHeight),
                       cornerWidth: tile.width * 0.03, cornerHeight: tile.width * 0.03, transform: nil))
    ctx.fillPath()
    let cellWidth = (content.width - gap * 2) / 3
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    for _ in 0..<3 {
        y -= gap + cellHeight
        for column in 0..<3 {
            let rect = CGRect(x: content.minX + CGFloat(column) * (cellWidth + gap), y: y, width: cellWidth, height: cellHeight)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: tile.width * 0.02, cornerHeight: tile.width * 0.02, transform: nil))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
