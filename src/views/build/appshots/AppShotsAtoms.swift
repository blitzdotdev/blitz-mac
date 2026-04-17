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
            ForEach(visible) { shot in
                thumbnail(shot: shot)
                    .frame(maxWidth: .infinity)
            }
            if overflow > 0 {
                overflowTile(count: overflow)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func thumbnail(shot: GeneratedScreenshot) -> some View {
        ZStack {
            // Always paint the template's palette gradient underneath — that's the card's identity.
            LinearGradient(colors: [paletteStart, paletteEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

            if let image = shot.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if shot.error != nil {
                failedOverlay
            } else {
                // During generation: render a preview skeleton so the user sees the template
                // style (not an empty gray void). Headline overlay + phone mockup.
                previewSkeleton
            }
        }
        .aspectRatio(9/19.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .help(shot.error.map { "Render failed — \($0)" } ?? "")
    }

    /// Preview of what the template will look like — shown during generation so the
    /// thumbnail doesn't read as "empty gray placeholder".
    private var previewSkeleton: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Headline overlay at top
                Text(set.headline)
                    .font(.system(size: max(7, geo.size.width * 0.11), weight: .bold))
                    .foregroundStyle(headlineColor)
                    .shadow(color: .black.opacity(headlineColor == .white ? 0.18 : 0), radius: 1, y: 1)
                    .lineLimit(2)
                    .padding(.horizontal, geo.size.width * 0.10)
                    .padding(.top, geo.size.height * 0.09)

                // Phone mockup rising from the bottom with 3 faint content stripes
                phoneMockup(in: geo.size)
                    .frame(
                        width: geo.size.width * 0.76,
                        height: geo.size.height * 0.62
                    )
                    .offset(x: geo.size.width * 0.12, y: geo.size.height * 0.33)
            }
        }
    }

    private func phoneMockup(in size: CGSize) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color(red: 0.17, green: 0.17, blue: 0.18),
                             Color(red: 0.08, green: 0.08, blue: 0.09)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2))

            // Dynamic island / notch
            Capsule()
                .fill(Color.black)
                .frame(width: size.width * 0.26, height: size.height * 0.044)
                .offset(y: size.height * 0.02)

            // Three faint content stripes suggesting app content
            VStack(spacing: size.height * 0.025) {
                stripe
                stripe
                stripe
            }
            .padding(.horizontal, size.width * 0.14)
            .padding(.top, size.height * 0.14)
        }
    }

    private var stripe: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.06))
            .frame(height: 6)
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

    /// Overflow tile matches the card's palette family (not gray), so the row reads as one set.
    private func overflowTile(count: Int) -> some View {
        ZStack {
            LinearGradient(
                colors: [paletteStart.opacity(0.35), paletteEnd.opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 2) {
                Text("+\(count)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(headlineColor.opacity(0.9))
                Text("more")
                    .font(.caption2)
                    .foregroundStyle(headlineColor.opacity(0.65))
            }
        }
        .aspectRatio(9/19.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
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

/// Modal that shows every screenshot in a set at full size.
struct AppShotsSetDetailSheet: View {
    let set: GeneratedSet
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.template.name).font(.headline)
                    Text("\(set.template.category.capitalized) · \(set.screenshots.count) shots · \"\(set.headline)\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let folder = folderPath {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
                    } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.bordered)
                }
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(set.screenshots) { shot in
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(paletteColor)
                                if let image = shot.image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else if shot.error != nil {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .aspectRatio(9/16, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppShotsTokens.subtleStroke))

                            HStack {
                                Text(shot.captureLabel).font(.caption.weight(.medium))
                                Spacer()
                                if let path = shot.imagePath {
                                    Button {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    } label: { Image(systemName: "eye").font(.caption2) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
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
