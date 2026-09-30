import AppKit
import CoreServices
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

let appName = "PPTX MacToWindows Fix"
let outputSuffix = "_windows"
let supportURL = URL(string: "https://buymeacoffee.com/filiphaegdorens")!

// MARK: - Files

func isCandidate(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard url.pathExtension.lowercased() == "pptx", !name.hasPrefix("~$"), !name.hasPrefix(".") else { return false }
    return !url.deletingPathExtension().lastPathComponent.hasSuffix(outputSuffix)
}

func outputURL(for input: URL) -> URL {
    let stem = input.deletingPathExtension().lastPathComponent
    return input.deletingLastPathComponent().appendingPathComponent(stem + outputSuffix + ".pptx")
}

func modificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

func fileSize(_ url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
}

func summary(_ fixed: [FixedImage]) -> String {
    fixed.count == 1 ? "1 image sharpened" : "\(fixed.count) images sharpened"
}

// MARK: - Command line (used by the tests)

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--fix" {
    let input = URL(fileURLWithPath: args[2])
    let output = args.count >= 4 ? URL(fileURLWithPath: args[3]) : outputURL(for: input)
    do {
        let fixed = try PPTXFixer.fix(input: input, output: output)
        if fixed.isEmpty {
            print("nothing to fix")
        } else {
            for f in fixed { print("\(f.oldPath) -> \(f.newPath) \(f.width)x\(f.height)") }
            print("output: \(output.path)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
if args.count >= 3, args[1] == "--fix-all" {
    // Same as dropping several files at once: each gets name_windows.pptx next to it.
    var failures = 0
    for path in args.dropFirst(2) {
        let input = URL(fileURLWithPath: path)
        do {
            let fixed = try PPTXFixer.fix(input: input, output: outputURL(for: input))
            print("\(input.lastPathComponent): " + (fixed.isEmpty ? "nothing to fix" : summary(fixed)))
        } catch {
            failures += 1
            print("\(input.lastPathComponent): failed: \(error)")
        }
    }
    exit(failures == 0 ? 0 : 1)
}
if args.count >= 2, args[1] == "--version" {
    print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                         NSDraggingDestination, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "pptxfix.work")
    private var stream: FSEventStreamRef?
    private var pendingScan: DispatchWorkItem?
    private var openedWithFiles = false
    private var lastResult = "Nothing fixed yet"
    private let defaults = UserDefaults.standard

    // Only touched on the work queue.
    private var skipped: [String: Double] = [:]   // path -> modification time of a version that needed nothing / failed

    private var watchFolder: URL? {
        get { defaults.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "watchFolder") }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedWithFiles = true
        fixManually(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        skipped = (defaults.dictionary(forKey: "skipped") as? [String: Double]) ?? [:]

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: appName)
            button.image?.isTemplate = true
            button.toolTip = "\(appName): drop a presentation here"
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if let folder = watchFolder { startWatching(folder) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.defaults.bool(forKey: "welcomeShown") && !self.openedWithFiles { self.showWelcome() }
        }
    }

    /// Opening the app again (Finder, Launchpad, Spotlight) shows the main options,
    /// useful when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(appName) is running"
        var text = "It lives in the menu bar as a magic wand icon. Drop presentations on that icon, or on the app in Finder."
        if let folder = watchFolder { text += "\n\nWatched folder: \(folder.path)" }
        a.informativeText = text
        a.addButton(withTitle: "Fix Presentation…")
        a.addButton(withTitle: watchFolder == nil ? "Choose Folder…" : "Choose Another Folder…")
        a.addButton(withTitle: "Close")
        switch a.runModal() {
        case .alertFirstButtonReturn: chooseFiles()
        case .alertSecondButtonReturn: chooseFolder()
        default: break
        }
        return false
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info("Drop a presentation on the icon above"))
        menu.addItem(item("Fix Presentation…", #selector(chooseFiles)))
        menu.addItem(.separator())
        if let folder = watchFolder {
            menu.addItem(info("Watched folder: \(folder.lastPathComponent)"))
            menu.addItem(item("Show Folder in Finder", #selector(revealFolder)))
            menu.addItem(item("Choose Another Folder…", #selector(chooseFolder)))
            menu.addItem(item("Stop Watching", #selector(stopWatchingFolder)))
        } else {
            menu.addItem(info("No watched folder"))
            menu.addItem(item("Choose Folder to Fix Automatically…", #selector(chooseFolder)))
        }
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(info("Last: \(lastResult)"))
        menu.addItem(.separator())
        menu.addItem(item("Buy Me a Coffee…", #selector(buyCoffee)))
        menu.addItem(item("About \(appName)", #selector(about)))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "pptx") { panel.allowedContentTypes = [t] }
        panel.message = "Choose the presentations you want to show on Windows."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { fixManually(panel.urls) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Watch This Folder"
        panel.message = "Every presentation in this folder (and its subfolders) automatically gets a Windows version next to it."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watchFolder = url
        startWatching(url)
    }

    @objc private func revealFolder() {
        if let f = watchFolder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    @objc private func stopWatchingFolder() {
        stopWatching()
        watchFolder = nil
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            alert("Open at Login could not be set", "\(error.localizedDescription)\n\nYou can also turn it on in System Settings > General > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func buyCoffee() { NSWorkspace.shared.open(supportURL) }

    @objc private func about() {
        let credits = NSMutableAttributedString(
            string: "Makes PDF clips pasted in PowerPoint for Mac sharp on Windows. Your original is never changed; the Windows version gets \"\(outputSuffix)\" in its name.\n\nFree to use. If it saves you time, you can buy me a coffee.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let link = "buy me a coffee"
        let range = (credits.string as NSString).range(of: link)
        if range.location != NSNotFound { credits.addAttribute(.link, value: supportURL, range: range) }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showWelcome() {
        defaults.set(true, forKey: "welcomeShown")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(appName) is now in the menu bar"
        a.informativeText = """
        Look for the magic wand icon at the top right of your screen.

        Drop one or more presentations (or a folder) on that icon, or choose a folder to watch: every presentation that lands there automatically gets a sharp Windows version next to it (name\(outputSuffix).pptx). Your original is never changed.
        """
        let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
        login.state = .on
        a.accessoryView = login
        a.addButton(withTitle: "Choose Folder…")
        a.addButton(withTitle: "Not Now")
        let answer = a.runModal()
        if login.state == .on, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if answer == .alertFirstButtonReturn { chooseFolder() }
    }

    // MARK: Drag and drop on the menu bar icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        fixManually(urls)
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.hasDirectoryPath || $0.pathExtension.lowercased() == "pptx" }
    }

    // MARK: Fixing

    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if isCandidate(f) { result.append(f) }
                }
            } else if isCandidate(url) {
                result.append(url)
            }
        }
        return result
    }

    private func fixManually(_ urls: [URL]) {
        let files = expand(urls)
        if files.isEmpty {
            notify("No presentation found", "Drop a .pptx file (not one that already ends in \(outputSuffix)).", path: nil, fallbackAlert: true)
            return
        }
        work.async { [weak self] in
            guard let self else { return }
            var done: [(output: URL, images: Int)] = []
            var nothing: [String] = []
            var failed: [String] = []
            for file in files {
                let out = outputURL(for: file)
                do {
                    let fixed = try PPTXFixer.fix(input: file, output: out)
                    if fixed.isEmpty { nothing.append(file.lastPathComponent) } else { done.append((out, fixed.count)) }
                } catch {
                    failed.append("\(file.lastPathComponent): \(error)")
                }
            }
            DispatchQueue.main.async { self.report(done: done, nothing: nothing, failed: failed) }
        }
    }

    /// One message per drop, however many files it contained.
    private func report(done: [(output: URL, images: Int)], nothing: [String], failed: [String]) {
        let total = done.count + nothing.count + failed.count
        let images = done.reduce(0) { $0 + $1.images }
        let imageText = images == 1 ? "1 image sharpened" : "\(images) images sharpened"

        if total == 1 {
            if let d = done.first {
                lastResult = "\(d.output.lastPathComponent) (\(imageText))"
                notify("Windows version ready", "\(d.output.lastPathComponent): \(imageText).", path: d.output.path, fallbackAlert: true)
            } else if let n = nothing.first {
                lastResult = "\(n): nothing to fix"
                notify("Nothing to fix", "\(n) has no Mac images that turn blurry on Windows.", path: nil, fallbackAlert: true)
            } else if let f = failed.first {
                lastResult = "fixing failed"
                notify("Fixing failed", f, path: nil, fallbackAlert: true)
            }
            return
        }

        var lines: [String] = []
        if !done.isEmpty { lines.append("\(done.count) Windows version\(done.count == 1 ? "" : "s") created (\(imageText)).") }
        if !nothing.isEmpty { lines.append("\(nothing.count) had nothing to fix.") }
        if !failed.isEmpty { lines.append("\(failed.count) failed.") }
        lastResult = "\(done.count) of \(total) presentations fixed"
        let title = failed.isEmpty ? "\(total) presentations processed" : "\(total) presentations processed, \(failed.count) failed"
        notify(title, lines.joined(separator: " "), path: done.first?.output.path, fallbackAlert: failed.isEmpty)
        if !failed.isEmpty {
            // Failures in a batch get a window, so the reasons can be read.
            alert(title, (lines + [""] + failed).joined(separator: "\n"), reveal: done.first?.output.path)
        }
    }

    // MARK: Watched folder

    private func startWatching(_ folder: URL) {
        stopWatching()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().scheduleScan(after: 3)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
        scheduleScan(after: 1)   // catch up on anything that changed while the app was not running
    }

    private func stopWatching() {
        pendingScan?.cancel()
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
    }

    fileprivate func scheduleScan(after seconds: Double) {
        pendingScan?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let folder = self.watchFolder else { return }
            self.work.async { self.scan(folder) }
        }
        pendingScan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Runs on the work queue.
    private func scan(_ folder: URL) {
        var retryLater = false
        var done: [(output: URL, images: Int)] = []
        var failed: [String] = []
        // Presentations that are new or changed since their Windows version was made.
        var todo: [(file: URL, mtime: Double, size: Int?)] = []
        for file in expand([folder]) {
            guard let mtime = modificationDate(file)?.timeIntervalSince1970 else { continue }
            if let outTime = modificationDate(outputURL(for: file))?.timeIntervalSince1970, outTime >= mtime { continue }
            if skipped[file.path] == mtime { continue }
            todo.append((file, mtime, fileSize(file)))
        }
        // Wait until PowerPoint, OneDrive or iCloud has finished writing (one wait for all).
        if !todo.isEmpty { Thread.sleep(forTimeInterval: 2) }

        for (file, mtime, size) in todo {
            let out = outputURL(for: file)
            guard fileSize(file) == size, modificationDate(file)?.timeIntervalSince1970 == mtime else {
                retryLater = true
                continue
            }

            do {
                let fixed = try PPTXFixer.fix(input: file, output: out)
                if fixed.isEmpty {
                    skipped[file.path] = mtime
                } else {
                    skipped[file.path] = nil
                    done.append((out, fixed.count))
                }
            } catch {
                skipped[file.path] = mtime   // try again once the file changes
                failed.append("\(file.lastPathComponent): \(error)")
            }
        }
        if !done.isEmpty || !failed.isEmpty {
            let d = done, f = failed
            DispatchQueue.main.async { self.reportWatched(done: d, failed: f) }
        }
        // Forget files that no longer exist, then save.
        skipped = skipped.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = skipped
        DispatchQueue.main.async {
            self.defaults.set(snapshot, forKey: "skipped")
            if retryLater { self.scheduleScan(after: 5) }
        }
    }

    /// Watched folder: one notification per scan, no windows (nobody may be watching).
    private func reportWatched(done: [(output: URL, images: Int)], failed: [String]) {
        let images = done.reduce(0) { $0 + $1.images }
        let imageText = images == 1 ? "1 image sharpened" : "\(images) images sharpened"
        if done.count == 1 && failed.isEmpty, let d = done.first {
            lastResult = "\(d.output.lastPathComponent) (\(imageText))"
            notify("Windows version ready", "\(d.output.lastPathComponent): \(imageText).", path: d.output.path, fallbackAlert: false)
            return
        }
        var lines: [String] = []
        if !done.isEmpty { lines.append("\(done.count) Windows version\(done.count == 1 ? "" : "s") created (\(imageText)).") }
        lines += failed.map { "Failed: \($0)" }
        lastResult = failed.isEmpty ? "\(done.count) presentations fixed" : "\(done.count) fixed, \(failed.count) failed"
        notify(failed.isEmpty ? "Windows versions ready" : "Some presentations could not be fixed",
               lines.joined(separator: "\n"), path: done.first?.output.path, fallbackAlert: false)
    }

    // MARK: Notifications

    private func notify(_ title: String, _ body: String, path: String?, fallbackAlert: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    if let path { content.userInfo = ["path": path] }
                    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                } else if fallbackAlert {
                    self.alert(title, body, reveal: path)
                }
            }
        }
    }

    private func alert(_ title: String, _ body: String, reveal path: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        if path != nil { a.addButton(withTitle: "Show in Finder") }
        if a.runModal() == .alertSecondButtonReturn, let path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
