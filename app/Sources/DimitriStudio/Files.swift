import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// FASTA reading: the first record is what Predict runs.
enum FASTA {
    struct Record: Equatable {
        let name: String
        let sequence: String
    }

    static func parse(_ text: String) -> [Record] {
        var records: [Record] = []
        var name: String?
        var sequence = ""
        func flush() {
            if let name, !sequence.isEmpty {
                records.append(Record(name: name, sequence: sequence))
            }
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix(">") {
                flush()
                // First word of the header, e.g. ">6tb7A RNA chain A …" → "6tb7A".
                let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
                name = header.split(separator: " ").first.map(String.init) ?? ""
                sequence = ""
            } else {
                if name == nil { name = "" }
                sequence += line.filter { !$0.isWhitespace && $0 != "*" }
            }
        }
        flush()
        return records
    }
}

enum FileKind {
    case fasta, structure, unknown

    static func detect(url: URL?, text: String) -> FileKind {
        let ext = url?.pathExtension.lowercased() ?? ""
        if ["fasta", "fa", "fna", "faa", "fas", "seq"].contains(ext) { return .fasta }
        if ["pdb", "ent", "cif", "mmcif"].contains(ext) { return .structure }
        let head = text.prefix(4000)
        if head.hasPrefix(">") { return .fasta }
        if head.contains("_atom_site.") || head.hasPrefix("data_") { return .structure }
        if head.split(whereSeparator: \.isNewline).contains(where: {
            $0.hasPrefix("ATOM  ") || $0.hasPrefix("HETATM") || $0.hasPrefix("HEADER")
        }) {
            return .structure
        }
        // Bare letters: treat as a sequence.
        let letters = head.filter { !$0.isWhitespace }
        if !letters.isEmpty, letters.allSatisfy({ $0.isLetter }) { return .fasta }
        return .unknown
    }
}

/// Accepts dropped files anywhere it is attached and hands them to the model.
struct FileDropModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    DropHighlight()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                load(providers)
                return true
            }
    }

    private func load(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.fileURL() { urls.append(url) }
            }
            if !urls.isEmpty { app.open(urls) }
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .light))
                    .symbolEffect(.pulse)
                Text("Drop to open")
                    .font(.title3.weight(.semibold))
                Text("FASTA goes to Predict · PDB and mmCIF open as results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(10)
    }
}

extension View {
    func acceptsStructureFiles() -> some View {
        modifier(FileDropModifier())
    }
}

extension NSItemProvider {
    func fileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }
}
