import SwiftUI
import AppKit

/// 3-column persistent workspace: Captures · Sets · Inspector.
/// Adaptive — light & dark mode via system semantic colors.
struct AppShotsWorkspaceView: View {
    var manager: AppShotsFlowManager
    let bootedUDID: String?
    let projectName: String

    @State private var openSet: GeneratedSet?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if manager.step == .generating { progressStrip }
            HStack(spacing: 0) {
                CapturesPanel(manager: manager, bootedUDID: bootedUDID)
                    .frame(width: 280)
                Divider()
                SetsPanel(manager: manager) { set in openSet = set }
                    .frame(maxWidth: .infinity)
                Divider()
                InspectorPanel(manager: manager, projectName: projectName)
                    .frame(width: 280)
            }
        }
        .sheet(item: $openSet) { set in
            AppShotsSetDetailSheet(set: set) { openSet = nil }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(projectName).font(.callout.weight(.semibold))
                Text("·").foregroundStyle(.tertiary)
                Text("App Shots").font(.callout).foregroundStyle(.secondary)
            }
            statusPill
            Spacer()
            if manager.step == .done {
                Button {
                    revealFolder()
                } label: {
                    Label("Show folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                manager.resetToHero()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppShotsTokens.panelBackground)
        .overlay(Divider(), alignment: .bottom)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch manager.step {
            case .hero, .capture:
                let n = manager.captures.count
                return ("Ready · \(n) capture\(n == 1 ? "" : "s")", .secondary)
            case .generating:
                return ("Generating · \(manager.totalRendersDone) of \(manager.totalRendersExpected)", .accentColor)
            case .done:
                let done = manager.generated.filter { $0.isReady }.count
                return ("\(done) of \(manager.generated.count) sets ready", .green)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.3)))
        .foregroundStyle(color)
    }

    private var progressStrip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                Rectangle()
                    .fill(LinearGradient(colors: [Color.accentColor, Color.purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: progressWidth(in: geo.size.width))
            }
        }
        .frame(height: 2)
    }

    private func progressWidth(in total: CGFloat) -> CGFloat {
        let expected = manager.totalRendersExpected
        guard expected > 0 else { return 0 }
        return total * CGFloat(manager.totalRendersDone) / CGFloat(expected)
    }

    private func revealFolder() {
        let firstPath = manager.generated
            .flatMap { $0.screenshots }
            .compactMap { $0.imagePath }
            .first
        guard let path = firstPath else { return }
        let folder = (path as NSString).deletingLastPathComponent
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
    }
}

// MARK: - Captures panel

private struct CapturesPanel: View {
    var manager: AppShotsFlowManager
    let bootedUDID: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Captures", trailing: headerTrailing)
            actions
            list
        }
        .frame(maxHeight: .infinity)
        .background(AppShotsTokens.panelBackground)
    }

    private var headerTrailing: String {
        let active = manager.includedCaptures.count
        let total = manager.captures.count
        return total == 0 ? "0" : "\(active) of \(total) active"
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                Task { await manager.captureOnce(bootedUDID: bootedUDID) }
            } label: {
                Label(captureLabel, systemImage: "camera")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isCapturing || manager.isRecording || bootedUDID == nil)

            Button {
                manager.toggleRecording(bootedUDID: bootedUDID)
            } label: {
                HStack {
                    Image(systemName: manager.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(manager.isRecording ? .red : .primary)
                    Text(manager.isRecording ? "Stop recording" : "Record flow")
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(bootedUDID == nil)

            Button {
                manager.importFiles()
            } label: {
                Label("Upload PNGs", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)

            footnote
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var captureLabel: String {
        manager.isCapturing && !manager.isRecording ? "Capturing…" : "Capture screen"
    }

    @ViewBuilder
    private var footnote: some View {
        if let error = manager.captureError {
            Text(error).font(.caption).foregroundStyle(.orange)
                .padding(.top, 2)
        } else if manager.isRecording {
            Text("Recording — tap around your sim. A frame every 2s, dups skipped.")
                .font(.caption).foregroundStyle(.orange)
                .padding(.top, 2)
        } else if bootedUDID == nil {
            Text("No booted simulator — boot one in Simulator tab, or upload PNGs.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
        } else {
            Text("Tap Capture while navigating your app. Uncheck any blank/wrong screen to skip it.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if manager.captures.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(manager.captures.enumerated()), id: \.element.id) { index, shot in
                        CaptureRow(
                            index: index + 1,
                            shot: shot,
                            onToggle: { manager.toggleCaptureInclusion(id: shot.id) },
                            onRemove: { manager.removeCapture(id: shot.id) }
                        )
                    }
                    if manager.blankWarningCount > 0 {
                        blankWarnBanner
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No captures yet — start with **Capture screen** above.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(AppShotsTokens.subtleStroke)
        )
    }

    private var blankWarnBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            let n = manager.blankWarningCount
            Text("\(n) capture\(n == 1 ? "" : "s") look blank. Auto-excluded — tick the box to include.")
                .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

private struct CaptureRow: View {
    let index: Int
    let shot: CapturedShot
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(shot.included ? Color.accentColor : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(shot.included ? Color.accentColor : AppShotsTokens.subtleStroke, lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(shot.included ? 1 : 0)
                    )
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(shot.included ? "Include in generation" : "Skip during generation")

            Image(nsImage: shot.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 76)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppShotsTokens.subtleStroke))
                .saturation(shot.included ? 1 : 0.2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Screen \(index)")
                        .font(.caption.weight(.medium))
                    if let warn = shot.warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(warn)
                    }
                }
                Text(byteSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .opacity(shot.included ? 1 : 0.55)

            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppShotsTokens.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppShotsTokens.subtleStroke))
    }

    private var byteSize: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: shot.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Sets panel (center)

private struct SetsPanel: View {
    var manager: AppShotsFlowManager
    var onOpenSet: (GeneratedSet) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Screenshot sets", trailing: trailingText)
            ScrollView {
                Group {
                    if manager.generated.isEmpty {
                        emptyState
                    } else {
                        liveGrid
                    }
                }
                .padding(18)
            }
        }
        .frame(maxHeight: .infinity)
        .background(AppShotsTokens.canvasBackground)
    }

    private var trailingText: String {
        let total = manager.generated.isEmpty ? 8 : manager.generated.count
        let done = manager.generated.filter { $0.isReady }.count
        return "\(done) of \(total) sets"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            // Accent-tinted icon tile
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.14), Color.purple.opacity(0.14)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                )

            Text("Your 8 sets will appear here")
                .font(.title3.weight(.semibold))
            Text("Capture screens on the left and pick a headline on the right — we'll render 8 polished template sets in about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Divider().frame(maxWidth: 420).padding(.top, 4)

            HStack(spacing: 8) {
                stepTile(num: "01", title: "Capture", body: "Screens from your simulator.")
                stepTile(num: "02", title: "Write", body: "One headline for all sets.")
                stepTile(num: "03", title: "Generate", body: "8 ready-to-ship sets.")
            }
            .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppShotsTokens.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppShotsTokens.subtleStroke))
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func stepTile(num: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(num)
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(body)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppShotsTokens.insetBackground))
    }

    private var liveGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 380), spacing: 16)],
            spacing: 16
        ) {
            ForEach(manager.generated) { set in
                AppShotsSetCard(set: set) {
                    if manager.step == .done { onOpenSet(set) }
                }
            }
        }
    }
}

// MARK: - Inspector (right)

private struct InspectorPanel: View {
    var manager: AppShotsFlowManager
    let projectName: String

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inspector", trailing: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headlineSection
                    Divider()
                    frameSection
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            generateFooter
        }
        .frame(maxHeight: .infinity)
        .background(AppShotsTokens.panelBackground)
    }

    private var headlineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                AppShotsLabel(text: "Headline")
                TextField("", text: Binding(
                    get: { manager.headline },
                    set: { manager.headline = $0 }
                ), prompt: Text(projectName))
                .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                AppShotsLabel(text: "Subtitle · varies if blank")
                TextField("", text: Binding(
                    get: { manager.subtitle },
                    set: { manager.subtitle = $0 }
                ), prompt: Text("Optional"))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppShotsToggleRow(
                title: "Apply device frame",
                hint: "Wrap each capture in an iPhone bezel.",
                isOn: Binding(
                    get: { manager.useFrame },
                    set: { manager.useFrame = $0 }
                )
            )
            if manager.useFrame && !manager.availableFrames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    AppShotsLabel(text: "Device")
                    Picker("", selection: Binding(
                        get: { manager.selectedFrameName },
                        set: { manager.selectedFrameName = $0 }
                    )) {
                        ForEach(manager.availableFrames, id: \.name) { frame in
                            Text(frame.name).tag(frame.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var generateFooter: some View {
        VStack(spacing: 8) {
            primaryButton
            Text(generateHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .overlay(Divider(), alignment: .top)
    }

    @ViewBuilder
    private var primaryButton: some View {
        // Behavior depends on state. In .done we don't have captures in memory,
        // so "Regenerate" can't reuse them — we ship the user back to the capture step.
        if manager.step == .done && !manager.generated.isEmpty {
            Button {
                manager.regenerate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("New generation")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button {
                Task { await manager.generate(projectName: projectName) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(manager.step == .generating ? "Generating…" : "Generate 8 sets")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!manager.canGenerate || manager.step == .generating)
        }
    }

    private var generateHint: String {
        if manager.step == .done && !manager.generated.isEmpty {
            return "Capture new screens, then generate again."
        }
        if manager.step == .generating { return "Hold tight — rendering all templates in parallel." }
        if manager.includedCaptures.isEmpty && !manager.captures.isEmpty {
            return "All captures excluded — tick at least one to generate."
        }
        if manager.captures.isEmpty { return "Add at least one capture to start." }
        let n = manager.includedCaptures.count
        return "Will render 8 templates × \(n) capture\(n == 1 ? "" : "s") = \(n * 8) screenshots."
    }
}

// MARK: - Shared

private struct PanelHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}
