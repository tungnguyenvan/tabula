// swift scripts/broken-frames.swift <dir>: lists rendered frames that are unlike both neighbours while the neighbours
// are like each other: a broken frame, not motion. Chrome now and then hands Remotion a screenshot of the wrong size,
// which lands in the video as the picture tiled. Reads the directory's images in name order and compares thumbnails.
import AppKit
let dir = CommandLine.arguments[1]
let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpeg") || $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
let w = 240, h = 135
func thumb(_ file: String) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let image = NSImage(contentsOfFile: "\(dir)/\(file)")?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return data }
    let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return data
}
func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var sum = 0
    for p in stride(from: 1, to: a.count, by: 4) { sum += abs(Int(a[p]) - Int(b[p])) }
    return Double(sum) / Double(a.count / 4)
}
var thumbs: [[UInt8]] = files.map(thumb)
for k in 1..<max(1, files.count - 1) {
    let before = diff(thumbs[k - 1], thumbs[k]), after = diff(thumbs[k], thumbs[k + 1]), around = diff(thumbs[k - 1], thumbs[k + 1])
    if before > 4, after > 4, around < 0.35 * min(before, after) {
        print(files[k], String(format: "%.1f %.1f %.1f", before, after, around))
    }
}
