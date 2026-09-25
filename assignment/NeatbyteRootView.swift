import Photos
import SwiftUI
import UIKit

struct NeatbyteRootView: View {
    @State private var model = NeatbyteModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            DashboardView(model: model)
        }
        .alert(
            cleanupTitle,
            isPresented: Binding(
                get: { model.cleanupOutcome != nil },
                set: { isPresented in
                    if !isPresented { model.dismissOutcome() }
                }
            )
        ) {
            Button("OK") {
                model.dismissOutcome()
            }
        } message: {
            Text(cleanupMessage)
        }
        .sheet(
            item: Binding(
                get: { model.cleanupSummary },
                set: { if $0 == nil { model.dismissCleanupSummary() } }
            )
        ) { summary in
            CleanupSummaryView(summary: summary) {
                model.dismissCleanupSummary()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            model.refreshAuthorization()
            model.refreshContactAuthorization()
        }
    }

    private var cleanupTitle: LocalizedStringKey {
        switch model.cleanupOutcome {
        case .success: "Cleanup requested"
        case .cancelled: "Cleanup cancelled"
        case .failed: "Cleanup couldn’t finish"
        case nil: "Cleanup"
        }
    }

    private var cleanupMessage: LocalizedStringResource {
        switch model.cleanupOutcome {
        case .success(let deletedCount):
            "\(deletedCount) items were moved to Recently Deleted. iOS may not reclaim their space immediately."
        case .cancelled:
            "Your selection is still available and no cleanup was completed."
        case .failed(let message):
            message
        case nil:
            ""
        }
    }
}

struct DashboardView: View {
    let model: NeatbyteModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DashboardHeader()
                StorageCard(storage: model.storage)
                ReclaimableSummaryCard(
                    estimate: model.totalReclaimableEstimate,
                    isCalculating: model.scanPhase == .scanning
                        || model.videoScanPhase == .scanning
                        || model.photoScanPhase == .scanning
                )
                PrivacyCard()
                ScreenshotCategoryCard(model: model)
                LargeVideoCategoryCard(model: model)
                SimilarPhotosCategoryCard(model: model)
                BlurryPhotosCategoryCard(model: model)
                DuplicateContactsCategoryCard(model: model)
                PrivateVaultCategoryCard()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Neatbyte")
        .task {
            model.refreshAuthorization()
            if model.authorizationStatus == .authorized || model.authorizationStatus == .limited {
                await model.scanScreenshots()
            }
        }
    }
}

struct ReclaimableSummaryCard: View {
    let estimate: ReclaimableEstimate
    let isCalculating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cleanup potential", systemImage: "externaldrive.badge.checkmark")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if estimate.knownBytes > 0 {
                if estimate.isPartial {
                    Text("At least \(estimate.knownBytes, format: .byteCount(style: .file))")
                        .font(.title2.bold())
                } else {
                    Text(estimate.knownBytes, format: .byteCount(style: .file))
                        .font(.title2.bold())
                }
                Text("\(estimate.itemCount) media items available to review")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isCalculating || estimate.isCalculating {
                Text("Calculating available local media…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Scan the media categories to calculate potential savings.")
                    .foregroundStyle(.secondary)
            }

            if estimate.isPartial {
                Text("\(estimate.unknownSizeCount) iCloud-only or unavailable sizes are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ReclaimableEstimateText: View {
    let estimate: ReclaimableEstimate
    let scanPhase: ScanPhase

    var body: some View {
        Group {
            if scanPhase == .scanning || estimate.isCalculating {
                Text("Calculating potential savings…")
            } else if estimate.itemCount == 0 {
                if scanPhase == .idle {
                    Text("Scan to estimate savings")
                } else {
                    Text("No reclaimable items found")
                }
            } else if estimate.knownBytes > 0 {
                if estimate.isPartial {
                    Text("At least \(estimate.knownBytes, format: .byteCount(style: .file)) reclaimable")
                } else {
                    Text("\(estimate.knownBytes, format: .byteCount(style: .file)) potentially reclaimable")
                }
            } else if estimate.isPartial {
                Text("Storage size unavailable for accessible items")
            } else {
                Text("No local storage estimate available")
            }
        }
        .font(.caption)
        .foregroundStyle(.green)
    }
}

struct DashboardHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Storage, made calmer", systemImage: "leaf.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
                .accessibilityAddTraits(.isHeader)
            Text("Review everything before it leaves your library. Neatbyte processes your media on this iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorageCard: View {
    let storage: StorageSnapshot?

    var body: some View {
        HStack(spacing: 20) {
            Gauge(value: storage?.usedFraction ?? 0, in: 0...1) {
                Text("Device storage used")
            } currentValueLabel: {
                Text(storage.map { "\(Int($0.usedFraction * 100))%" } ?? "—")
                    .font(.caption2.bold())
            }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(.green)
                .frame(width: 54, height: 54)
                .accessibilityLabel("Device storage used")
                .accessibilityValue(storage.map { "\(Int($0.usedFraction * 100)) percent" } ?? "Unavailable")

            VStack(alignment: .leading, spacing: 6) {
                Text("iPhone Storage")
                    .font(.headline)
                if let storage {
                    Text("\(storage.usedBytes, format: .byteCount(style: .file)) used")
                    Text("\(storage.availableBytes, format: .byteCount(style: .file)) available")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Storage information unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PrivacyCard: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Private by design")
                    .font(.headline)
                Text("No photos or analysis leave your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ScreenshotCategoryCard: View {
    let model: NeatbyteModel

    var body: some View {
        NavigationLink {
            ScreenshotGalleryView(model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Screenshots")
                        .font(.headline)
                    Text(categorySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ReclaimableEstimateText(
                        estimate: model.screenshotReclaimableEstimate,
                        scanPhase: model.scanPhase
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
            .accessibilityLabel("Screenshots")
            .accessibilityValue(
                Text(model.screenshotReclaimableEstimate.accessibilityDescription(scanPhase: model.scanPhase))
            )
        }
        .buttonStyle(.plain)
    }

    private var categorySubtitle: LocalizedStringResource {
        switch model.authorizationStatus {
        case .authorized:
            "\(model.screenshots.count) found"
        case .limited:
            "\(model.screenshots.count) found in limited access"
        case .denied:
            "Photos access denied"
        case .restricted:
            "Photos access restricted"
        case .notDetermined:
            "Ready to scan"
        @unknown default:
            "Photos access unavailable"
        }
    }
}

struct ScreenshotGalleryView: View {
    let model: NeatbyteModel

    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: 3)
    ]

    var body: some View {
        content
            .navigationTitle("Screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.screenshots.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(model.selectedScreenshotIDs.count == model.screenshots.count ? "Clear" : "Select All") {
                            if model.selectedScreenshotIDs.count == model.screenshots.count {
                                model.clearScreenshotSelection()
                            } else {
                                model.selectAllScreenshots()
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.selectedIDs.isEmpty {
                    ReviewBar(model: model)
                }
            }
            .task {
                model.refreshAuthorization()
                if model.authorizationStatus == .authorized || model.authorizationStatus == .limited {
                    await model.scanScreenshots()
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
            ScreenshotResultsView(model: model, columns: columns)
        @unknown default:
            PhotosUnavailableView(isRestricted: true)
        }
    }
}

struct PhotosPermissionView: View {
    let model: NeatbyteModel

    var body: some View {
        ContentUnavailableView {
            Label("Find your screenshots", systemImage: "photo.badge.magnifyingglass")
        } description: {
            Text("Neatbyte needs read and write access so it can show screenshots and delete only the ones you approve. Processing stays on this iPhone.")
        } actions: {
            Button("Continue") {
                Task { await model.requestAccessAndScan() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }
}

struct PhotosUnavailableView: View {
    let isRestricted: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(
                isRestricted ? "Photos access restricted" : "Photos access denied",
                systemImage: "photo.badge.exclamationmark"
            )
        } description: {
            Text(isRestricted
                 ? "A device restriction prevents Neatbyte from accessing Photos."
                 : "Allow Photos access in Settings to scan and review screenshots.")
        } actions: {
            if !isRestricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ScreenshotResultsView: View {
    let model: NeatbyteModel
    let columns: [GridItem]

    var body: some View {
        VStack(spacing: 0) {
            if model.authorizationStatus == .limited {
                LimitedAccessBanner()
            }

            switch model.scanPhase {
            case .idle, .scanning:
                ProgressView("Scanning screenshots…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                if model.screenshots.isEmpty {
                    ContentUnavailableView("No screenshots found", systemImage: "sparkles", description: Text("There’s nothing to review in the accessible library."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(model.screenshots) { item in
                                ScreenshotTile(
                                    item: item,
                                    isSelected: model.selectedIDs.contains(item.id),
                                    photoLibrary: model.photoLibrary
                                ) {
                                    model.toggleSelection(for: item.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LimitedAccessBanner: View {
    var body: some View {
        Label("Showing only the photos you allowed. You can change this in Settings.", systemImage: "hand.raised.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.yellow.opacity(0.12))
    }
}

struct ScreenshotTile: View {
    let item: ScreenshotItem
    let isSelected: Bool
    let photoLibrary: PhotoLibraryService
    let toggleSelection: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink {
                ScreenshotPreviewView(
                    item: item,
                    photoLibrary: photoLibrary,
                    isSelected: isSelected,
                    toggleSelection: toggleSelection
                )
            } label: {
                PhotoAssetImage(
                    identifier: item.id,
                    photoLibrary: photoLibrary,
                    targetSize: CGSize(width: 320, height: 320)
                )
                .frame(minHeight: 132)
                .aspectRatio(0.75, contentMode: .fill)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview screenshot")
            .accessibilityValue(isSelected ? "Selected for deletion" : "Kept")

            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? .blue : .black.opacity(0.45))
                    .padding(7)
            }
            .accessibilityLabel(isSelected ? "Deselect screenshot" : "Select screenshot")
        }
    }
}

struct ScreenshotPreviewView: View {
    let item: ScreenshotItem
    let photoLibrary: PhotoLibraryService
    let isSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            PhotoAssetImage(
                identifier: item.id,
                photoLibrary: photoLibrary,
                targetSize: CGSize(width: 1400, height: 1400),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screenshot preview")

            if let creationDate = item.creationDate {
                Text(creationDate, format: .dateTime.day().month().year().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(isSelected ? "Keep this screenshot" : "Select for deletion") {
                toggleSelection()
            }
            .buttonStyle(.borderedProminent)
            .tint(isSelected ? .gray : .red)
            .padding(.bottom)
        }
        .padding(.horizontal)
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReviewBar: View {
    let model: NeatbyteModel

    var body: some View {
        NavigationLink {
            CleanupReviewView(model: model)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text("Review \(model.selectedIDs.count) selected")
                        .font(.headline)
                    SelectionSizeText(model: model)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
            }
            .foregroundStyle(.white)
            .padding()
            .background(
                Color(red: 0.04, green: 0.38, blue: 0.20).gradient,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
        .background(.bar)
    }
}

struct SelectionSizeText: View {
    let model: NeatbyteModel

    var body: some View {
        if model.selectedKnownBytes > 0 {
            Text("About \(model.selectedKnownBytes, format: .byteCount(style: .file))\(model.hasUnknownSelectedSizes ? "+" : "")")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        } else {
            Text("Measuring local sizes…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

struct CleanupReviewView: View {
    let model: NeatbyteModel
    @State private var showsConfirmation = false

    var body: some View {
        List {
            if !model.selectedScreenshots.isEmpty {
                Section {
                    ForEach(model.selectedScreenshots) { item in
                        ReviewRow(
                            item: item,
                            measuredBytes: model.measuredBytes[item.id],
                            photoLibrary: model.photoLibrary
                        )
                    }
                } header: {
                    Text("Screenshots to delete")
                }
            }

            if !model.selectedVideos.isEmpty {
                Section {
                    ForEach(model.selectedVideos) { video in
                        VideoReviewRow(
                            video: video,
                            measuredBytes: model.measuredBytes[video.id],
                            photoLibrary: model.photoLibrary
                        )
                    }
                } header: {
                    Text("Videos to delete")
                }
            }

            if !model.selectedGroupedPhotos.isEmpty {
                Section {
                    ForEach(model.selectedGroupedPhotos) { photo in
                        PhotoReviewRow(
                            photo: photo,
                            measuredBytes: model.measuredBytes[photo.id],
                            photoLibrary: model.photoLibrary
                        )
                    }
                } header: {
                    Text("Duplicate and similar photos to delete")
                }
            }

            if !model.selectedBlurryPhotos.isEmpty {
                Section {
                    ForEach(model.selectedBlurryPhotos) { photo in
                        PhotoReviewRow(
                            photo: photo,
                            measuredBytes: model.measuredBytes[photo.id],
                            photoLibrary: model.photoLibrary
                        )
                    }
                } header: {
                    Text("Blurry photos to delete")
                }
            }

            Section("Before you continue") {
                Label("Photos will show its own confirmation.", systemImage: "checkmark.shield")
                Label("Items move to Recently Deleted, so space may not return immediately.", systemImage: "clock.arrow.circlepath")
                Label("You can go back and change this selection.", systemImage: "arrow.uturn.backward")
            }
        }
        .navigationTitle("Final Review")
        .safeAreaInset(edge: .bottom) {
            Button {
                showsConfirmation = true
            } label: {
                if model.isDeleting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Delete \(model.selectedIDs.count) items")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.isDeleting || model.selectedIDs.isEmpty)
            .padding()
            .background(.bar)
        }
        .confirmationDialog(
            "Delete selected items?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue to Photos confirmation", role: .destructive) {
                Task { await model.deleteSelection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Neatbyte will request deletion only for the items listed here.")
        }
    }
}

struct ReviewRow: View {
    let item: ScreenshotItem
    let measuredBytes: Int64?
    let photoLibrary: PhotoLibraryService

    var body: some View {
        HStack(spacing: 12) {
            PhotoAssetImage(
                identifier: item.id,
                photoLibrary: photoLibrary,
                targetSize: CGSize(width: 160, height: 160)
            )
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                if let date = item.creationDate {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                } else {
                    Text("Screenshot")
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

#Preview {
    NeatbyteRootView()
}
