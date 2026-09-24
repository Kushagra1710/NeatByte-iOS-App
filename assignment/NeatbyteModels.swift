import Foundation

struct StorageSnapshot: Equatable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct ReclaimableEstimate: Equatable {
    let knownBytes: Int64
    let itemCount: Int
    let unknownSizeCount: Int
    let isCalculating: Bool

    var isPartial: Bool {
        unknownSizeCount > 0
    }

    func accessibilityDescription(scanPhase: ScanPhase) -> LocalizedStringResource {
        if scanPhase == .scanning || isCalculating {
            return "Calculating potential savings"
        }
        if itemCount == 0 {
            return scanPhase == .idle ? "Scan to estimate savings" : "No reclaimable items found"
        }
        if knownBytes > 0 {
            let formattedBytes = knownBytes.formatted(.byteCount(style: .file))
            return isPartial
                ? "At least \(formattedBytes) reclaimable"
                : "\(formattedBytes) potentially reclaimable"
        }
        if isPartial {
            return "Storage size unavailable for accessible items"
        }
        return "No local storage estimate available"
    }
}

struct ScreenshotItem: Identifiable, Equatable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
}

struct LargeVideoItem: Identifiable, Equatable {
    let id: String
    let creationDate: Date?
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
}

struct PhotoCandidate: Identifiable, Equatable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool

    var pixelCount: Int {
        pixelWidth * pixelHeight
    }
}

enum PhotoGroupKind: String, Equatable {
    case exact
    case similar

    var title: LocalizedStringResource {
        switch self {
        case .exact: "Exact duplicates"
        case .similar: "Visually similar"
        }
    }
}

enum KeeperReason: Equatable {
    case favorite
    case higherResolution
    case earliestCapture
    case userChoice

    var message: LocalizedStringResource {
        switch self {
        case .favorite: "Suggested because it’s already a favorite."
        case .higherResolution: "Suggested because it has the highest resolution."
        case .earliestCapture: "Suggested as the earliest original in this group."
        case .userChoice: "You chose this photo to keep."
        }
    }
}

struct PhotoGroup: Identifiable, Equatable {
    let id: String
    let kind: PhotoGroupKind
    let members: [PhotoCandidate]
    var keeperID: String
    var recommendation: KeeperReason

    var deletionCandidates: [PhotoCandidate] {
        members.filter { $0.id != keeperID }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning
    case ready
    case failed(LocalizedStringResource)
}

struct ScanProgress: Equatable {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

enum ContactAccessState: Equatable {
    case notDetermined
    case restricted
    case denied
    case limited
    case authorized
}

struct ContactRecord: Identifiable, Equatable {
    let id: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]

    var displayName: String {
        let personName = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        return phoneNumbers.first ?? emailAddresses.first ?? String(localized: "Unnamed contact")
    }
}

enum ContactMatchConfidence: Equatable {
    case strong
    case possible

    var title: LocalizedStringResource {
        switch self {
        case .strong: "Strong match"
        case .possible: "Possible match"
        }
    }
}

struct ContactGroup: Identifiable, Equatable {
    let id: String
    let confidence: ContactMatchConfidence
    let reason: ContactMatchReason
    let members: [ContactRecord]
    let mergedPreview: ContactRecord
}

enum ContactMatchReason: Equatable {
    case sharedPhone
    case sharedEmail
    case matchingNameAndOrganization

    var message: LocalizedStringResource {
        switch self {
        case .sharedPhone: "These contacts share a phone number."
        case .sharedEmail: "These contacts share an email address."
        case .matchingNameAndOrganization: "These contacts share the same name and organization."
        }
    }
}

enum ContactCleanupOutcome: Equatable {
    case merged
    case deleted
    case failed(LocalizedStringResource)
}

enum CleanupOutcome: Equatable {
    case success(deletedCount: Int)
    case cancelled
    case failed(LocalizedStringResource)
}
