import AppKit
import SwiftUI

/// First-run guide: what is ready, what to install, and a one-click first fold.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var commandLineTools: Bool?

    private var rhofold: CatalogEntry? { app.entry(for: "rhofold") }
    private var alphafold: CatalogEntry? { app.entry(for: "alphafold3-mac") }
    private var rhofoldInstalling: Bool {
        app.installJobs.contains { $0.modelId == "rhofold" && $0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 12) {
                step(0, done: app.connected, title: "Local backend", detail: app.connected ? "Running on this Mac. It starts and stops with the app." : "Starting…") {
                    EmptyView()
                }
                step(1, done: commandLineTools == true, title: "Apple's Command Line Tools", detail: commandLineTools == false ? "Needed once to install models (git and a compiler)." : "Installed.") {
                    if commandLineTools == false {
                        Button("Install…") { installTools() }
                            .buttonStyle(SubtleButtonStyle(prominent: true))
                    }
                }
                step(2, done: rhofold?.ready == true, title: "RhoFold+ for RNA", detail: rhofoldDetail) {
                    if rhofold?.ready != true {
                        Button(rhofoldInstalling ? "Installing…" : "Install (0.5 GB)") {
                            if let rhofold { Task { await app.install(rhofold) } }
                        }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                        .disabled(rhofoldInstalling || commandLineTools == false)
                    }
                }
                step(3, done: alphafold?.ready == true, title: "AlphaFold 3 (optional)", detail: alphafold?.ready == true ? "Ready through mac-af3." : "Install from the Library. It needs your own copy of the official weights, which Dimitri cannot download.") {
                    EmptyView()
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 22)

            Divider()

            HStack {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    foldSample()
                } label: {
                    Label("Fold the sample RNA", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(rhofold?.ready != true)
                .help(rhofold?.ready == true ? "Runs the 52-nt RNA (PDB 6TB7) with RhoFold+; takes seconds." : "Install RhoFold+ first")
            }
            .padding(18)
        }
        .frame(width: 600)
        .task {
            commandLineTools = await Self.hasCommandLineTools()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { appeared = true }
        }
    }

    private var hero: some View {
        ZStack {
            Theme.brand.opacity(0.14)
            VStack(spacing: 12) {
                LogoMark(size: 74)
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)
                Text("Welcome to Dimitri Studio")
                    .font(.system(size: 24, weight: .bold))
                Text("Predict protein and RNA structures on this Mac. Your sequences and results never leave it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var rhofoldDetail: String {
        if rhofold?.ready == true { return "Ready. Folds a 52-nt RNA in a few seconds on the GPU." }
        if let job = app.installJobs.first(where: { $0.modelId == "rhofold" && $0.isActive }) {
            return "\(job.stageMessage ?? "Installing") · \(Int(job.progress))%"
        }
        return "Installs rhofold-mac: PyTorch for the Apple GPU and the public weights."
    }

    private func step<Accessory: View>(
        _ index: Int, done: Bool, title: String, detail: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(done ? Theme.success : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer()
            accessory()
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.5).delay(0.08 * Double(index)), value: appeared)
        .animation(Motion.spring, value: done)
    }

    private func foldSample() {
        guard let sample = SequenceExample.all.first(where: { $0.entity == .rna }) else { return }
        app.draft = PredictionDraft(
            name: "Sample RNA (6TB7)", sequence: sample.sequence, entity: .rna,
            entityPinned: true, modelIDs: ["rhofold"], modelsPinned: true
        )
        finish()
        Task { await app.submit() }
    }

    private func finish() {
        app.finishOnboarding()
        dismiss()
    }

    private func installTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()
        app.present(.info, "Follow Apple's installer", "When it finishes, come back here; Dimitri checks again automatically.")
        Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                if await Self.hasCommandLineTools() {
                    commandLineTools = true
                    return
                }
            }
        }
    }

    static func hasCommandLineTools() async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["-p"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
