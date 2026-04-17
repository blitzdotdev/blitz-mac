import SwiftUI

// Shared atoms for the App Shots views. Adaptive — light & dark mode.

// MARK: - Tokens

enum AppShotsTokens {
    /// Tab background — adapts to system appearance.
    static var canvasBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// Slightly distinct surface for sidebars / inspector.
    static var panelBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    /// Inset surface — input fields, capture rows.
    static var insetBackground: Color { Color(nsColor: .controlBackgroundColor) }
    /// Hairline rules.
    static var separator: Color { Color(nsColor: .separatorColor) }
    /// Subtle filled strokes (cards, dashed dropzones).
    static var subtleStroke: Color { Color.primary.opacity(0.12) }
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

/// Preview card for a generated (or in-flight) set. A "set" contains N screenshots
/// (one per source capture). The card shows up to 3 inline + a "+N" badge if more.
struct AppShotsSetCard: View {
    let set: GeneratedSet
    var onOpen: (() -> Void)? = nil

    private static let maxInline = 3

    var body: some View {
        Button {
            onOpen?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailStrip
                meta
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppShotsTokens.insetBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppShotsTokens.subtleStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var thumbnailStrip: some View {
        let inline = Array(set.screenshots.prefix(Self.maxInline))
        let overflow = max(0, set.screenshots.count - Self.maxInline)
        return HStack(spacing: 6) {
            ForEach(inline) { shot in
                screenshotThumb(shot)
            }
            if overflow > 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(paletteColor.opacity(0.85))
                    Text("+\(overflow)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .aspectRatio(9/16, contentMode: .fit)
            }
        }
    }

    private func screenshotThumb(_ shot: GeneratedScreenshot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(paletteColor)
            if let image = shot.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if shot.error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppShotsTokens.subtleStroke))
        .aspectRatio(9/16, contentMode: .fit)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(set.template.name).font(.caption.weight(.semibold))
                Text("\(set.template.category.capitalized) · \(set.screenshots.count) shot\(set.screenshots.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if set.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Text("\(set.readyCount)/\(set.screenshots.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var paletteColor: Color {
        if let hex = set.template.palette?.background, let c = Color(hex: hex) { return c }
        return Color.gray.opacity(0.3)
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
