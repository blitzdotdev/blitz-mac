import SwiftUI

struct AppShotsHeroView: View {
    let hasProject: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                Text("No sets yet")
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
            .foregroundStyle(Color.accentColor)

            Text("Build your App Store screenshot sets")
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)

            Text("Capture a handful of screens from your simulator, pick a headline — we'll lay them into 8 polished template sets you can ship.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            if hasProject {
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        Text("Start building")
                        Image(systemName: "arrow.right")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .frame(minWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)

                Text("Takes about 1 minute · device frames included")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                noProjectHint
            }

            Spacer()

            HStack(spacing: 12) {
                tile(num: "01 CAPTURE",
                     title: "Screens from your sim",
                     body: "Use Capture or Record while you tap through your app. Uploading PNGs also works.")
                tile(num: "02 FRAME & WRITE",
                     title: "Device frame + varied copy",
                     body: "Auto device-frame per template; subtitles vary so 8 sets actually look distinct.")
                tile(num: "03 PERSISTENT",
                     title: "Your sets stay here",
                     body: "Come back anytime — the App Shots tab is always your sets for this project.")
            }
            .padding(.top, 16)
        }
        .padding(40)
        .frame(maxWidth: 900)
    }

    private var noProjectHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Pick a project in the sidebar to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppShotsTokens.insetBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppShotsTokens.subtleStroke))
    }

    private func tile(num: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(num).font(.caption2).foregroundStyle(.tertiary).tracking(0.5)
            Text(title).font(.callout.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppShotsTokens.insetBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppShotsTokens.subtleStroke))
    }
}
