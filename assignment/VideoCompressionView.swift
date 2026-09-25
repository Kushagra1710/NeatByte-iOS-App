import SwiftUI

struct VideoCompressionSection: View {
    let video: LargeVideoItem
    let originalBytes: Int64?
    let photoLibrary: PhotoLibraryService
    let isOriginalSelected: Bool
    let selectOriginalForDeletion: () -> Void

    @State private var model = VideoCompressionModel()
    @State private var quality: VideoCompressionQuality = .balanced
    @State private var showsSavedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Compress Video", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.headline)

            Text("Neatbyte creates a smaller copy in Photos. The original is never deleted automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("Compression quality", selection: $quality) {
                ForEach(VideoCompressionQuality.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isWorking)

            Text(quality.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            VideoCompressionStatus(
                state: model.state,
                progress: model.progress
            )

            compressionActions
        }
        .padding()
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: model.state) { _, newState in
            if case .completed = newState {
                showsSavedAlert = true
            }
        }
        .alert("Compressed Video Saved", isPresented: $showsSavedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The compressed copy was saved in the Photos app. Your original video is still unchanged.")
        }
        .onDisappear {
            if model.isWorking {
                model.cancel()
            }
        }
    }

    @ViewBuilder
    private var compressionActions: some View {
        switch model.state {
        case .idle, .failed:
            Button {
                Task {
                    await model.compress(
                        identifier: video.id,
                        originalBytes: originalBytes,
                        quality: quality,
                        photoLibrary: photoLibrary
                    )
                }
            } label: {
                Label("Create compressed copy", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

        case .preparing, .exporting, .saving:
            Button("Cancel compression", role: .cancel) {
                model.cancel()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

        case .completed:
            VStack(spacing: 10) {
                Label("Compressed copy saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)

                if !isOriginalSelected {
                    Button("Select original for deletion", role: .destructive) {
                        selectOriginalForDeletion()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Label("Original selected for review", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Compress another copy") {
                    model.reset()
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct VideoCompressionStatus: View {
    let state: VideoCompressionState
    let progress: Double

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("Preparing local video…")
        case .exporting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(.purple)
                Text("\(Int(progress * 100))% compressed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .saving:
            ProgressView("Saving compressed copy to Photos…")
        case .completed(let result):
            VStack(alignment: .leading, spacing: 4) {
                Text("Compressed size: \(result.compressedBytes, format: .byteCount(style: .file))")
                if let savedBytes = result.savedBytes, savedBytes > 0 {
                    Text("Potential saving: \(savedBytes, format: .byteCount(style: .file))")
                        .foregroundStyle(.green)
                } else if result.originalBytes != nil {
                    Text("This preset did not produce a smaller file.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote.bold())
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
