import SwiftUI

struct BuildProgressView: View {
    let runtime: ProjectRuntime

    private let steps: [(status: RuntimeStatus, label: String)] = [
        (.installingDependencies, "Install Dependencies"),
        (.startingIOSBuild, "Build iOS App"),
        (.startingMetro, "Start Metro"),
        (.startingVite, "Start Vite"),
        (.startingBackend, "Start Backend"),
        (.running, "Running"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps, id: \.status) { step in
                HStack(spacing: 8) {
                    stepIcon(for: step.status)
                        .frame(width: 16)

                    Text(step.label)
                        .font(.system(size: 12))
                        .foregroundStyle(stepColor(for: step.status))
                }
            }

            if let error = runtime.error {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 16)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .padding(.top, 4)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func stepIcon(for step: RuntimeStatus) -> some View {
        if runtime.status == step {
            ProgressView()
                .scaleEffect(0.5)
        } else if runtime.status > step {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        } else {
            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 12, height: 12)
        }
    }

    private func stepColor(for step: RuntimeStatus) -> Color {
        if runtime.status == step { return .primary }
        if runtime.status > step { return .secondary }
        return .secondary.opacity(0.5)
    }
}
