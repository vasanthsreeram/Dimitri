import SwiftUI

struct PredictView: View {
    @EnvironmentObject private var app: AppModel
    let onRun: () -> Void
    let onNeedSetup: () -> Void

    @State private var entity: EntityKind = .protein
    @State private var selectedModelID: String = "alphafold3-mac"
    @State private var sequence: String = ""
    @State private var seed: Int = 42
    @State private var samples: Int = 5
    @State private var isSubmitting = false

    private var allModels: [CatalogEntry] {
        app.catalog
            .filter { $0.installable }
            .sorted { lhs, rhs in
                let order = ["alphafold3-mac", "openfold3", "rhofold"]
                let l = order.firstIndex(of: lhs.id) ?? 99
                let r = order.firstIndex(of: rhs.id) ?? 99
                return l < r
            }
    }

    private var compatibleModels: [CatalogEntry] {
        allModels.filter { $0.entityTypes.contains(entity.rawValue) }
    }

    private var selectedEntry: CatalogEntry? {
        if let selected = compatibleModels.first(where: { $0.id == selectedModelID }) {
            return selected
        }
        return compatibleModels.first(where: { $0.ready }) ?? compatibleModels.first
    }

    private var cleanedSequence: String {
        let stripped = sequence.filter { !$0.isWhitespace }
        return entity == .ligand ? stripped : stripped.uppercased()
    }

    private var validation: String? {
        if cleanedSequence.isEmpty { return nil }
        if cleanedSequence.count > 8_000 { return "Sequences are limited to 8,000 tokens." }
        if let alphabet = entity.alphabet {
            let bad = Set(cleanedSequence).subtracting(alphabet)
            if !bad.isEmpty {
                return "Unsupported \(entity.label) character(s): \(String(bad.sorted()))"
            }
        }
        return nil
    }

    private var canRun: Bool {
        selectedEntry?.ready == true
            && !cleanedSequence.isEmpty
            && validation == nil
            && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        modelPicker
                        inputCard
                    }
                    sidePanel
                        .frame(width: 330)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1240, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reconcileModel)
        .onChange(of: entity) { _, _ in reconcileModel() }
        .onChange(of: app.catalog.count) { _, _ in reconcileModel() }
        .onChange(of: readinessSignature) { _, _ in reconcileModel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Predict a structure")
                .font(.system(size: 26, weight: .bold))
            Text("Paste a sequence, pick a model, and run it on Apple Silicon.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private var modelPicker: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(
                    title: "Model",
                    subtitle: "The same input can be folded by any installed model.",
                    icon: "square.stack.3d.up"
                )

                if compatibleModels.isEmpty {
                    Text("No model accepts \(entity.label) input yet. Open the Library to install one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(allModels) { entry in
                            ModelOptionCard(
                                entry: entry,
                                selected: entry.id == selectedEntry?.id,
                                compatible: entry.entityTypes.contains(entity.rawValue),
                                status: app.statusEntry(for: entry),
                                action: {
                                    if entry.entityTypes.contains(entity.rawValue) {
                                        selectedModelID = entry.id
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(
                    title: "Input",
                    subtitle: "One entity per run. Complexes are on the roadmap.",
                    icon: "text.cursor"
                )

                entityPicker

                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if sequence.isEmpty {
                            Text(entity.placeholder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $sequence)
                            .font(.system(size: 12.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(minHeight: 132)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                validation == nil
                                    ? Color.primary.opacity(0.08)
                                    : Theme.danger.opacity(0.5),
                                lineWidth: 1
                            )
                    )

                    HStack {
                        Text("\(cleanedSequence.count) \(entity == .ligand ? "character" : "residue")\(cleanedSequence.count == 1 ? "" : "s")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if entity != .ligand {
                            Text("· \(entity.alphabet.map { String($0.sorted()) } ?? "")")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Use example") {
                            sequence = entity.placeholder
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }

                    if let validation {
                        Label(validation, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                    }
                }

                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Seed")
                            .font(.system(size: 10.5, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("42", value: $seed, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                            Stepper("", value: $seed, in: 0...999_999)
                                .labelsHidden()
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Samples")
                            .font(.system(size: 10.5, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("\(samples)")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 22)
                            Stepper("", value: $samples, in: 1...20)
                                .labelsHidden()
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var entityPicker: some View {
        HStack(spacing: 6) {
            ForEach(EntityKind.allCases) { kind in
                Button {
                    entity = kind
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11, weight: .medium))
                        Text(kind.label)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(entity == kind ? Theme.accent.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                entity == kind ? Theme.accent.opacity(0.45) : Color.primary.opacity(0.07),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(entity == kind ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sidePanel: some View {
        VStack(spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(title: "Run", icon: "play.circle")

                    VStack(alignment: .leading, spacing: 7) {
                        KeyValueRow(
                            label: "Model",
                            value: selectedEntry?.name ?? "None available"
                        )
                        KeyValueRow(label: "Input", value: entity.label)
                        KeyValueRow(
                            label: "Sequence",
                            value: "\(cleanedSequence.count)\(entity == .ligand ? "" : " aa")"
                        )
                        KeyValueRow(label: "Samples", value: "\(samples)")
                    }

                    if let entry = selectedEntry {
                        if entry.ready {
                            Label("Installed and ready", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        } else {
                            Label("Setup required", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.amber)
                        }
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                            }
                            Text(isSubmitting ? "Starting…" : "Run prediction")
                            Spacer()
                            Text("⌘↩")
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.55)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canRun)
                    .opacity(canRun ? 1 : 0.45)
                    .keyboardShortcut(.return, modifiers: [.command])

                    if selectedEntry?.ready != true, selectedEntry != nil {
                        Button("Set up in Library") {
                            onNeedSetup()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let entry = selectedEntry {
                Card {
                    VStack(alignment: .leading, spacing: 11) {
                        CardTitle(title: "About \(entry.name)", icon: "info.circle")
                        Text(entry.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let provider = entry.provider {
                            KeyValueRow(label: "Provider", value: provider)
                        }
                        if let runtime = entry.runtime {
                            KeyValueRow(label: "Runtime", value: runtime)
                        }
                        if let fallback = entry.fallback {
                            KeyValueRow(label: "Fallback", value: fallback)
                        }
                        if let license = entry.license {
                            KeyValueRow(label: "License", value: license)
                        }
                        if let openness = entry.openness {
                            KeyValueRow(label: "Openness", value: "\(openness) / 100")
                        }

                        if entry.ready != true, let note = entry.weightNote {
                            Divider().opacity(0.5)
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                            if let requestURL = entry.weightRequestUrl,
                               let url = URL(string: requestURL) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Get weights", systemImage: "arrow.up.right.square")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                            }
                            if let directory = entry.weightDir {
                                Text(directory)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        if let sourceURL = entry.sourceUrl, let url = URL(string: sourceURL) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("View on bio.rodeo", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var readinessSignature: String {
        app.catalog.map { "\($0.id):\($0.ready)" }.joined(separator: ",")
    }

    private func reconcileModel() {
        if let current = compatibleModels.first(where: { $0.id == selectedModelID }) {
            if current.ready { return }
            if let ready = compatibleModels.first(where: { $0.ready }) {
                selectedModelID = ready.id
            }
            return
        }
        selectedModelID = compatibleModels.first(where: { $0.ready })?.id
            ?? compatibleModels.first?.id
            ?? selectedModelID
    }

    private func submit() {
        guard let entry = selectedEntry, entry.ready, canRun else { return }
        isSubmitting = true
        Task {
            let job = await app.submitPrediction(
                modelID: entry.runnerId ?? entry.id,
                entity: entity,
                sequence: cleanedSequence,
                seed: seed,
                samples: samples
            )
            isSubmitting = false
            if job != nil {
                sequence = ""
                onRun()
            }
        }
    }
}

struct ModelOptionCard: View {
    let entry: CatalogEntry
    let selected: Bool
    let compatible: Bool
    let status: RunnerStatus?
    let action: () -> Void

    private var statusText: String {
        if !compatible { return "Unsupported input" }
        if entry.ready { return "Ready" }
        if entry.installed { return "Weights needed" }
        return "Not installed"
    }

    private var statusColor: Color {
        if !compatible { return .secondary }
        if entry.ready { return Theme.accent }
        if entry.installed { return Theme.amber }
        return .secondary
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
                }
                Text(entry.provider ?? "Local model")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    StatusPill(text: statusText, color: statusColor, filled: true)
                    Spacer()
                    if entry.sizeBytes > 0 {
                        Text(formatBytes(entry.sizeBytes))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.accent.opacity(0.45) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )
            .opacity(compatible ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!compatible)
        .help(status?.detail ?? entry.description)
    }
}
