import SwiftUI

enum SidebarItem: Hashable {
    case screen(Screen)
    case job(String)
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            ZStack(alignment: .top) {
                Theme.canvas.ignoresSafeArea()
                if app.backend.isReady {
                    screen
                        .transition(.opacity)
                } else {
                    BackendStatusView()
                        .transition(.opacity)
                }
                if let toast = app.toast {
                    ToastView(toast: toast) { app.dismissToast() }
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(reduceMotion ? nil : Motion.gentle, value: app.backend.isReady)
        }
        .acceptsStructureFiles()
        .sheet(isPresented: Binding(
            get: { app.showOnboarding && app.backend.isReady && app.connected },
            set: { if !$0 { app.finishOnboarding() } }
        )) {
            OnboardingView()
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch app.screen {
        case .predict:
            PredictView()
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        case .results:
            ResultsView()
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        case .library:
            LibraryView()
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if app.screen == .results, let id = app.selectedJobID,
                   recent.contains(where: { $0.id == id }) {
                    return .job(id)
                }
                return .screen(app.screen)
            },
            set: { item in
                withAnimation(Motion.snappy) {
                    switch item {
                    case .screen(let screen):
                        app.screen = screen
                    case .job(let id):
                        app.select(id)
                    case nil:
                        break
                    }
                }
            }
        )
    }

    private var recent: [JobSummary] { Array(app.predictions.prefix(8)) }
    private var running: Int { app.predictions.filter(\.isActive).count }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(Screen.allCases) { screen in
                    Label {
                        HStack {
                            Text(screen.title)
                            Spacer()
                            if screen == .results, running > 0 {
                                Text("\(running)")
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                                    .foregroundStyle(.white)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            if screen == .library, app.installJobs.contains(where: \.isActive) {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    } icon: {
                        Image(systemName: screen.icon)
                    }
                    .tag(SidebarItem.screen(screen))
                    .accessibilityHint("Keyboard shortcut Command \(String(screen.shortcut.character))")
                }
            }

            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { job in
                        RecentJobRow(job: job)
                            .tag(SidebarItem.job(job.id))
                            .contextMenu { JobContextMenu(job: job) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeader()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .animation(Motion.snappy, value: running)
    }
}

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dimitri Studio")
                    .font(.system(size: 14, weight: .semibold))
                Text("Local structure prediction")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RecentJobRow: View {
    @Environment(AppModel.self) private var app
    let job: JobSummary

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if job.isActive {
                    ProgressRing(progress: job.progress / 100, size: 14, lineWidth: 2.2)
                } else if job.isCompleted, let plddt = job.plddt {
                    Circle()
                        .fill(Theme.plddtColor(plddt))
                        .frame(width: 8, height: 8)
                        .frame(width: 14)
                } else {
                    Image(systemName: job.status == "failed" ? "exclamationmark.circle.fill" : (job.isImport ? "doc" : "circle.dashed"))
                        .font(.system(size: 11))
                        .foregroundStyle(job.status == "failed" ? Theme.failure : Color.secondary)
                        .frame(width: 14)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.name), \(app.shortName(for: job.modelId)), \(Theme.statusLabel(job.status))")
    }

    private var subtitle: String {
        let model = app.shortName(for: job.modelId)
        if job.isActive {
            return "\(model) · \(job.stageName ?? Theme.statusLabel(job.status)) · \(Int(job.progress))%"
        }
        if let plddt = job.plddt {
            return "\(model) · pLDDT \(Format.score(plddt))"
        }
        return "\(model) · \(Theme.statusLabel(job.status))"
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                    if let device = app.status?.device {
                        Text("\(device.chip) · \(Int(device.memoryGb)) GB\(app.workers.isEmpty ? "" : " · \(app.workers.count) loaded")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help("Settings and backend status")
    }

    private var title: String {
        switch app.backend.phase {
        case .ready: return app.connected ? "Backend ready" : "Reconnecting…"
        case .preparing: return "Setting up…"
        case .failed: return "Backend stopped"
        default: return "Starting backend…"
        }
    }

    private var color: Color {
        switch app.backend.phase {
        case .ready: return app.connected ? Theme.success : Theme.warning
        case .failed: return Theme.failure
        default: return Theme.warning
        }
    }
}

struct JobContextMenu: View {
    @Environment(AppModel.self) private var app
    let job: JobSummary

    var body: some View {
        if job.isActive {
            Button("Cancel") { Task { await app.cancel(job.id) } }
        } else {
            if job.kind == "predict" {
                Button("Run Again") { Task { await app.rerun(job.id) } }
            }
            if !job.isImport {
                Button("Edit Input in Predict") { Task { await app.reuseInput(job.id) } }
            }
            if job.isCompleted {
                Menu("Export") {
                    Button("mmCIF…") { app.export(job.id, format: "cif") }
                    Button("PDB…") { app.export(job.id, format: "pdb") }
                    Button("Confidence JSON…") { app.export(job.id, format: "json") }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await app.delete(job.id) } }
        }
    }
}

// MARK: - Backend start-up states

struct BackendStatusView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 72)
                .modifier(Breathing())
            switch app.backend.phase {
            case .failed(let problem):
                failure(problem)
            case .preparing(let message):
                progress(
                    title: app.backend.firstLaunch ? "Setting up Dimitri Studio" : "Preparing",
                    message: message,
                    detail: "This happens once and takes a minute or two. Nothing needs a terminal."
                )
            case .starting:
                progress(title: "Starting the local backend", message: "Loading the job queue and model runners…", detail: nil)
            default:
                progress(title: "Connecting", message: "Looking for the local backend…", detail: nil)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(title: String, message: String, detail: String?) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            .animation(Motion.gentle, value: message)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !app.backend.setupLines.isEmpty {
                ScrollView {
                    Text(app.backend.setupLines.suffix(8).joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 520, maxHeight: 110)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func failure(_ problem: BackendController.Problem) -> some View {
        VStack(spacing: 12) {
            Text(problem.title)
                .font(.title2.weight(.semibold))
            Text(problem.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let command = problem.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        app.present(.success, "Copied to the clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack(spacing: 10) {
                Button("Try Again") { app.backend.restart() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Show Log") { NSWorkspace.shared.open(app.backend.logURL) }
                    .buttonStyle(SubtleButtonStyle())
            }
            .padding(.top, 4)
        }
    }
}

/// A slow scale "breath" for the logo while the app is busy.
struct Breathing: ViewModifier {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.04 : 0.98)
            .opacity(on ? 1 : 0.85)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
