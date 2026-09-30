import AppKit
import SwiftUI
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
if args.count >= 3, args[1] == "--compare" {
    // --compare CANDIDATE CURRENT: prints "newer" or "not newer" (used by the tests)
    print(Updater.isNewer(args[2], than: args.count >= 4 ? args[3] : Updater.currentVersion) ? "newer" : "not newer")
    exit(0)
}
if args.count >= 2, args[1] == "--check-update" {
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Updater.fetchLatest { result in
        switch result {
        case .success(let r):
            let newer = Updater.isNewer(r.version, than: Updater.currentVersion)
            print("current \(Updater.currentVersion), latest \(r.version): " + (newer ? "update available" : "up to date"))
            print("download: \(r.downloadURL?.absoluteString ?? r.pageURL.absoluteString)")
            print("notes: " + Updater.plainNotes(r.notes).replacingOccurrences(of: "\n", with: " | "))
        case .failure(let e):
            print("error: \(e)")
            code = 2
        }
        done.signal()
    }
    done.wait()
    exit(code)
}
if args.count >= 3, args[1] == "--render-ui" {
    // Screenshots of the window in several states, light and dark (used by the tests).
    renderSnapshots(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
if args.count >= 2, args[1] == "--version" {
    print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    exit(0)
}


// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                         NSDraggingDestination, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "pptxfix.work")
    private var stream: FSEventStreamRef?
    private var pendingScan: DispatchWorkItem?
    private var launchedAtLogin = false
    private var openedWithFiles = false
    private let defaults = UserDefaults.standard
    private var updateTimer: Timer?
    private var batchJobs: [UUID] = []   // manual jobs of the batch in progress

    // Only touched on the work queue.
    private var skipped: [String: Double] = [:]   // path -> modification time of a version that needed nothing / failed

    private let onboardingKey = "onboardingV2Done"

    private var watchFolder: URL? {
        get { defaults.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            defaults.set(newValue?.path, forKey: "watchFolder")
            model.watchFolder = newValue
        }
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started by macOS at login: stay quietly in the menu bar.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
        if ProcessInfo.processInfo.systemUptime < 120 { launchedAtLogin = true }
        buildMainMenu()
        wireModel()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedWithFiles = true
        showWindow()
        process(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        skipped = (defaults.dictionary(forKey: "skipped") as? [String: Double]) ?? [:]

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: appName)
            button.image?.isTemplate = true
            button.toolTip = appName
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        menu.delegate = self
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        model.watchFolder = watchFolder
        model.openAtLogin = SMAppService.mainApp.status == .enabled
        if let folder = watchFolder { startWatching(folder) }

        // Daily update check: first shortly after launch, then re-evaluated every hour.
        defaults.register(defaults: ["autoUpdateCheck": true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkForUpdatesIfDue() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdatesIfDue()
        }

        if !defaults.bool(forKey: onboardingKey) {
            model.showOnboarding = true
            showWindow()
        } else {
            requestNotifications()
            if !launchedAtLogin && !openedWithFiles { showWindow() }
        }
    }

    /// Clicking the app in Finder, the Dock or Launchpad while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func wireModel() {
        model.onDrop = { [weak self] urls in self?.process(urls) }
        model.onChooseFiles = { [weak self] in self?.chooseFiles() }
        model.onChooseFolder = { [weak self] in self?.chooseFolder() }
        model.onStopWatching = { [weak self] in self?.stopWatchingFolder() }
        model.onSetOpenAtLogin = { [weak self] on in self?.setOpenAtLogin(on) }
        model.onShowUpdate = { [weak self] in self?.showUpdateFromMenu() }
        model.onDownloadUpdate = { [weak self] in self?.downloadUpdate() }
        model.onFinishOnboarding = { [weak self] login in
            guard let self else { return }
            self.defaults.set(true, forKey: self.onboardingKey)
            self.model.showOnboarding = false
            self.setOpenAtLogin(login)
            self.requestNotifications()
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Window

    private func makeWindowIfNeeded() -> NSWindow {
        if let w = window { return w }
        let hosting = NSHostingController(rootView: MainView().environmentObject(model))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = appName
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 480, height: 660))
        w.center()
        w.setFrameAutosaveName("MainWindow")
        window = w
        return w
    }

    @objc func showWindow() {
        let w = makeWindowIfNeeded()
        // While the window is open the app is in the Dock too (also a drop target).
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // Back to the menu bar only.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    private var windowIsFront: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && NSApp.isActive
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesManually), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Buy Me a Coffee…", action: #selector(buyCoffee), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Choose Folder to Fix Automatically…", action: #selector(chooseFolder), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: appName, action: #selector(showWindow), keyEquivalent: "1").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Menu bar menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = item("Open \(appName)", #selector(showWindow))
        open.attributedTitle = NSAttributedString(string: open.title,
                                                  attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(open)
        if let update = model.update {
            menu.addItem(item("Update Available: Version \(update.version)…", #selector(showUpdateFromMenu)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Choose Files…", #selector(chooseFiles)))
        if let folder = watchFolder {
            menu.addItem(info("Fixing automatically: \(folder.lastPathComponent)"))
            menu.addItem(item("Show Folder in Finder", #selector(revealFolder)))
            menu.addItem(item("Stop Fixing Automatically", #selector(stopWatchingFolder)))
        } else {
            menu.addItem(item("Choose Folder to Fix Automatically…", #selector(chooseFolder)))
        }
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Check for Updates…", #selector(checkForUpdatesManually)))
        let auto = item("Check for Updates Automatically", #selector(toggleAutoUpdate))
        auto.state = defaults.bool(forKey: "autoUpdateCheck") ? .on : .off
        menu.addItem(auto)
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

    // MARK: Actions

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if let t = UTType(filenameExtension: "pptx") { panel.allowedContentTypes = [t] }
        panel.prompt = "Fix"
        panel.message = "Choose presentations (or a folder) to make a sharp Windows copy of."
        runPanel(panel) { [weak self] in self?.process(panel.urls) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Fix Automatically"
        panel.message = "Every presentation saved in this folder (or a subfolder) automatically gets a sharp Windows copy next to it."
        runPanel(panel) { [weak self] in
            guard let self, let url = panel.url else { return }
            self.watchFolder = url
            self.startWatching(url)
        }
    }

    /// As a sheet on the window when it is open, otherwise as a separate dialog.
    private func runPanel(_ panel: NSOpenPanel, onOK: @escaping () -> Void) {
        if let w = window, w.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.beginSheetModal(for: w) { if $0 == .OK { onOK() } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK { onOK() }
        }
    }

    @objc private func revealFolder() {
        if let f = watchFolder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    @objc private func stopWatchingFolder() {
        stopWatching()
        watchFolder = nil
    }

    @objc private func toggleLogin() {
        setOpenAtLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on && service.status != .enabled { try service.register() }
            if !on && service.status == .enabled { try service.unregister() }
        } catch {
            alert("Open at Login could not be set", "\(error.localizedDescription)\n\nYou can also turn it on in System Settings > General > Login Items.")
        }
        if on && service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        model.openAtLogin = service.status == .enabled
    }

    @objc private func buyCoffee() { NSWorkspace.shared.open(supportURL) }

    @objc private func about() {
        let credits = NSMutableAttributedString(
            string: "Makes PDF clips pasted in PowerPoint for Mac sharp on Windows. Your original is never changed; the Windows version gets \"\(outputSuffix)\" in its name.\n\nFree to use. If it saves you time, you can buy me a coffee.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let range = (credits.string as NSString).range(of: "buy me a coffee")
        if range.location != NSNotFound { credits.addAttribute(.link, value: supportURL, range: range) }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Updates

    private func checkForUpdatesIfDue() {
        guard defaults.bool(forKey: "autoUpdateCheck") else { return }
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Updater.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case .success(let release) = result else { return }   // silent: try again later
                self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                guard Updater.isNewer(release.version, than: Updater.currentVersion),
                      self.defaults.string(forKey: "skippedVersion") != release.version else {
                    self.model.update = nil
                    return
                }
                self.model.update = release
                if self.defaults.string(forKey: "notifiedVersion") != release.version {
                    self.defaults.set(release.version, forKey: "notifiedVersion")
                    if !self.windowIsFront {
                        self.notify("Update available", "\(appName) \(release.version) is available. Click to see what's new.",
                                    userInfo: ["update": true])
                    }
                }
            }
        }
    }

    @objc private func showUpdateFromMenu() {
        if let u = model.update { showUpdateAlert(u) }
    }

    private func downloadUpdate() {
        if let u = model.update { NSWorkspace.shared.open(u.downloadURL ?? u.pageURL) }
    }

    @objc private func checkForUpdatesManually() {
        Updater.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let release):
                    self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                    if Updater.isNewer(release.version, than: Updater.currentVersion) {
                        self.model.update = release
                        self.showUpdateAlert(release)
                    } else {
                        self.model.update = nil
                        self.alert("You're up to date", "\(appName) \(Updater.currentVersion) is the latest version.")
                    }
                case .failure(let error):
                    self.alert("Could not check for updates", "\(error.localizedDescription)\n\nYou can also look at github.com/\(Updater.repository)/releases")
                }
            }
        }
    }

    @objc private func toggleAutoUpdate() {
        defaults.set(!defaults.bool(forKey: "autoUpdateCheck"), forKey: "autoUpdateCheck")
    }

    private func showUpdateAlert(_ release: ReleaseInfo) {
        let a = NSAlert()
        a.messageText = "\(appName) \(release.version) is available"
        var text = "You have version \(Updater.currentVersion)."
        let notes = Updater.plainNotes(release.notes)
        if !notes.isEmpty { text += "\n\nWhat's new:\n\(notes)" }
        text += "\n\nTo install: quit this app, unzip the download and replace the app in Applications."
        a.informativeText = text
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
            case .alertThirdButtonReturn:
                self.defaults.set(release.version, forKey: "skippedVersion")
                self.model.update = nil
            default:
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
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
        showWindow()
        process(urls)
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.hasDirectoryPath || $0.pathExtension.lowercased() == "pptx" }
    }

    // MARK: Fixing (drop, Choose Files, Finder)

    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
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

    /// Main thread. Adds the files to the list and fixes them one after the other.
    private func process(_ urls: [URL]) {
        let files = expand(urls)
        if files.isEmpty {
            let onlyCopies = !urls.isEmpty && urls.allSatisfy {
                $0.pathExtension.lowercased() == "pptx" && $0.deletingPathExtension().lastPathComponent.hasSuffix(outputSuffix)
            }
            model.flash(onlyCopies ? "That is already a Windows copy. Drop the original presentation."
                                   : "Only PowerPoint presentations (.pptx) can be fixed.")
            return
        }
        let jobs = files.map { Job(input: $0, output: outputURL(for: $0), source: .manual, state: .queued) }
        withAnimation(.easeOut(duration: 0.2)) { model.add(jobs) }
        batchJobs += jobs.map { $0.id }
        let previous = model.batch
        model.batch = BatchProgress(total: (previous?.total ?? 0) + jobs.count,
                                    finished: previous?.finished ?? 0,
                                    current: previous?.current ?? jobs[0].input.lastPathComponent)

        for job in jobs {
            work.async { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.model.setState(job.id, .working)
                    self.model.batch?.current = job.input.lastPathComponent
                }
                let state = self.fix(job)
                DispatchQueue.main.async { self.finished(job, state) }
            }
        }
    }

    /// Work queue.
    private func fix(_ job: Job) -> Job.State {
        do {
            let fixed = try PPTXFixer.fix(input: job.input, output: job.output)
            return fixed.isEmpty ? .nothing : .done(images: fixed.count)
        } catch {
            return .failed("\(error)")
        }
    }

    private func finished(_ job: Job, _ state: Job.State) {
        withAnimation(.easeOut(duration: 0.15)) { model.setState(job.id, state) }
        guard var batch = model.batch else { return }
        batch.finished += 1
        if batch.finished >= batch.total {
            model.batch = nil
            reportBatch(batchJobs)
            batchJobs = []
        } else {
            model.batch = batch
        }
    }

    /// Only when the window is not in front; otherwise the list already shows everything.
    private func reportBatch(_ ids: [UUID]) {
        guard !windowIsFront else { return }
        let jobs = model.jobs.filter { ids.contains($0.id) }
        let done = jobs.filter { $0.isDone }
        let failed = jobs.filter { if case .failed = $0.state { return true } else { return false } }
        let images = done.reduce(0) { total, job in
            if case .done(let n) = job.state { return total + n } else { return total }
        }
        let imageText = images == 1 ? "1 image sharpened" : "\(images) images sharpened"
        if jobs.count == 1, let d = done.first {
            notify("Windows version ready", "\(d.output.lastPathComponent): \(imageText).", userInfo: ["path": d.output.path])
            return
        }
        var lines: [String] = []
        if !done.isEmpty { lines.append("\(done.count) Windows version\(done.count == 1 ? "" : "s") created (\(imageText)).") }
        let nothing = jobs.count - done.count - failed.count
        if nothing > 0 { lines.append("\(nothing) had nothing to fix.") }
        if !failed.isEmpty { lines.append("\(failed.count) could not be fixed.") }
        notify(jobs.count == 1 ? "Done" : "\(jobs.count) presentations processed", lines.joined(separator: " "), userInfo: ["window": true])
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

    /// Work queue.
    private func scan(_ folder: URL) {
        var retryLater = false
        var reported: [Job] = []
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
            guard fileSize(file) == size, modificationDate(file)?.timeIntervalSince1970 == mtime else {
                retryLater = true
                continue
            }
            var job = Job(input: file, output: outputURL(for: file), source: .watched, state: .working)
            job.state = fix(job)
            switch job.state {
            case .done:
                skipped[file.path] = nil
                reported.append(job)
            case .failed:
                skipped[file.path] = mtime   // try again once the file changes
                reported.append(job)
            default:
                skipped[file.path] = mtime
            }
        }
        skipped = skipped.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = skipped
        let jobs = reported
        DispatchQueue.main.async {
            self.defaults.set(snapshot, forKey: "skipped")
            if !jobs.isEmpty {
                withAnimation { self.model.add(jobs) }
                self.reportWatched(jobs)
            }
            if retryLater { self.scheduleScan(after: 5) }
        }
    }

    /// One notification per scan, only when the window is not in front.
    private func reportWatched(_ jobs: [Job]) {
        guard !windowIsFront else { return }
        let done = jobs.filter { $0.isDone }
        let failed = jobs.count - done.count
        if done.count == 1 && failed == 0, let d = done.first {
            notify("Windows version ready", "\(d.output.lastPathComponent): \(d.detail).", userInfo: ["path": d.output.path])
            return
        }
        var lines: [String] = []
        if !done.isEmpty { lines.append("\(done.count) Windows version\(done.count == 1 ? "" : "s") created.") }
        if failed > 0 { lines.append("\(failed) could not be fixed. Open the app for details.") }
        notify(failed == 0 ? "Windows versions ready" : "Some presentations could not be fixed",
               lines.joined(separator: " "), userInfo: ["window": true])
    }

    // MARK: Notifications

    private func notify(_ title: String, _ body: String, userInfo: [String: Any]) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = userInfo
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let path = info["path"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else if info["update"] as? Bool == true {
                self.showWindow()
                self.showUpdateFromMenu()
            } else {
                self.showWindow()
            }
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
