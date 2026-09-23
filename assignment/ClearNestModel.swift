import Foundation
import Observation
import Photos

@MainActor
@Observable
final class ClearNestModel {
    private let storageService: StorageService
    let photoLibrary: PhotoLibraryService
    let contactService: ContactService

    private(set) var storage: StorageSnapshot?
    private(set) var authorizationStatus: PHAuthorizationStatus
    private(set) var screenshots: [ScreenshotItem] = []
    private(set) var largeVideos: [LargeVideoItem] = []
    private(set) var photoGroups: [PhotoGroup] = []
    private(set) var contactGroups: [ContactGroup] = []
    private(set) var scanPhase: ScanPhase = .idle
    private(set) var videoScanPhase: ScanPhase = .idle
    private(set) var photoScanPhase: ScanPhase = .idle
    private(set) var videoScanProgress = ScanProgress(completed: 0, total: 0)
    private(set) var photoScanProgress = ScanProgress(completed: 0, total: 0)
    private(set) var contactAccessState: ContactAccessState
    private(set) var contactScanPhase: ScanPhase = .idle
    private(set) var contactCleanupOutcome: ContactCleanupOutcome?
    private(set) var isChangingContacts = false
    private(set) var selectedIDs: Set<String> = []
    private(set) var measuredBytes: [String: Int64] = [:]
    private(set) var measuringIDs: Set<String> = []
    private(set) var sizeMeasurementAttemptedIDs: Set<String> = []
    private(set) var cleanupOutcome: CleanupOutcome?
    private(set) var isDeleting = false
    @ObservationIgnored private var videoScanTask: Task<Void, Never>?
    @ObservationIgnored private var photoScanTask: Task<Void, Never>?
    @ObservationIgnored private let photoAnalyzer = PhotoFeatureAnalyzer()

    init() {
        let storageService = StorageService()
        let photoLibrary = PhotoLibraryService()
        let contactService = ContactService()
        self.storageService = storageService
        self.photoLibrary = photoLibrary
        self.contactService = contactService
        authorizationStatus = photoLibrary.authorizationStatus
        contactAccessState = contactService.authorizationState
        refreshStorage()
    }

    var selectedScreenshots: [ScreenshotItem] {
        screenshots.filter { selectedIDs.contains($0.id) }
    }

    var selectedVideos: [LargeVideoItem] {
        largeVideos.filter { selectedIDs.contains($0.id) }
    }

    var selectedGroupedPhotos: [PhotoCandidate] {
        var seen: Set<String> = []
        return photoGroups
            .flatMap(\.members)
            .filter { selectedIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    var selectedScreenshotIDs: Set<String> {
        selectedIDs.intersection(screenshots.map(\.id))
    }

    var selectedVideoIDs: Set<String> {
        selectedIDs.intersection(largeVideos.map(\.id))
    }

    var selectedKnownBytes: Int64 {
        selectedIDs.reduce(into: 0) { total, identifier in
            total += measuredBytes[identifier] ?? 0
        }
    }

    var hasUnknownSelectedSizes: Bool {
        selectedIDs.contains { measuredBytes[$0] == nil }
    }

    var screenshotReclaimableEstimate: ReclaimableEstimate {
        reclaimableEstimate(for: Set(screenshots.map(\.id)))
    }

    var videoReclaimableEstimate: ReclaimableEstimate {
        reclaimableEstimate(for: Set(largeVideos.map(\.id)))
    }

    var similarPhotoReclaimableEstimate: ReclaimableEstimate {
        let identifiers = Set(photoGroups.flatMap(\.deletionCandidates).map(\.id))
        return reclaimableEstimate(for: identifiers)
    }

    var totalReclaimableEstimate: ReclaimableEstimate {
        let identifiers = Set(screenshots.map(\.id))
            .union(largeVideos.map(\.id))
            .union(photoGroups.flatMap(\.deletionCandidates).map(\.id))
        return reclaimableEstimate(for: identifiers)
    }

    func refreshAuthorization() {
        authorizationStatus = photoLibrary.authorizationStatus
        guard authorizationStatus != .authorized && authorizationStatus != .limited else {
            return
        }

        let inaccessibleIDs = Set(screenshots.map(\.id))
            .union(largeVideos.map(\.id))
            .union(photoGroups.flatMap(\.members).map(\.id))
        selectedIDs.subtract(inaccessibleIDs)
        screenshots = []
        largeVideos = []
        photoGroups = []
        scanPhase = .idle
        videoScanPhase = .idle
        photoScanPhase = .idle
        cancelVideoScan()
        cancelPhotoScan()
    }

    func refreshContactAuthorization() {
        contactAccessState = contactService.authorizationState
        if contactAccessState != .authorized && contactAccessState != .limited {
            contactGroups = []
            contactScanPhase = .idle
        }
    }

    func requestContactsAndScan() async {
        contactAccessState = await contactService.requestAuthorization()
        await scanContacts()
    }

    func scanContacts() async {
        refreshContactAuthorization()
        guard contactAccessState == .authorized || contactAccessState == .limited else {
            contactScanPhase = .idle
            return
        }

        contactScanPhase = .scanning
        await Task.yield()
        do {
            contactGroups = try contactService.fetchDuplicateGroups()
            contactScanPhase = .ready
        } catch {
            contactScanPhase = .failed("ClearNest couldn’t read the accessible contacts.")
        }
    }

    func mergeContactGroup(groupID: String, survivorID: String) async {
        guard let group = contactGroups.first(where: { $0.id == groupID }) else { return }
        isChangingContacts = true
        do {
            try contactService.merge(group: group, survivorID: survivorID)
            contactCleanupOutcome = .merged
            await scanContacts()
        } catch {
            contactCleanupOutcome = .failed(
                "The contacts couldn’t be merged. ClearNest left the source contacts unchanged."
            )
        }
        isChangingContacts = false
    }

    func deleteContact(contactID: String) async {
        isChangingContacts = true
        do {
            try contactService.delete(contactID: contactID)
            contactCleanupOutcome = .deleted
            await scanContacts()
        } catch {
            contactCleanupOutcome = .failed(
                "The contact couldn’t be deleted. It may belong to a read-only or managed account."
            )
        }
        isChangingContacts = false
    }

    func dismissContactOutcome() {
        contactCleanupOutcome = nil
    }

    func requestAccessAndScan() async {
        authorizationStatus = await photoLibrary.requestAuthorization()
        await scanScreenshots()
    }

    func scanScreenshots() async {
        refreshAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            scanPhase = .idle
            return
        }

        scanPhase = .scanning
        await Task.yield()
        let previousIDs = Set(screenshots.map(\.id))
        screenshots = photoLibrary.fetchScreenshots()
        let currentIDs = Set(screenshots.map(\.id))
        selectedIDs.subtract(previousIDs.subtracting(currentIDs))
        scanPhase = .ready
        await measureSizes(for: currentIDs)
    }

    func toggleSelection(for identifier: String) {
        if selectedIDs.remove(identifier) == nil {
            selectedIDs.insert(identifier)
            measureSizeIfNeeded(identifier: identifier)
        }
    }

    func selectAllScreenshots() {
        let screenshotIDs = Set(screenshots.map(\.id))
        selectedIDs.formUnion(screenshotIDs)
        for identifier in screenshotIDs {
            measureSizeIfNeeded(identifier: identifier)
        }
    }

    func clearScreenshotSelection() {
        selectedIDs.subtract(screenshots.map(\.id))
    }

    func startVideoScan() {
        cancelVideoScan()
        videoScanTask = Task { await scanLargeVideos() }
    }

    func cancelVideoScan() {
        videoScanTask?.cancel()
        videoScanTask = nil
        if videoScanPhase == .scanning {
            videoScanPhase = largeVideos.isEmpty ? .idle : .ready
        }
    }

    func startPhotoScan() {
        cancelPhotoScan()
        photoScanTask = Task { await scanPhotoGroups() }
    }

    func cancelPhotoScan() {
        photoScanTask?.cancel()
        photoScanTask = nil
        if photoScanPhase == .scanning {
            photoScanPhase = photoGroups.isEmpty ? .idle : .ready
        }
    }

    func selectSuggestedDeletions(in groupID: String) {
        guard let group = photoGroups.first(where: { $0.id == groupID }) else { return }
        selectedIDs.remove(group.keeperID)
        for candidate in group.deletionCandidates {
            selectedIDs.insert(candidate.id)
            measureSizeIfNeeded(identifier: candidate.id)
        }
    }

    func keepAll(in groupID: String) {
        guard let group = photoGroups.first(where: { $0.id == groupID }) else { return }
        selectedIDs.subtract(group.members.map(\.id))
    }

    func setKeeper(_ identifier: String, in groupID: String) {
        guard let index = photoGroups.firstIndex(where: { $0.id == groupID }),
              photoGroups[index].members.contains(where: { $0.id == identifier }) else { return }
        photoGroups[index].keeperID = identifier
        photoGroups[index].recommendation = .userChoice
        selectedIDs.remove(identifier)
    }

    func scanPhotoGroups() async {
        refreshAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            photoScanPhase = .idle
            return
        }

        photoScanPhase = .scanning
        photoGroups = []
        await photoAnalyzer.reset()
        let candidates = photoLibrary.fetchPhotoCandidates()
        photoScanProgress = ScanProgress(completed: 0, total: max(candidates.count * 2, 1))
        var completed = 0
        var groups: [PhotoGroup] = []
        var exactMemberIDs: Set<String> = []

        let dimensionBuckets = Dictionary(grouping: candidates) {
            "\($0.pixelWidth)x\($0.pixelHeight)"
        }

        for bucket in dimensionBuckets.values where bucket.count > 1 {
            var hashes: [String: [PhotoCandidate]] = [:]
            for candidate in bucket {
                guard !Task.isCancelled else {
                    photoScanPhase = groups.isEmpty ? .idle : .ready
                    return
                }
                if let hash = try? await photoLibrary.hashLocalPhoto(identifier: candidate.id) {
                    hashes[hash, default: []].append(candidate)
                }
                completed += 1
                photoScanProgress = ScanProgress(completed: completed, total: max(candidates.count * 2, 1))
            }

            for matches in hashes.values where matches.count > 1 {
                let recommendation = keeperRecommendation(for: matches)
                let sortedIDs = matches.map(\.id).sorted()
                groups.append(
                    PhotoGroup(
                        id: "exact-\(sortedIDs.joined(separator: "-"))",
                        kind: .exact,
                        members: matches,
                        keeperID: recommendation.candidate.id,
                        recommendation: recommendation.reason
                    )
                )
                exactMemberIDs.formUnion(matches.map(\.id))
            }
        }

        let similarityCandidates = candidates.filter { !exactMemberIDs.contains($0.id) }
        let timeBuckets = makeTimeBuckets(from: similarityCandidates)

        for bucket in timeBuckets where bucket.count > 1 {
            var available: [PhotoCandidate] = []
            for candidate in bucket {
                guard !Task.isCancelled else {
                    photoGroups = groups
                    photoScanPhase = groups.isEmpty ? .idle : .ready
                    return
                }
                if let data = try? await photoLibrary.requestAnalysisData(identifier: candidate.id),
                   (try? await photoAnalyzer.storeFeaturePrint(identifier: candidate.id, imageData: data)) != nil {
                    available.append(candidate)
                }
                completed += 1
                photoScanProgress = ScanProgress(
                    completed: min(completed, max(candidates.count * 2, 1)),
                    total: max(candidates.count * 2, 1)
                )
            }

            var remaining = available
            while let anchor = remaining.first {
                remaining.removeFirst()
                var matches = [anchor]
                var unmatched: [PhotoCandidate] = []
                for candidate in remaining {
                    let distance = try? await photoAnalyzer.distance(from: anchor.id, to: candidate.id)
                    if let distance, distance <= 0.18 {
                        matches.append(candidate)
                    } else {
                        unmatched.append(candidate)
                    }
                }
                remaining = unmatched
                guard matches.count > 1 else { continue }

                let recommendation = keeperRecommendation(for: matches)
                let sortedIDs = matches.map(\.id).sorted()
                groups.append(
                    PhotoGroup(
                        id: "similar-\(sortedIDs.joined(separator: "-"))",
                        kind: .similar,
                        members: matches,
                        keeperID: recommendation.candidate.id,
                        recommendation: recommendation.reason
                    )
                )
            }
        }

        photoGroups = groups.sorted {
            if $0.kind != $1.kind { return $0.kind == .exact }
            return $0.members.count > $1.members.count
        }
        let suggestedDeletionIDs = Set(photoGroups.flatMap(\.deletionCandidates).map(\.id))
        await measureSizes(for: suggestedDeletionIDs)
        photoScanProgress = ScanProgress(completed: max(candidates.count * 2, 1), total: max(candidates.count * 2, 1))
        photoScanPhase = .ready
        photoScanTask = nil
    }

    func scanLargeVideos() async {
        refreshAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            videoScanPhase = .idle
            return
        }

        let previousIDs = Set(largeVideos.map(\.id))
        let fetchedVideos = photoLibrary.fetchVideos()
        let currentIDs = Set(fetchedVideos.map(\.id))
        selectedIDs.subtract(previousIDs.subtracting(currentIDs))
        largeVideos = fetchedVideos
        videoScanPhase = .scanning
        videoScanProgress = ScanProgress(completed: 0, total: fetchedVideos.count)

        for (index, video) in fetchedVideos.enumerated() {
            guard !Task.isCancelled else {
                videoScanPhase = largeVideos.isEmpty ? .idle : .ready
                return
            }

            if measuredBytes[video.id] == nil,
               let bytes = try? await photoLibrary.measureLocalBytes(identifier: video.id) {
                measuredBytes[video.id] = bytes
            }
            sizeMeasurementAttemptedIDs.insert(video.id)
            videoScanProgress = ScanProgress(completed: index + 1, total: fetchedVideos.count)
            sortVideosByMeasuredSize()
        }

        videoScanPhase = .ready
        videoScanTask = nil
    }

    func deleteSelection() async {
        guard !selectedIDs.isEmpty else { return }
        isDeleting = true
        let identifiers = selectedIDs

        do {
            try await photoLibrary.deleteAssets(identifiers: identifiers)
            cleanupOutcome = .success(deletedCount: identifiers.count)
            selectedIDs.removeAll()
            for identifier in identifiers {
                measuredBytes.removeValue(forKey: identifier)
                sizeMeasurementAttemptedIDs.remove(identifier)
            }
            await scanScreenshots()
            largeVideos.removeAll { identifiers.contains($0.id) }
            photoGroups = photoGroups.compactMap { group in
                let remaining = group.members.filter { !identifiers.contains($0.id) }
                guard remaining.count > 1 else { return nil }
                var updated = group
                updated = PhotoGroup(
                    id: group.id,
                    kind: group.kind,
                    members: remaining,
                    keeperID: remaining.contains(where: { $0.id == group.keeperID })
                        ? group.keeperID
                        : remaining[0].id,
                    recommendation: group.recommendation
                )
                return updated
            }
            refreshStorage()
        } catch is CancellationError {
            cleanupOutcome = .cancelled
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.Code.userCancelled.rawValue {
                cleanupOutcome = .cancelled
            } else {
                cleanupOutcome = .failed(
                    "ClearNest couldn’t delete the selected media. Nothing else was changed."
                )
            }
        }
        isDeleting = false
    }

    func dismissOutcome() {
        cleanupOutcome = nil
    }

    private func measureSizeIfNeeded(identifier: String) {
        guard measuredBytes[identifier] == nil,
              !measuringIDs.contains(identifier) else { return }

        measuringIDs.insert(identifier)
        Task {
            defer {
                measuringIDs.remove(identifier)
                sizeMeasurementAttemptedIDs.insert(identifier)
            }
            if let bytes = try? await photoLibrary.measureLocalBytes(identifier: identifier) {
                measuredBytes[identifier] = bytes
            }
        }
    }

    private func measureSizes(for identifiers: Set<String>) async {
        for identifier in identifiers {
            guard !Task.isCancelled else { return }
            guard measuredBytes[identifier] == nil else {
                sizeMeasurementAttemptedIDs.insert(identifier)
                continue
            }

            measuringIDs.insert(identifier)
            sizeMeasurementAttemptedIDs.remove(identifier)
            if let bytes = try? await photoLibrary.measureLocalBytes(identifier: identifier) {
                measuredBytes[identifier] = bytes
            }
            measuringIDs.remove(identifier)
            sizeMeasurementAttemptedIDs.insert(identifier)
        }
    }

    private func reclaimableEstimate(for identifiers: Set<String>) -> ReclaimableEstimate {
        let knownBytes = identifiers.reduce(into: Int64(0)) { total, identifier in
            total += measuredBytes[identifier] ?? 0
        }
        let unknownSizeCount = identifiers.filter {
            sizeMeasurementAttemptedIDs.contains($0) && measuredBytes[$0] == nil
        }.count
        let unmeasuredCount = identifiers.filter {
            measuredBytes[$0] == nil && !sizeMeasurementAttemptedIDs.contains($0)
        }.count

        return ReclaimableEstimate(
            knownBytes: knownBytes,
            itemCount: identifiers.count,
            unknownSizeCount: unknownSizeCount,
            isCalculating: unmeasuredCount > 0 || !measuringIDs.isDisjoint(with: identifiers)
        )
    }

    private func refreshStorage() {
        storage = try? storageService.snapshot()
    }

    private func sortVideosByMeasuredSize() {
        largeVideos.sort { first, second in
            switch (measuredBytes[first.id], measuredBytes[second.id]) {
            case let (firstBytes?, secondBytes?):
                if firstBytes == secondBytes {
                    return first.duration > second.duration
                }
                return firstBytes > secondBytes
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return first.duration > second.duration
            }
        }
    }

    private func makeTimeBuckets(from candidates: [PhotoCandidate]) -> [[PhotoCandidate]] {
        var buckets: [[PhotoCandidate]] = []
        for candidate in candidates {
            guard let lastBucket = buckets.last,
                  let anchor = lastBucket.first,
                  let anchorDate = anchor.creationDate,
                  let candidateDate = candidate.creationDate,
                  abs(candidateDate.timeIntervalSince(anchorDate)) <= 10,
                  aspectRatioDifference(anchor, candidate) <= 0.03 else {
                buckets.append([candidate])
                continue
            }
            buckets[buckets.count - 1].append(candidate)
        }
        return buckets
    }

    private func aspectRatioDifference(_ first: PhotoCandidate, _ second: PhotoCandidate) -> Double {
        guard first.pixelHeight > 0, second.pixelHeight > 0 else { return 1 }
        let firstRatio = Double(first.pixelWidth) / Double(first.pixelHeight)
        let secondRatio = Double(second.pixelWidth) / Double(second.pixelHeight)
        return abs(firstRatio - secondRatio)
    }

    private func keeperRecommendation(
        for candidates: [PhotoCandidate]
    ) -> (candidate: PhotoCandidate, reason: KeeperReason) {
        if let favorite = candidates.first(where: \.isFavorite) {
            return (favorite, .favorite)
        }
        if let highestResolution = candidates.max(by: { $0.pixelCount < $1.pixelCount }),
           candidates.contains(where: { $0.pixelCount != highestResolution.pixelCount }) {
            return (highestResolution, .higherResolution)
        }
        let earliest = candidates.min {
            ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture)
        } ?? candidates[0]
        return (earliest, .earliestCapture)
    }
}
