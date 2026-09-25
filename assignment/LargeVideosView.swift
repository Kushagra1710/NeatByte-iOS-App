import AVFoundation
import AVKit
import Photos
import SwiftUI

struct LargeVideoCategoryCard: View {
    let model: NeatbyteModel

    var body: some View {
        NavigationLink {
            LargeVideosView(model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.purple.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Large Videos")
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ReclaimableEstimateText(
                        estimate: model.videoReclaimableEstimate,
                        scanPhase: model.videoScanPhase
                    )
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Large Videos")
            .accessibilityValue(
                Text(model.videoReclaimableEstimate.accessibilityDescription(scanPhase: model.videoScanPhase))
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: LocalizedStringResource {
        switch model.videoScanPhase {
        case .scanning:
            "Measuring \(model.videoScanProgress.completed) of \(model.videoScanProgress.total)"
        case .ready:
            "\(model.largeVideos.count) found"
        case .failed:
            "Scan needs attention"
        case .idle:
            "Ready to scan"
        }
    }
}

struct LargeVideosView: View {
    let model: NeatbyteModel

    var body: some View {
        VStack(spacing: 0) {
            if model.authorizationStatus == .limited {
                LimitedAccessBanner()
            }

            if model.videoScanPhase == .scanning {
                VideoScanProgressView(
                    progress: model.videoScanProgress,
                    cancel: model.cancelVideoScan
                )
            }

            videoContent
        }
        .navigationTitle("Large Videos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.selectedIDs.isEmpty {
                ReviewBar(model: model)
            }
        }
        .toolbar {
            if model.videoScanPhase != .scanning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.largeVideos.isEmpty ? "Scan" : "Rescan") {
                        model.startVideoScan()
                    }
                }
            }
        }
        .task {
            model.refreshAuthorization()
            if model.largeVideos.isEmpty,
               model.authorizationStatus == .authorized || model.authorizationStatus == .limited {
                model.startVideoScan()
            }
        }
        .onChange(of: model.authorizationStatus) { _, newStatus in
            if model.largeVideos.isEmpty,
               newStatus == .authorized || newStatus == .limited {
                model.startVideoScan()
            }
        }
        .onDisappear {
            if model.videoScanPhase == .scanning {
                model.cancelVideoScan()
            }
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        switch model.authorizationStatus {
        case .notDetermined:
            PhotosPermissionView(model: model)
        case .denied:
            PhotosUnavailableView(isRestricted: false)
        case .restricted:
            PhotosUnavailableView(isRestricted: true)
        case .authorized, .limited:
            if model.largeVideos.isEmpty {
                if model.videoScanPhase == .scanning {
                    Spacer()
                } else {
                    ContentUnavailableView(
                        "No videos found",
                        systemImage: "video.slash",
                        description: Text("There are no videos in the accessible library.")
                    )
                }
            } else {
                List(model.largeVideos) { video in
                    LargeVideoRow(
                        video: video,
                        measuredBytes: model.measuredBytes[video.id],
                        isSelected: model.selectedIDs.contains(video.id),
                        photoLibrary: model.photoLibrary
                    ) {
                        model.toggleSelection(for: video.id)
                    }
                }
                .listStyle(.plain)
            }
        @unknown default:
            PhotosUnavailableView(isRestricted: true)
        }
    }
}

struct VideoScanProgressView: View {
    let progress: ScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measuring local videos")
                        .font(.subheadline.bold())
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
            }
            ProgressView(value: progress.fraction)
                .tint(.purple)
        }
        .padding()
        .background(.purple.opacity(0.08))
    }
}

struct LargeVideoRow: View {
    let video: LargeVideoItem
    let measuredBytes: Int64?
    let isSelected: Bool
    let photoLibrary: PhotoLibraryService
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                LargeVideoPreviewView(
                    video: video,
                    measuredBytes: measuredBytes,
                    isSelected: isSelected,
                    photoLibrary: photoLibrary,
                    toggleSelection: toggleSelection
                )
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        PhotoAssetImage(
                            identifier: video.id,
                            photoLibrary: photoLibrary,
                            targetSize: CGSize(width: 280, height: 180)
                        )
                        .frame(width: 112, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text(Duration.seconds(video.duration), format: .time(pattern: .minuteSecond))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let measuredBytes {
                            Text(measuredBytes, format: .byteCount(style: .file))
                                .font(.headline)
                        } else {
                            Text("Size unavailable locally")
                                .font(.subheadline.bold())
                        }
                        Text("\(video.pixelWidth) × \(video.pixelHeight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let date = video.creationDate {
                            Text(date, format: .dateTime.day().month().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? .purple : .secondary)
            }
            .accessibilityLabel(isSelected ? "Deselect video" : "Select video")
        }
        .padding(.vertical, 4)
    }
}

struct LargeVideoPreviewView: View {
    let video: LargeVideoItem
    let measuredBytes: Int64?
    let isSelected: Bool
    let photoLibrary: PhotoLibraryService
    let toggleSelection: () -> Void

    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                } else if loadFailed {
                    ContentUnavailableView(
                        "Video unavailable",
                        systemImage: "icloud.slash",
                        description: Text("The full video may only be available in iCloud.")
                    )
                    .frame(height: 280)
                } else {
                    ProgressView("Loading local video…")
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                }

                VStack(spacing: 4) {
                    Text(Duration.seconds(video.duration), format: .time(pattern: .minuteSecond))
                    if let measuredBytes {
                        Text(measuredBytes, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Exact size unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)

                VideoCompressionSection(
                    video: video,
                    originalBytes: measuredBytes,
                    photoLibrary: photoLibrary,
                    isOriginalSelected: isSelected,
                    selectOriginalForDeletion: toggleSelection
                )

                Button(isSelected ? "Keep this video" : "Select original for deletion") {
                    toggleSelection()
                }
                .buttonStyle(.borderedProminent)
                .tint(isSelected ? .gray : .red)
                .padding(.bottom)
            }
            .padding()
        }
        .navigationTitle("Video Preview")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: video.id) {
            do {
                let asset = try await photoLibrary.requestLocalAVAsset(identifier: video.id)
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch {
                loadFailed = true
            }
        }
    }
}

struct VideoReviewRow: View {
    let video: LargeVideoItem
    let measuredBytes: Int64?
    let photoLibrary: PhotoLibraryService

    var body: some View {
        HStack(spacing: 12) {
            PhotoAssetImage(
                identifier: video.id,
                photoLibrary: photoLibrary,
                targetSize: CGSize(width: 180, height: 120)
            )
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(Duration.seconds(video.duration), format: .time(pattern: .minuteSecond))
                if let measuredBytes {
                    Text(measuredBytes, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Size unavailable locally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
