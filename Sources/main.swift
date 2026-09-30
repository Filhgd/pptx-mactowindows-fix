import AppKit
import CoreServices
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

let appName = "PPTX MacToWindows Fix"
let outputSuffix = "_windows"

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
    fixed.count == 1 ? "1 afbeelding verscherpt" : "\(fixed.count) afbeeldingen verscherpt"
}

// MARK: - Command line (used by the tests)

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--fix" {
    let input = URL(fileURLWithPath: args[2])
    let output = args.count >= 4 ? URL(fileURLWithPath: args[3]) : outputURL(for: input)
    do {
        let fixed = try PPTXFixer.fix(input: input, output: output)
        if fixed.isEmpty {
            print("niets te repareren")
        } else {
            for f in fixed { print("\(f.oldPath) -> \(f.newPath) \(f.width)x\(f.height)") }
            print("output: \(output.path)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("fout: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
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
    private var lastResult = "Nog niets gerepareerd"
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
            button.toolTip = "\(appName): sleep hier een presentatie op"
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

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info("Sleep een presentatie op het icoon hierboven"))
        menu.addItem(item("Presentatie repareren…", #selector(chooseFiles)))
        menu.addItem(.separator())
        if let folder = watchFolder {
            menu.addItem(info("Bewaakte map: \(folder.lastPathComponent)"))
            menu.addItem(item("Map tonen in Finder", #selector(revealFolder)))
            menu.addItem(item("Andere map kiezen…", #selector(chooseFolder)))
            menu.addItem(item("Stop met bewaken", #selector(stopWatchingFolder)))
        } else {
            menu.addItem(info("Geen bewaakte map"))
            menu.addItem(item("Map kiezen om automatisch te repareren…", #selector(chooseFolder)))
        }
        menu.addItem(.separator())
        let login = item("Starten bij inloggen", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(info("Laatste: \(lastResult)"))
        menu.addItem(.separator())
        menu.addItem(item("Over \(appName)", #selector(about)))
        menu.addItem(item("Stop", #selector(quit), key: "q"))
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
        panel.message = "Kies de presentaties die je op Windows wilt tonen."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { fixManually(panel.urls) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Bewaak deze map"
        panel.message = "Elke presentatie in deze map (en submappen) krijgt automatisch een Windows-versie ernaast."
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
            alert("Starten bij inloggen kon niet ingesteld worden", "\(error.localizedDescription)\n\nJe kan het ook zelf aanzetten in Systeeminstellingen > Algemeen > Inlogonderdelen.")
            SMAppService.openSystemSettingsLoginItems()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Maakt geplakte PDF-knipsels en afbeeldingen uit PowerPoint voor Mac scherp op Windows. Je origineel blijft ongewijzigd; de Windows-versie krijgt \"\(outputSuffix)\" in de naam.")
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showWelcome() {
        defaults.set(true, forKey: "welcomeShown")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(appName) staat nu in de menubalk"
        a.informativeText = """
        Je vindt het toverstaf-icoon rechtsboven in je scherm.

        Sleep een presentatie op dat icoon, of kies een map: elke presentatie die daarin komt, krijgt dan automatisch een scherpe Windows-versie ernaast (naam\(outputSuffix).pptx). Je origineel blijft ongewijzigd.
        """
        let login = NSButton(checkboxWithTitle: "Starten bij inloggen", target: nil, action: nil)
        login.state = .on
        a.accessoryView = login
        a.addButton(withTitle: "Map kiezen…")
        a.addButton(withTitle: "Later")
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
            notify("Geen presentatie gevonden", "Sleep een .pptx-bestand (niet een bestand dat al op \(outputSuffix) eindigt).", path: nil, fallbackAlert: true)
            return
        }
        work.async { [weak self] in
            guard let self else { return }
            for file in files {
                let out = outputURL(for: file)
                do {
                    let fixed = try PPTXFixer.fix(input: file, output: out)
                    DispatchQueue.main.async {
                        if fixed.isEmpty {
                            self.lastResult = "\(file.lastPathComponent): niets te repareren"
                            self.notify("Niets te repareren", "\(file.lastPathComponent) bevat geen Mac-afbeeldingen die op Windows wazig worden.", path: nil, fallbackAlert: true)
                        } else {
                            self.lastResult = "\(out.lastPathComponent) (\(summary(fixed)))"
                            self.notify("Windows-versie klaar", "\(out.lastPathComponent): \(summary(fixed)).", path: out.path, fallbackAlert: true)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.lastResult = "\(file.lastPathComponent): mislukt"
                        self.notify("Repareren mislukt", "\(file.lastPathComponent): \(error)", path: nil, fallbackAlert: true)
                    }
                }
            }
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
        for file in expand([folder]) {
            guard let mtime = modificationDate(file)?.timeIntervalSince1970 else { continue }
            let out = outputURL(for: file)
            if let outTime = modificationDate(out)?.timeIntervalSince1970, outTime >= mtime { continue }
            if skipped[file.path] == mtime { continue }

            // Wait until PowerPoint, OneDrive or iCloud has finished writing.
            let size = fileSize(file)
            Thread.sleep(forTimeInterval: 2)
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
                    DispatchQueue.main.async {
                        self.lastResult = "\(out.lastPathComponent) (\(summary(fixed)))"
                        self.notify("Windows-versie klaar", "\(out.lastPathComponent): \(summary(fixed)).", path: out.path, fallbackAlert: false)
                    }
                }
            } catch {
                skipped[file.path] = mtime   // try again once the file changes
                DispatchQueue.main.async {
                    self.lastResult = "\(file.lastPathComponent): mislukt"
                    self.notify("Repareren mislukt", "\(file.lastPathComponent): \(error)", path: nil, fallbackAlert: false)
                }
            }
        }
        // Forget files that no longer exist, then save.
        skipped = skipped.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = skipped
        DispatchQueue.main.async {
            self.defaults.set(snapshot, forKey: "skipped")
            if retryLater { self.scheduleScan(after: 5) }
        }
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
        if path != nil { a.addButton(withTitle: "Toon in Finder") }
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
