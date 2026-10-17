import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case predict, results, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .predict: return "Predict"
        case .results: return "Results"
        case .library: return "Library"
        }
    }

    var icon: String {
        switch self {
        case .predict: return "wand.and.stars"
        case .results: return "chart.xyaxis.line"
        case .library: return "books.vertical"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var screen: Screen
    @State private var showSettings = false

    init(initialScreen: Screen = .predict) {
        _screen = State(initialValue: initialScreen)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.5)
                if !app.connected {
                    offlineBanner
                }
                content
            }

            if let banner = app.banner {
                BannerView(text: banner) {
                    app.banner = nil
                }
                .padding(.top, 68)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: app.banner)
        .task {
            await app.refreshAll()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(app)
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: "dna")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dimitri Studio")
                        .font(.system(size: 14, weight: .bold))
                    Text("Local structure prediction")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(Screen.allCases) { item in
                    Button {
                        screen = item
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                            if item == .results, app.totalJobsRunning > 0 {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(screen == item ? Color.primary.opacity(0.09) : .clear)
                        )
                        .foregroundStyle(screen == item ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(app.connected ? Theme.accent : Theme.danger)
                    .frame(width: 6, height: 6)
                Text(app.connected ? "Backend online" : "Backend offline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(app.connectionDetail)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.5))
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(Theme.amber)
            Text(app.connectionDetail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task { await app.refreshAll() }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.amber.opacity(0.08))
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .predict:
            PredictView(
                onRun: { screen = .results },
                onNeedSetup: { screen = .library }
            )
        case .results:
            ResultsView()
        case .library:
            LibraryView()
        }
    }
}

struct BannerView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(3)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
