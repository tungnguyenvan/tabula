// Composes the README hero image: a window screenshot on a gradient in the app icon's colors,
// with rounded corners and a soft shadow.
//
// Usage: swift scripts/make-hero.swift <window.png> <out.png>
// Take the screenshot with the debug build, e.g.:
//   TABULA_DATA_DIR=/tmp/tabula-dev-data TABULA_DEBUG_OPEN=<ids> TABULA_DEBUG_TABLE=products \
//   TABULA_DEBUG_WIDTH=1440 TABULA_DEBUG_HEIGHT=860 TABULA_DEBUG_SNAPSHOT=/tmp/shots swift run Tabula
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let window = NSImage(contentsOfFile: arguments[1]),
      let source = window.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make-hero.swift <window.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

/// Proportions relative to the screenshot, so the result looks the same at any size.
enum Hero {
    static let margin = 0.07
    static let cornerRadius = 0.012
    static let shadowBlur = 0.03
    static let shadowOffset = 0.012
    static let shadowOpacity = 0.45
    /// The icon's gradient (AppMark), from top left to bottom right.
    static let colors = [CGColor(red: 0.29, green: 0.36, blue: 0.95, alpha: 1), CGColor(red: 0.55, green: 0.27, blue: 0.86, alpha: 1)]
    /// A soft light in the top left corner.
    static let glow = CGColor(red: 1, green: 1, blue: 1, alpha: 0.18)
}

let width = Double(source.width), height = Double(source.height)
let margin = width * Hero.margin
let canvas = CGSize(width: width + margin * 2, height: height + margin * 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Background: diagonal gradient plus a radial highlight.
let gradient = CGGradient(colorsSpace: space, colors: Hero.colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
let glow = CGGradient(colorsSpace: space, colors: [Hero.glow, CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.2, y: canvas.height * 0.9), startRadius: 0,
                           endCenter: CGPoint(x: canvas.width * 0.2, y: canvas.height * 0.9), endRadius: canvas.width * 0.6, options: [])

// Window with shadow, clipped to rounded corners.
let frame = CGRect(x: margin, y: margin, width: width, height: height)
let radius = width * Hero.cornerRadius
let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -width * Hero.shadowOffset), blur: width * Hero.shadowBlur,
                  color: CGColor(gray: 0, alpha: Hero.shadowOpacity))
context.addPath(shape)
context.setFillColor(CGColor(gray: 0.1, alpha: 1))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(shape)
context.clip()
context.draw(source, in: frame)
context.restoreGState()

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: arguments[2]))
print("Wrote \(arguments[2]) (\(Int(canvas.width))×\(Int(canvas.height)))")
