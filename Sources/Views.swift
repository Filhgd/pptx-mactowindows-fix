import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.update != nil {
                UpdateBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            VStack(spacing: 16) {
                HeaderView()
                DropZone()
                ResultsSection()
            }
            .padding(.horizontal, 20)
            .padding(.top, model.update == nil ? 36 : 14)
            .padding(.bottom, 14)
            Divider()
            FooterView()
        }
        .frame(minWidth: 460, idealWidth: 480, maxWidth: 760, minHeight: 600, idealHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        // The whole window accepts drops, not only the drop zone.
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            loadFileURLs(providers) { urls in model.onDrop(urls) }
            return true
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .environmentObject(model)
        }
        .animation(.easeInOut(duration: 0.2), value: model.update?.version)
    }
}

/// Reads file URLs from dropped items; calls back on the main thread with all of them at once.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

struct HeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 17, weight: .semibold))
                Text("Makes images pasted from PDFs sharp on Windows")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let targeted = model.dropTargeted
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 6) {
            ZStack {
                shape.fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
                shape.strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                   style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [7, 5]))
                if let batch = model.batch {
                    BusyContent(batch: batch)
                } else {
                    IdleContent(targeted: targeted)
                }
            }
            .frame(height: 210)
            .scaleEffect(targeted ? 1.015 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
            .contentShape(Rectangle())
            .onTapGesture { if model.batch == nil { model.onChooseFiles() } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drop presentations here, or click to choose files")

            if let message = model.dropMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.dropMessage)
    }
}

struct IdleContent: View {
    @EnvironmentObject var model: AppModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.accentColor)
            Text(targeted ? "Release to fix" : "Drop presentations here")
                .font(.system(size: 16, weight: .semibold))
            Text("One or more .pptx files, or a folder")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("Choose Files…") { model.onChooseFiles() }
                .controlSize(.regular)
                .padding(.top, 4)
                .opacity(targeted ? 0 : 1)
        }
        .padding()
    }
}

struct BusyContent: View {
    let batch: BatchProgress

    var body: some View {
        VStack(spacing: 12) {
            Text(batch.total == 1 ? "Fixing…" : "Fixing \(min(batch.finished + 1, batch.total)) of \(batch.total)…")
                .font(.system(size: 16, weight: .semibold))
            ProgressView(value: Double(batch.finished), total: Double(max(batch.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 240)
            Text(batch.current)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320)
        }
        .padding()
    }
}

// MARK: - Results

struct ResultsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if model.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear") { withAnimation { model.clearFinished() } }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            if model.jobs.isEmpty {
                EmptyResults()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct EmptyResults: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(.secondary.opacity(0.7))
            Text("Fixed copies appear here, next to the originals.\nYou can drag them straight into an email.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }
}

extension Job {
    var isActive: Bool {
        switch state {
        case .queued, .working: return true
        default: return false
        }
    }

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    var title: String { isDone ? output.lastPathComponent : input.lastPathComponent }

    var detail: String {
        let from = source == .watched ? " · watched folder" : ""
        switch state {
        case .queued: return "Waiting…"
        case .working: return "Fixing…"
        case .done(let n): return (n == 1 ? "1 image sharpened" : "\(n) images sharpened") + from
        case .nothing: return "Nothing to fix: already looks the same on Windows" + from
        case .failed(let reason): return reason
        }
    }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    let job: Job
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(state: job.state)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.detail)
                    .font(.system(size: 11))
                    .foregroundColor(isFailure ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if job.isDone {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([job.output])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .opacity(hovering ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if job.isDone { NSWorkspace.shared.open(job.output) } }
        .onDrag {
            // Drag the fixed copy straight into Mail, Teams, Finder...
            NSItemProvider(object: (job.isDone ? job.output : job.input) as NSURL)
        }
        .contextMenu {
            if job.isDone {
                Button("Open") { NSWorkspace.shared.open(job.output) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }
            }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.input]) }
        }
        .help(job.isDone ? "Double-click to open, or drag the file into an email" : job.input.path)
    }

    private var isFailure: Bool {
        if case .failed = job.state { return true }
        return false
    }
}

struct StatusIcon: View {
    let state: Job.State

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundColor(.secondary)
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .nothing:
            Image(systemName: "equal.circle").foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.watchFolder == nil ? "folder" : "folder.fill")
                    .font(.system(size: 16))
                    .foregroundColor(model.watchFolder == nil ? .secondary : .accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fix automatically")
                        .font(.system(size: 13, weight: .medium))
                    Text(folderText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if model.watchFolder == nil {
                    Button("Choose Folder…") { model.onChooseFolder() }
                } else {
                    Button("Change…") { model.onChooseFolder() }
                    Button {
                        model.onStopWatching()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop watching this folder")
                }
            }
            HStack {
                Toggle("Open at login", isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.onSetOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Text("Closing the window keeps the app in the menu bar")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                Text("Version \(model.version)")
                Spacer()
                Link(destination: supportURL) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var folderText: String {
        guard let f = model.watchFolder else {
            return "Off. Presentations saved in a chosen folder are fixed within seconds."
        }
        return (f.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Update banner

struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
            Text("Version \(model.update?.version ?? "") is available")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button("What's New") { model.onShowUpdate() }
                .buttonStyle(.link)
            Button("Download") { model.onDownloadUpdate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)   // below the window buttons
        .padding(.bottom, 10)
        .background(Color.accentColor.opacity(0.1))
    }
}

// MARK: - Welcome screen

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, 10)
            Text("Welcome to \(appName)")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Images you paste from a PDF into PowerPoint for Mac look pixelated on Windows. This app makes a copy of your presentation that is sharp on both.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "arrow.down.doc",
                        title: "Drop presentations in the window",
                        text: "A sharp copy named “name_windows.pptx” appears next to each one. Your original is never changed.")
                Feature(symbol: "folder.badge.gearshape",
                        title: "Or let it work automatically",
                        text: "Choose a folder, and every presentation saved there is fixed within seconds.")
                Feature(symbol: "menubar.arrow.up.rectangle",
                        title: "Always within reach",
                        text: "When you close the window, the app stays in the menu bar at the top right of your screen. Click this icon to open it again:")
            }
            .padding(.top, 22)

            MenuBarIllustration()
                .padding(.top, 10)
                .padding(.leading, 44)

            Divider().padding(.top, 22)

            HStack {
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Get Started") { model.onFinishOnboarding(openAtLogin) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(width: 460)
    }
}

struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small drawing of the right side of the menu bar, with the app's icon highlighted.
struct MenuBarIllustration: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 26, height: 26)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text("9:41").font(.system(size: 12, weight: .medium))
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
