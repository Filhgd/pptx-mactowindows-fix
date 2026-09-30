import AppKit
import SwiftUI

/// Renders the window in several states, in light and dark mode, to PNG files.
/// Used by the tests to review the design without a screen.
func renderSnapshots(to dir: URL) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let talks = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Talks")
    func job(_ name: String, _ state: Job.State, _ source: Job.Source = .manual) -> Job {
        let input = talks.appendingPathComponent(name + ".pptx")
        return Job(input: input, output: outputURL(for: input), source: source, state: state)
    }
    func model(_ configure: (AppModel) -> Void) -> AppModel {
        let m = AppModel()
        configure(m)
        return m
    }

    let states: [(String, AppModel)] = [
        ("1-empty", model { _ in }),
        ("2-dragging", model { $0.dropTargeted = true }),
        ("3-busy", model { m in
            m.batch = BatchProgress(total: 5, finished: 1, current: "Lecture 3 - Frailty in older adults.pptx")
            m.jobs = [job("Lecture 3 - Frailty in older adults", .working),
                      job("Lecture 4 - Early warning scores", .queued),
                      job("Lecture 2 - Vital signs", .done(images: 4))]
        }),
        ("4-results", model { m in
            m.watchFolder = talks
            m.openAtLogin = true
            m.update = ReleaseInfo(version: "1.3.0", pageURL: URL(string: "https://github.com")!, downloadURL: nil, notes: "")
            m.jobs = [job("Conference talk ESICM", .done(images: 10)),
                      job("Team meeting", .nothing),
                      job("Old deck", .failed("This is not a valid PowerPoint file (.pptx).")),
                      job("Guest lecture", .done(images: 1), .watched)]
        }),
        ("5-wrong-file", model { $0.dropMessage = "Only PowerPoint presentations (.pptx) can be fixed." }),
        ("6-readme", model { m in
            m.watchFolder = talks
            m.openAtLogin = true
            m.jobs = [job("Conference talk", .done(images: 10)),
                      job("Guest lecture", .done(images: 3), .watched),
                      job("Team meeting", .nothing)]
        }),
    ]

    for (name, m) in states {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            render(MainView().environmentObject(m), size: NSSize(width: 480, height: 660), appearance: appearance,
                   to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
    let onboardingModel = AppModel()
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        render(OnboardingView().environmentObject(onboardingModel), size: nil, appearance: appearance,
               to: dir.appendingPathComponent("0-welcome-\(suffix).png"))
    }
}

private func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance.Name, to url: URL) {
    let hosting = NSHostingView(rootView: view)
    let s = size ?? hosting.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: s),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: s)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    hosting.layoutSubtreeIfNeeded()
    // Capture the whole window frame (including the window buttons) when possible.
    let target: NSView = window.contentView?.superview ?? hosting
    // Always at Retina resolution (2x), also on a build server without a Retina screen.
    let bounds = target.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = bounds.size
    target.cacheDisplay(in: bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
    }
    window.orderOut(nil)
}
