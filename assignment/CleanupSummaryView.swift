import SwiftUI

struct CleanupSummaryView: View {
    let summary: CleanupSummary
    let done: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.green.opacity(0.14))
                    .frame(width: 124, height: 124)
                Image(systemName: "sparkles")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Cleanup Complete")
                    .font(.largeTitle.bold())
                Text("\(summary.deletedCount) item\(summary.deletedCount == 1 ? "" : "s") moved to Recently Deleted")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                Text(summary.hasUnknownSizes ? "At least" : "Space selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if summary.knownBytes > 0 {
                    Text(summary.knownBytes, format: .byteCount(style: .file))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("Size unavailable")
                        .font(.title2.bold())
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))

            Label(
                "iOS may not reclaim this space until Recently Deleted is emptied.",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()

            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
