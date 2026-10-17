import AppKit
import SwiftUI

struct PredictView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        SequenceCard(editorFocused: $editorFocused)
                        ModelPicker()
                    }
                    .frame(maxWidth: .infinity)
                    RunPanel()
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1260)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Predict")
        .navigationSubtitle(app.draft.cleanedSequence.isEmpty ? "New prediction" : "\(app.draft.cleanedSequence.count) \(app.draft.entity.unit) \(app.draft.entity.label)")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(SequenceExample.all) { example in
                        Button(example.title) { load(example) }
                    }
                } label: {
                    Label("Examples", systemImage: "text.badge.star")
                }
                .help("Load a small example input")
                Button {
                    app.openPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a FASTA, PDB or mmCIF file (⌘O)")
            }
        }
        .onAppear {
            app.reconcileDraftModels()
            if app.draft.sequence.isEmpty { editorFocused = true }
        }
        .onChange(of: app.draft.entity) { app.reconcileDraftModels() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New prediction")
                .font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let chip = app.status?.device?.chip ?? "Apple Silicon"
        return "Paste a sequence or drop a FASTA file, choose one or more models, and run it on the \(chip) GPU. Nothing leaves this Mac."
    }

    private func load(_ example: SequenceExample) {
        withAnimation(Motion.spring) {
            app.draft.sequence = example.sequence
            app.draft.entity = example.entity
            app.draft.entityPinned = false
            app.draft.modelsPinned = false
            app.draft.name = example.title.components(separatedBy: " (").first ?? example.title
        }
        app.reconcileDraftModels()
    }
}

// MARK: - Sequence

private struct SequenceCard: View {
    @Environment(AppModel.self) private var app
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var app = app
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: "Input", subtitle: "One chain per run. Drop a .fasta file anywhere in the window.", icon: "text.cursor")
                    Spacer()
                    if !app.draft.sequence.isEmpty {
                        Button("Clear") {
                            withAnimation(Motion.snappy) {
                                app.draft.sequence = ""
                                app.draft.name = ""
                                app.draft.entityPinned = false
                            }
                        }
                        .buttonStyle(.borderless)
                        .transition(.opacity)
                    }
                }

                HStack(spacing: 12) {
                    TextField("Name (optional)", text: $app.draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer()
                    EntityPicker()
                }

                editor

                footer

                if let problem = app.draftProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.failure)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .motion(Motion.snappy, value: app.draftProblem)
    }

    private var editor: some View {
        @Bindable var app = app
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $app.draft.sequence)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused(editorFocused)
                .onChange(of: app.draft.sequence) { _, newValue in
                    // Pasted FASTA: keep the name, drop the header line.
                    if newValue.hasPrefix(">"), let record = FASTA.parse(newValue).first {
                        app.draft.sequence = record.sequence
                        if app.draft.name.isEmpty { app.draft.name = record.name }
                    }
                    if !app.draft.entityPinned, !newValue.isEmpty {
                        let guess = EntityKind.guess(for: newValue)
                        if guess != app.draft.entity {
                            withAnimation(Motion.snappy) { app.draft.entity = guess }
                        }
                    }
                }
                .accessibilityLabel("Sequence")
            if app.draft.sequence.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste a protein, RNA or DNA sequence, a SMILES string or a CCD code…")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        ForEach(SequenceExample.all) { example in
                            Button {
                                withAnimation(Motion.spring) {
                                    app.draft.sequence = example.sequence
                                    app.draft.entity = example.entity
                                    app.draft.modelsPinned = false
                                    app.draft.name = example.title.components(separatedBy: " (").first ?? example.title
                                }
                                app.reconcileDraftModels()
                            } label: {
                                Label(example.entity == .rna ? "Try the 52-nt RNA sample" : "Try Trp-cage (1L2Y)", systemImage: example.entity == .rna ? "waveform.path" : "circle.hexagongrid")
                            }
                            .buttonStyle(SubtleButtonStyle(prominent: true))
                            .help(example.detail)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 16)
            }
        }
        .frame(minHeight: 150, maxHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(app.draftProblem == nil ? (editorFocused.wrappedValue ? Color.accentColor.opacity(0.6) : Theme.hairline) : Theme.failure.opacity(0.6), lineWidth: editorFocused.wrappedValue ? 1.5 : 1)
        )
        .motion(Motion.snappy, value: editorFocused.wrappedValue)
    }

    private var footer: some View {
        let sequence = app.draft.cleanedSequence
        return VStack(alignment: .leading, spacing: 8) {
            if !sequence.isEmpty, app.draft.entity != .ligand {
                CompositionStrip(sequence: sequence, entity: app.draft.entity)
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Text("\(sequence.count) \(app.draft.entity.unit)")
                    .font(.callout.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                if !app.draft.entityPinned, !sequence.isEmpty {
                    Chip(text: "Detected \(app.draft.entity.label)", icon: "sparkles", tint: .accentColor)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                Spacer()
                if let alphabet = app.draft.entity.alphabet {
                    Text(String(alphabet.sorted()))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .help("Accepted letters")
                }
            }
        }
        .motion(Motion.snappy, value: sequence.isEmpty)
    }
}

private struct EntityPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let binding = Binding<EntityKind>(
            get: { app.draft.entity },
            set: { value in
                withAnimation(Motion.snappy) {
                    app.draft.entity = value
                    app.draft.entityPinned = true
                }
            }
        )
        Picker("Entity", selection: binding) {
            ForEach(EntityKind.allCases) { kind in
                Label(kind.label, systemImage: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 330)
        .help("What the sequence is. Detected automatically until you choose.")
    }
}

/// A one-line portrait of the sequence: base identity for nucleic acids,
/// residue class for proteins.
private struct CompositionStrip: View {
    let sequence: String
    let entity: EntityKind

    var body: some View {
        Canvas { context, size in
            let letters = Array(sequence.prefix(4000))
            guard !letters.isEmpty else { return }
            let width = size.width / CGFloat(letters.count)
            for (index, letter) in letters.enumerated() {
                let rect = CGRect(x: CGFloat(index) * width, y: 0, width: width + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(color(letter)))
            }
        }
        .accessibilityLabel("Sequence composition")
    }

    private func color(_ letter: Character) -> Color {
        if entity == .rna || entity == .dna {
            switch letter {
            case "A": return Color(red: 0.30, green: 0.69, blue: 0.47)
            case "U", "T": return Color(red: 0.93, green: 0.43, blue: 0.37)
            case "G": return Color(red: 0.98, green: 0.74, blue: 0.29)
            case "C": return Color(red: 0.31, green: 0.55, blue: 0.93)
            default: return .gray
            }
        }
        switch letter {
        case "A", "V", "L", "I", "M", "F", "W", "P", "G": return Color(red: 0.98, green: 0.74, blue: 0.29)  // hydrophobic
        case "D", "E": return Color(red: 0.93, green: 0.43, blue: 0.37)  // acidic
        case "K", "R", "H": return Color(red: 0.31, green: 0.55, blue: 0.93)  // basic
        case "S", "T", "N", "Q", "C", "Y": return Color(red: 0.30, green: 0.69, blue: 0.47)  // polar
        default: return .gray
        }
    }
}

// MARK: - Models

private struct ModelPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(
                    title: "Models",
                    subtitle: "Pick one, or several to compare them on the same input.",
                    icon: "square.stack.3d.up"
                )
                if app.predictableModels.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the model library…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(app.predictableModels) { entry in
                            ModelCard(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

private struct ModelCard: View {
    @Environment(AppModel.self) private var app
    let entry: CatalogEntry
    @State private var hovering = false

    private var compatible: Bool { entry.entityTypes.contains(app.draft.entity.rawValue) }
    private var selected: Bool { app.draft.modelIDs.contains(entry.modelID) }
    private var warm: Bool { app.isWarm(entry.modelID) }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.callout.weight(.semibold))
                        Text(entry.provider ?? "Independent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .contentTransition(.symbolEffect(.replace))
                }
                HStack(spacing: 6) {
                    if let device = entry.device {
                        Chip(text: device.uppercased(), icon: "cpu")
                    }
                    status
                }
                Text(inputs)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(hovering ? 0.05 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Theme.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .scaleEffect(hovering && compatible ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!compatible)
        .opacity(compatible ? 1 : 0.45)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: selected)
        .motion(Motion.snappy, value: hovering)
        .help(compatible ? (entry.statusDetail ?? entry.description) : "\(entry.name) does not accept \(app.draft.entity.label) input")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(compatible ? "Toggles this model" : "Not available for this input")
    }

    @ViewBuilder
    private var status: some View {
        if !compatible {
            Chip(text: "No \(app.draft.entity.label)", tint: .secondary)
        } else if warm {
            Chip(text: "Loaded", icon: "bolt.fill", tint: Theme.success)
                .transition(.scale.combined(with: .opacity))
        } else if entry.ready {
            Chip(text: "Ready", icon: "checkmark", tint: Theme.success)
        } else if entry.installed {
            Chip(text: "Needs weights", icon: "key", tint: Theme.warning)
        } else {
            Chip(text: "Not installed", icon: "arrow.down.circle", tint: .secondary)
        }
    }

    private var inputs: String {
        entry.entityTypes.compactMap { EntityKind(rawValue: $0)?.label }.joined(separator: " · ")
    }

    private func toggle() {
        withAnimation(Motion.snappy) {
            app.draft.modelsPinned = true
            if selected {
                app.draft.modelIDs.removeAll { $0 == entry.modelID }
            } else {
                app.draft.modelIDs.append(entry.modelID)
                app.prewarm(entry.modelID)
            }
        }
    }
}

// MARK: - Run

private struct RunPanel: View {
    @Environment(AppModel.self) private var app
    @State private var showOptions = false

    private var selectedEntries: [CatalogEntry] {
        app.draft.modelIDs.compactMap { app.entry(for: $0) }
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "Run", icon: "play.circle")
                    VStack(spacing: 8) {
                        KeyValueRow(label: "Input", value: app.draft.cleanedSequence.isEmpty ? "—" : "\(app.draft.entity.label) · \(app.draft.cleanedSequence.count) \(app.draft.entity.unit)")
                        KeyValueRow(label: selectedEntries.count > 1 ? "Models" : "Model", value: selectedEntries.isEmpty ? "None selected" : selectedEntries.map(\.name).joined(separator: ", "))
                        if let device = app.status?.device {
                            KeyValueRow(label: "Runs on", value: "\(device.chip) GPU")
                        }
                    }

                    DisclosureGroup(isExpanded: $showOptions) {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Seed").foregroundStyle(.secondary)
                                Spacer()
                                TextField("Seed", value: $app.draft.seed, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                                    .multilineTextAlignment(.trailing)
                            }
                            HStack {
                                Text("Samples").foregroundStyle(.secondary)
                                Spacer()
                                Stepper(value: $app.draft.samples, in: 1...10) {
                                    Text("\(app.draft.samples)")
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                }
                            }
                            Text("Samples apply to AlphaFold 3 and OpenFold3 (diffusion models). RhoFold+ makes one structure.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Options").font(.callout.weight(.medium))
                    }

                    Button {
                        Task { await app.submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if app.submitting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(app.submitting ? "Starting…" : (selectedEntries.count > 1 ? "Run on \(selectedEntries.count) models" : "Run prediction"))
                            Spacer()
                            Text("⌘↩").opacity(0.7).font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!app.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)

                    readiness
                }
            }
            if let entry = selectedEntries.first {
                AboutModelCard(entry: entry)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .id(entry.id)
            }
        }
        .motion(Motion.spring, value: selectedEntries.map(\.id))
    }

    @ViewBuilder
    private var readiness: some View {
        let notReady = selectedEntries.filter { !$0.ready }
        if !notReady.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notReady) { entry in
                    Label(entry.installed ? "\(entry.name) needs its weights" : "\(entry.name) is not installed yet", systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                }
                Button("Set up in Library") {
                    withAnimation(Motion.snappy) { app.screen = .library }
                }
                .buttonStyle(SubtleButtonStyle(prominent: true))
            }
            .transition(.opacity)
        } else if selectedEntries.contains(where: { app.isWarm($0.modelID) }) {
            Label("Model loaded: starts at once", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(Theme.success)
                .transition(.opacity)
        }
    }
}

private struct AboutModelCard: View {
    let entry: CatalogEntry

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: entry.name, subtitle: entry.provider, icon: "info.circle")
                Text(entry.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let runtime = entry.runtime {
                    KeyValueRow(label: "Runtime", value: runtime)
                }
                if let license = entry.license {
                    KeyValueRow(label: "License", value: license)
                }
                if !entry.ready, let note = entry.weightNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = entry.sourceUrl, let url = URL(string: source) {
                    Link(destination: url) {
                        Label("Model page on bio.rodeo", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }
}
