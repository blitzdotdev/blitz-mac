import SwiftUI

// Shared atoms for the App Shots views. Adaptive — light & dark mode.

// MARK: - Tokens

enum AppShotsTokens {
    // Two-surface system — matches the POC:
    //   canvas = the "board" — captures panel, sets canvas, inspector all share this
    //   cardSurface = elevated white surface — cards, inputs, capture rows
    // Everything else (shadows, borders) distinguishes elevation.

    /// Board background — captures / canvas / inspector all use this.
    /// Light gray in light mode; deep gray in dark mode.
    static var canvasBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// Back-compat alias; same as canvas so panels don't introduce a third tint.
    static var panelBackground: Color { canvasBackground }
    /// Elevated surface — cards, inputs, capture rows. White in light mode.
    static var cardSurface: Color { Color(nsColor: .controlBackgroundColor) }
    /// Alias for inset (form inputs, inset tiles).
    static var insetBackground: Color { cardSurface }
    /// Hairline rules.
    static var separator: Color { Color(nsColor: .separatorColor) }
    /// Subtle filled strokes (cards, dashed dropzones).
    static var subtleStroke: Color { Color.primary.opacity(0.10) }
}

// MARK: - Background

struct AppShotsBackground: View {
    var body: some View {
        AppShotsTokens.canvasBackground.ignoresSafeArea()
    }
}

// MARK: - Section card

struct AppShotsSectionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppShotsTokens.insetBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppShotsTokens.subtleStroke))
    }
}

// MARK: - Section label

struct AppShotsLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - Toggle row

struct AppShotsToggleRow: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Set card
//
// Big multi-thumb card: up to 3 inline thumbs + "+N" overflow tile + meta row.
// Each thumb stretches via `flex: 1 1 0` equivalent so thumbs are large enough
// to read as real App Store screenshots, not icons.
struct AppShotsSetCard: View {
    let set: GeneratedSet
    var onOpen: (() -> Void)? = nil

    private static let inlineLimit = 3

    var body: some View {
        Button { onOpen?() } label: {
            VStack(spacing: 14) {
                thumbStrip
                meta
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppShotsTokens.cardSurface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppShotsTokens.subtleStroke))
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Thumb strip

    private var thumbStrip: some View {
        let visibleCount = min(Self.inlineLimit, set.screenshots.count)
        let visible = Array(set.screenshots.prefix(visibleCount))
        let overflow = max(0, set.screenshots.count - visibleCount)
        return HStack(alignment: .top, spacing: 8) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, shot in
                thumbnail(
                    shot: shot,
                    moreBadge: (index == visible.count - 1 && overflow > 0) ? "+\(overflow)" : nil
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func thumbnail(shot: GeneratedScreenshot, moreBadge: String?) -> some View {
        ZStack(alignment: .topTrailing) {
            // Always paint the template's palette gradient underneath — that's the card's identity.
            LinearGradient(colors: [paletteStart, paletteEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

            if let image = shot.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if shot.error != nil {
                failedOverlay
            }

            if let moreBadge {
                Text(moreBadge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.72)))
                    .padding(6)
            }
        }
        .aspectRatio(9/19.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .help(shot.error.map { "Render failed — \($0)" } ?? "")
    }

    private var failedOverlay: some View {
        ZStack {
            // Hatched amber — clearly "something went wrong" but still palette-contextual.
            Rectangle().fill(Color(red: 1.0, green: 0.96, blue: 0.90))
                .overlay(
                    Rectangle().fill(LinearGradient(
                        stops: [.init(color: Color.orange.opacity(0.18), location: 0),
                                .init(color: .clear, location: 0.5),
                                .init(color: Color.orange.opacity(0.18), location: 1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }


    // MARK: Meta row

    private var meta: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.template.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(set.template.category.capitalized) · \(set.screenshots.count) shot\(set.screenshots.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            statusBadge
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let failed = set.screenshots.filter { $0.error != nil }.count
        if failed > 0 {
            Text("\(set.readyCount)/\(set.screenshots.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else if set.isReady {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                Text("ready")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        } else {
            Text("rendering…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Palette

    private var paletteStart: Color {
        Color(hex: set.template.palette?.background ?? "#4b5563") ?? .gray
    }
    private var paletteEnd: Color {
        paletteStart.opacity(0.78)
    }
    /// Pick light or dark text based on palette luminance.
    private var headlineColor: Color {
        let lum = paletteLuminance
        return lum < 0.6 ? .white : Color.black.opacity(0.85)
    }
    private var paletteLuminance: Double {
        guard let hex = set.template.palette?.background,
              let c = Color(hex: hex) else { return 0 }
        let ns = NSColor(c).usingColorSpace(.deviceRGB)
        guard let ns else { return 0 }
        return 0.2126 * Double(ns.redComponent) + 0.7152 * Double(ns.greenComponent) + 0.0722 * Double(ns.blueComponent)
    }
}

/// Modal that shows every screenshot in a set at full size and lets the user
/// ship them straight to App Store Connect.
///
/// Takes the manager + setId (not the set itself) so the sheet re-reads live state
/// after retries / regenerates.
struct AppShotsSetDetailSheet: View {
    let manager: AppShotsFlowManager
    let setId: String
    let projectName: String
    let onClose: () -> Void

    /// Live lookup: the sheet re-reads from the manager each render so retries update in place.
    /// Methods below assume this is non-nil — `body` guards first.
    private var set: GeneratedSet {
        manager.generated.first(where: { $0.id == setId })
            ?? GeneratedSet(id: setId, template: ASCManager.AppShotTemplate(id: setId, name: "—", category: "—", description: "", deviceCount: 1, palette: nil), headline: "", subtitle: nil, screenshots: [])
    }
    private var setExists: Bool { manager.generated.contains(where: { $0.id == setId }) }

    var body: some View {
        Group {
            if setExists {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.35)
                    scroller
                    Divider().opacity(0.35)
                    footer
                }
            } else {
                VStack(spacing: 12) {
                    Text("This set is no longer available.")
                        .font(.headline)
                    Button("Close") { onClose() }
                }
                .padding(40)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(backdrop)
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            LinearGradient(
                colors: [
                    washColor.opacity(0.34),
                    washColor.opacity(0.12),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [washColor.opacity(0.18), .clear],
                center: UnitPoint(x: 0.88, y: 0.78),
                startRadius: 60,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    /// A pastel "lifted" version of the template palette — palette mixed toward
    /// white so dark palettes (navy, charcoal) still read as a visible tint
    /// instead of muddying into gray.
    private var washColor: Color {
        guard let ns = NSColor(paletteColor).usingColorSpace(.deviceRGB) else { return paletteColor }
        let mix: Double = 0.55
        let r = Double(ns.redComponent)
        let g = Double(ns.greenComponent)
        let b = Double(ns.blueComponent)
        return Color(
            red: r + (1 - r) * mix,
            green: g + (1 - g) * mix,
            blue: b + (1 - b) * mix
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            palettePuck
            VStack(alignment: .leading, spacing: 4) {
                Text(set.template.name).font(.title3.weight(.semibold))
                metaRow
            }
            Spacer(minLength: 12)
            if let folder = folderPath {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
                } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                // Placeholder for the ASC upload flow — stub for now.
            } label: {
                Label("Upload to ASC", systemImage: "arrow.up.forward.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(readyCount == 0)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var palettePuck: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(LinearGradient(
                colors: [paletteColor, paletteColor.opacity(0.70)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.08)))
            .shadow(color: paletteColor.opacity(0.30), radius: 6, y: 2)
            .frame(width: 32, height: 32)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            categoryChip
            Text("\(set.screenshots.count) shot\(set.screenshots.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text("\u{201C}\(set.headline)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var categoryChip: some View {
        Text(set.template.category.capitalized)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.primary.opacity(0.82))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(paletteColor.opacity(0.16)))
            .overlay(Capsule().strokeBorder(paletteColor.opacity(0.28)))
    }

    // MARK: - Horizontal screenshots row
    //
    // App Store listings are horizontal — so is the preview. All N screenshots
    // stay at the same height, user scrolls left-right. Feels like the store itself.

    private var scroller: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(set.screenshots.enumerated()), id: \.element.id) { index, shot in
                        shotCard(shot, index: index + 1, height: cardHeight(for: geo.size.height))
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
        }
    }

    /// Pick a consistent card height from the available vertical space.
    private func cardHeight(for height: CGFloat) -> CGFloat {
        let available = max(240, height - 88)
        return min(available, 560)
    }

    private func shotCard(_ shot: GeneratedScreenshot, index: Int, height: CGFloat) -> some View {
        let width = height * 9 / 16
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(paletteColor)
                if let image = shot.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else if shot.error != nil {
                    failedBadge
                }
            }
            .frame(width: width, height: height)
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.10)))
            .shadow(color: paletteColor.opacity(0.35), radius: 28, y: 18)
            .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)

            HStack(spacing: 6) {
                Text("Screen \(index)")
                    .font(.caption.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(shot.captureLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if shot.error != nil {
                    Button {
                        Task {
                            await manager.retryScreenshot(
                                setId: setId,
                                screenshotId: shot.id,
                                projectName: projectName
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Retry this render")
                } else if let path = shot.imagePath {
                    iconButton(systemName: "eye", tooltip: "Preview") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    iconButton(systemName: "folder", tooltip: "Show in Finder") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
            }
            .frame(width: width)
        }
    }

    private func iconButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tooltip)
    }

    private var failedBadge: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Render failed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.orange.opacity(0.10)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.forward.circle")
                .foregroundStyle(.secondary)
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Change locale") {
                // Placeholder — future locale picker.
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var footerText: String {
        let ready = readyCount
        if ready == 0 { return "No renders ready yet — upload will enable once at least one shot finishes." }
        return "Uploading sends these \(ready) PNG\(ready == 1 ? "" : "s") to the en-US locale in App Store Connect."
    }

    // MARK: - Helpers

    private var readyCount: Int {
        let shots = set.screenshots
        return shots.filter { $0.image != nil }.count
    }

    private var paletteColor: Color {
        if let hex = set.template.palette?.background, let c = Color(hex: hex) { return c }
        return Color.gray.opacity(0.3)
    }

    private var folderPath: String? {
        guard let path = set.screenshots.compactMap({ $0.imagePath }).first else { return nil }
        return (path as NSString).deletingLastPathComponent
    }
}

// MARK: - Hex helper

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}
