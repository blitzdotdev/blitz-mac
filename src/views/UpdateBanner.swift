import SwiftUI

// MARK: - Full-screen overlay

/// Full-screen update card that blocks the main window UI when an update is in progress.
struct UpdateOverlay: View {
    @Bindable var autoUpdate: AutoUpdateManager

    var body: some View {
        ZStack {
            // Dim background — blocks interaction with content beneath
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            UpdateCardContent(autoUpdate: autoUpdate)
                .frame(width: 420)
                .padding(32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
    }
}

/// Reusable update card content used by both UpdateOverlay and UpdateSettingsRow sheet.
struct UpdateCardContent: View {
    @Bindable var autoUpdate: AutoUpdateManager

    @ViewBuilder
    var body: some View {
        switch autoUpdate.state {
        case .available(let version, let notes):
            VStack(spacing: 16) {
                HStack {
                    Text("Update Available")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("v\(version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }

                VStack(spacing: 8) {
                    Button("Update Now") {
                        Task { await autoUpdate.performUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Later") {
                        autoUpdate.dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

        case .downloading(let percent):
            VStack(spacing: 20) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                VStack(spacing: 6) {
                    Text("Downloading Update")
                        .font(.title2.weight(.semibold))
                    if percent >= 0 {
                        Text("\(percent)%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if percent >= 0 {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }

                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .installing:
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 6) {
                    Text("Installing Update")
                        .font(.title2.weight(.semibold))
                    Text("Blitz will restart automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Please wait...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .failed(let message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                VStack(spacing: 6) {
                    Text("Update Failed")
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }

                HStack(spacing: 12) {
                    Button("Retry") {
                        Task { await autoUpdate.performUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Dismiss") {
                        autoUpdate.dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Settings row with sheet

/// Inline row for the Settings "Updates" section.
/// Shows status + "Check for Updates" or "View Update" button.
/// Active update/download/install states are shown in a closable sheet reusing UpdateOverlay.
struct UpdateSettingsRow: View {
    @Bindable var autoUpdate: AutoUpdateManager
    @State private var showUpdateSheet = false

    var body: some View {
        switch autoUpdate.state {
        case .idle:
            Button("Check for Updates") {
                Task { await autoUpdate.checkForUpdate() }
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You're up to date")
                    .font(.callout)
                Spacer()
                Button("Check Again") {
                    Task { await autoUpdate.checkForUpdate() }
                }
                .controlSize(.small)
            }

        case .available(let version, _):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Update available")
                    .font(.callout)
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View Update") {
                    showUpdateSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .sheet(isPresented: $showUpdateSheet) {
                updateSheet
            }

        case .downloading, .installing, .failed:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View") {
                    showUpdateSheet = true
                }
                .controlSize(.small)
            }
            .sheet(isPresented: $showUpdateSheet) {
                updateSheet
            }
            .onAppear { showUpdateSheet = true }
        }
    }

    private var statusLabel: String {
        switch autoUpdate.state {
        case .downloading: return "Downloading..."
        case .installing: return "Installing..."
        case .failed: return "Update failed"
        default: return ""
        }
    }

    private var updateSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showUpdateSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding([.top, .trailing], 12)

            UpdateCardContent(autoUpdate: autoUpdate)
                .padding(24)
        }
        .frame(width: 480, height: 380)
    }
}
