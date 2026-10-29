#if DEBUG
import AppKit
import Foundation
import TabulaSQL
import ImageIO
import UniformTypeIdentifiers

/// TABULA_DEBUG_RECORD, TABULA_DEBUG_SNAPSHOT and TABULA_DEBUG_SEASON_ICON: what scripted runs capture.
extension DebugHooks {
    /// The recording in progress, if any.
    private static var recorder: WindowRecorder?

    /// Scripted input while recording: what happened, at which frame, where (fractions of the window, from the top
    /// left). Written to events.json next to the frames, so the demo video can draw the cursor and play sounds there.
    private static var recordedEvents: [[String: Any]] = []

    static func logEvent(_ kind: String, x: Double? = nil, y: Double? = nil) {
        guard let recorder else { return }
        var event: [String: Any] = ["frame": recorder.currentFrame, "kind": kind]
        if let x, let y {
            event["x"] = x
            event["y"] = y
        }
        recordedEvents.append(event)
        if let data = try? JSONSerialization.data(withJSONObject: recordedEvents, options: [.prettyPrinted]) {
            try? data.write(to: recorder.directory.appendingPathComponent("events.json"))
        }
    }

    /// TABULA_DEBUG_RECORD: records the workspace window as frame-00001.jpg… at TABULA_DEBUG_RECORD_FPS (default 30).
    static func startRecording() {
        guard let directory = environment["TABULA_DEBUG_RECORD"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fps = environment["TABULA_DEBUG_RECORD_FPS"].flatMap(Double.init) ?? 30
        let recorder = WindowRecorder(directory: URL(fileURLWithPath: directory), fps: fps)
        self.recorder = recorder
        // Which windows to capture is read on the main thread; capturing and encoding happen on the recorder's own
        // queue, so they neither slow the app down nor fall behind it.
        Timer.scheduledTimer(withTimeInterval: 1 / (fps * 2), repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = targetWindow else { return }
                recorder.target = .init(id: CGWindowID(window.windowNumber), size: window.frame.size)
            }
        }
        recorder.start()
    }

    /// TABULA_DEBUG_SEASON_ICON: a PNG path; writes the Halloween icon there at 1024×1024 and quits (for the Halloween
    /// video, scripts/render-halloween.sh, and for checking the artwork).
    static func exportSeasonalIcon() {
        guard let path = environment["TABULA_DEBUG_SEASON_ICON"] else { return }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1024,
            pixelsHigh: 1024,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let image = SeasonalIcon.image(for: .halloween) else {
            print("SEASON ICON failed")
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("SEASON ICON", path)
            exit(0)
        } catch {
            print("SEASON ICON failed:", error.localizedDescription)
            exit(1)
        }
    }

    static func startSnapshots() {
        guard let directory = environment["TABULA_DEBUG_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard environment["TABULA_DEBUG_KEYS"] == nil else { return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    guard let rep = windowServerImage(window) ?? cachedImage(window) else { continue }
                    let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
                    let safe = name.replacingOccurrences(of: "/", with: "-")
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(safe).png"))
                }
            }
        }
    }

    static func snapshotKeyWindow(_ name: String) {
        // A sheet on the window is what the step is about.
        guard let directory = environment["TABULA_DEBUG_SNAPSHOT"],
            let window = (targetWindow ?? NSApp.keyWindow).map({ $0.attachedSheet ?? $0 }),
            let rep = windowServerImage(window) ?? cachedImage(window)
        else { return }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("step-\(name).png"))
        print("SNAP", name)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Window-server capture includes vibrancy; an app may capture its own windows without extra permission.
    /// The symbol is looked up at runtime because newer SDKs mark it unavailable.
    private static func windowServerImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// Captures a window (and the app's sheets, menus and popovers over it) at a steady rate on a queue of its own. Frames are numbered by the clock,
/// not by captures: frame n shows the window at (n - 1) / fps seconds, and a capture that runs late fills the frames
/// it missed with the picture before, so recordings play back at the speed things happened.
final class WindowRecorder: @unchecked Sendable {
    struct Target {
        var id: CGWindowID
        var size: CGSize
    }

    let directory: URL
    private let fps: Double
    private let started = Date()
    private let queue = DispatchQueue(label: "app.tabula.debug.recorder", qos: .userInitiated)
    private let lock = NSLock()
    private var _target: Target?
    private var timer: DispatchSourceTimer?
    private var written = 0
    private var last: Data?

    init(directory: URL, fps: Double) {
        self.directory = directory
        self.fps = fps
    }

    var target: Target? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }

    /// The frame showing this moment.
    var currentFrame: Int { Int(Date().timeIntervalSince(started) * fps) + 1 }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.capture() }
        timer.resume()
        self.timer = timer
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let create: CreateImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    private static func image(of id: CGWindowID) -> CGImage? {
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        create?(.null, 1 << 3, id, 1 << 0)?.takeRetainedValue()
    }

    /// The app's own windows in front of the target and over it (sheets, menus, popovers), back to front, with where
    /// they are on it: points from its top left.
    private static func overlays(above id: CGWindowID) -> [(id: CGWindowID, rect: CGRect)] {
        func bounds(_ info: [String: Any]) -> CGRect? {
            (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        guard let below = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
            let frame = below.first.flatMap(bounds),
            let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, id) as? [[String: Any]]
        else { return [] }
        let pid = Int(getpid())
        return above.reversed()
            .compactMap { info in
                guard info[kCGWindowOwnerPID as String] as? Int == pid,
                    let number = info[kCGWindowNumber as String] as? Int,
                    let rect = bounds(info), rect.intersects(frame)
                else { return nil }
                return (CGWindowID(number), rect.offsetBy(dx: -frame.minX, dy: -frame.minY))
            }
    }

    private func capture() {
        let frame = currentFrame
        guard frame > written, let target, let window = Self.image(of: target.id) else { return }
        var picture = window
        let overlays = Self.overlays(above: target.id)
        if !overlays.isEmpty,
            let context = CGContext(
                data: nil,
                width: window.width,
                height: window.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        {
            // Over the window, keeping the overlays' transparent rounded corners and shadows.
            let scale = CGFloat(window.width) / target.size.width
            context.draw(window, in: CGRect(x: 0, y: 0, width: window.width, height: window.height))
            for overlay in overlays {
                guard let image = Self.image(of: overlay.id) else { continue }
                let rect = overlay.rect
                context.draw(
                    image,
                    in: CGRect(
                        x: rect.minX * scale,
                        y: (target.size.height - rect.maxY) * scale,
                        width: rect.width * scale,
                        height: rect.height * scale
                    )
                )
            }
            picture = context.makeImage() ?? window
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            destination,
            picture,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return }
        // Frames missed while this one was taken show the picture before.
        for missed in (written + 1)..<frame {
            write(last ?? data as Data, frame: missed)
        }
        write(data as Data, frame: frame)
        written = frame
        last = data as Data
    }

    private func write(_ data: Data, frame: Int) {
        try? data.write(to: directory.appendingPathComponent(String(format: "frame-%05d.jpg", frame)))
    }
}
#endif
