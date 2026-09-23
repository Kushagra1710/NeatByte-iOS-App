import Photos
import SwiftUI

struct SimilarPhotosCategoryCard: View {
    let model: ClearNestModel

    var body: some View {
        NavigationLink {
            SimilarPhotosView(model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "photo.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate & Similar Photos")
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ReclaimableEstimateText(
                        estimate: model.similarPhotoReclaimableEstimate,
                        scanPhase: model.photoScanPhase
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
            .accessibilityLabel("Duplicate and Similar Photos")
            .accessibilityValue(
                Text(model.similarPhotoReclaimableEstimate.accessibilityDescription(scanPhase: model.photoScanPhase))
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: LocalizedStringResource {
        switch model.photoScanPhase {
        case .scanning:
            "Analyzing on device"
        case .ready:
            "\(model.photoGroups.count) groups found"
        case .failed:
            "Scan needs attention"
        case .idle:
            "Ready to scan"
        }
    }
}

struct SimilarPhotosView: View {
    let model: ClearNestModel

    var body: some View {
        VStack(spacing: 0) {
            if model.authorizationStatus == .limited {
                LimitedAccessBanner()
            }

            if model.photoScanPhase == .scanning {
                PhotoScanProgressView(
                    progress: model.photoScanProgress,
                    cancel: model.cancelPhotoScan
                )
            }

            content
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.selectedIDs.isEmpty {
                ReviewBar(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.photoScanPhase == .scanning {
                    Button("Cancel") {
                        model.cancelPhotoScan()
                    }
                } else if model.photoGroups.isEmpty {
                    Button("Scan") {
                        model.startPhotoScan()
                    }
                    .accessibilityIdentifier("similarPhotosScanButton")
                } else {
                    Button("Rescan") {
                        model.startPhotoScan()
                    }
                    .accessibilityIdentifier("similarPhotosScanButton")
                }
            }
        }
        .task {
            model.refreshAuthorization()
            if model.photoGroups.isEmpty,
               model.authorizationStatus == .authorized || model.authorizationStatus == .limited {
                model.startPhotoScan()
            }
        }
        .onChange(of: model.authorizationStatus) { _, newStatus in
            if model.photoGroups.isEmpty,
               newStatus == .authorized || newStatus == .limited {
                model.startPhotoScan()
            }
        }
        .onDisappear {
            if model.photoScanPhase == .scanning {
                model.cancelPhotoScan()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.authorizationStatus {
        case .notDetermined:
            PhotosPermissionView(model: model)
        case .denied:
            PhotosUnavailableView(isRestricted: false)
        case .restricted:
            PhotosUnavailableView(isRestricted: true)
        case .authorized, .limited:
            if model.photoGroups.isEmpty {
                if model.photoScanPhase == .scanning {
                    Spacer()
                } else {
                    ContentUnavailableView(
                        "No groups found",
                        systemImage: "photo.stack",
                        description: Text("ClearNest found no verified duplicates or conservatively matched similar photos.")
                    )
                }
            } else {
                List(model.photoGroups) { group in
                    PhotoGroupRow(group: group, model: model)
                }
                .listStyle(.plain)
            }
        @unknown default:
            PhotosUnavailableView(isRestricted: true)
        }
    }
}

struct PhotoScanProgressView: View {
    let progress: ScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comparing photos on device")
                        .font(.subheadline.bold())
                    Text("This can take a while for large libraries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
            }
            ProgressView(value: progress.fraction)
                .tint(.orange)
        }
        .padding()
        .background(.orange.opacity(0.08))
    }
}

struct PhotoGroupRow: View {
    let group: PhotoGroup
    let model: ClearNestModel

    var body: some View {
        NavigationLink {
            PhotoGroupReviewContent(groupID: group.id, model: model)
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(group.members.prefix(3)) { photo in
                        PhotoAssetImage(
                            identifier: photo.id,
                            photoLibrary: model.photoLibrary,
                            targetSize: CGSize(width: 150, height: 150)
                        )
                        .frame(width: 48, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(group.kind.title)
                        .font(.headline)
                    Text("\(group.members.count) photos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(group.kind == .exact ? "Byte-for-byte verified" : "Vision match—review carefully")
                        .font(.caption)
                        .foregroundStyle(group.kind == .exact ? .green : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct PhotoGroupReviewContent: View {
    let groupID: String
    let model: ClearNestModel

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]

    var body: some View {
        if let group = model.photoGroups.first(where: { $0.id == groupID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PhotoGroupExplanation(group: group)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(group.members) { photo in
                            GroupedPhotoTile(
                                photo: photo,
                                isKeeper: group.keeperID == photo.id,
                                isSelected: model.selectedIDs.contains(photo.id),
                                photoLibrary: model.photoLibrary,
                                makeKeeper: { model.setKeeper(photo.id, in: group.id) },
                                toggleSelection: { model.toggleSelection(for: photo.id) }
                            )
                        }
                    }

                    ViewThatFits {
                        HStack {
                            GroupReviewActions(groupID: group.id, model: model)
                        }
                        VStack {
                            GroupReviewActions(groupID: group.id, model: model)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(group.kind == .exact ? "Exact Duplicates" : "Similar Photos")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if !model.selectedIDs.isEmpty {
                    ReviewBar(model: model)
                }
            }
        } else {
            ContentUnavailableView("Group unavailable", systemImage: "photo.stack")
        }
    }
}

struct PhotoGroupExplanation: View {
    let group: PhotoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                group.kind == .exact ? "Verified exact duplicate" : "Visually similar—not identical",
                systemImage: group.kind == .exact ? "checkmark.seal.fill" : "eye.fill"
            )
            .font(.headline)
            .foregroundStyle(group.kind == .exact ? .green : .orange)

            Text(group.kind == .exact
                 ? "The original resource bytes have matching SHA-256 hashes."
                 : "Vision found a close visual match among photos taken within ten seconds. Review every photo before selecting it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(group.recommendation.message)
                .font(.subheadline.bold())
        }
    }
}

struct GroupedPhotoTile: View {
    let photo: PhotoCandidate
    let isKeeper: Bool
    let isSelected: Bool
    let photoLibrary: PhotoLibraryService
    let makeKeeper: () -> Void
    let toggleSelection: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PhotoAssetImage(
                    identifier: photo.id,
                    photoLibrary: photoLibrary,
                    targetSize: CGSize(width: 420, height: 420)
                )
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if isKeeper {
                    Label("Keep", systemImage: "checkmark")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(7)
                } else {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? .red : .white)
                            .padding(7)
                    }
                    .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo for deletion")
                }
            }

            Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !isKeeper {
                Button("Make keeper", action: makeKeeper)
                    .font(.caption)
            }
        }
    }
}

struct GroupReviewActions: View {
    let groupID: String
    let model: ClearNestModel

    var body: some View {
        Button("Select suggested deletions") {
            model.selectSuggestedDeletions(in: groupID)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)

        Button("Keep all") {
            model.keepAll(in: groupID)
        }
        .buttonStyle(.bordered)
    }
}

struct PhotoReviewRow: View {
    let photo: PhotoCandidate
    let measuredBytes: Int64?
    let photoLibrary: PhotoLibraryService

    var body: some View {
        HStack(spacing: 12) {
            PhotoAssetImage(
                identifier: photo.id,
                photoLibrary: photoLibrary,
                targetSize: CGSize(width: 160, height: 160)
            )
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                if let date = photo.creationDate {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                } else {
                    Text("Photo")
                }
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
