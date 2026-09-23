//
//  ClearNestVerifiedTests.swift
//  ClearNestVerifiedTests
//
//  Created by KUSHAGRA SHARMA on 23/09/26.
//

import Testing
@testable import ClearNest

struct ClearNestVerifiedTests {
    @Test
    func storageSnapshotCalculatesUsedCapacity() {
        let snapshot = StorageSnapshot(totalBytes: 1_000, availableBytes: 250)

        #expect(snapshot.usedBytes == 750)
        #expect(snapshot.usedFraction == 0.75)
    }

    @Test
    func storageSnapshotNeverReportsNegativeUsage() {
        let snapshot = StorageSnapshot(totalBytes: 1_000, availableBytes: 1_200)

        #expect(snapshot.usedBytes == 0)
        #expect(snapshot.usedFraction == 0)
    }

    @Test
    func screenshotIdentityUsesPhotoLibraryIdentifier() {
        let first = ScreenshotItem(
            id: "asset-1",
            creationDate: nil,
            pixelWidth: 1_170,
            pixelHeight: 2_532
        )
        let second = ScreenshotItem(
            id: "asset-1",
            creationDate: nil,
            pixelWidth: 1_170,
            pixelHeight: 2_532
        )

        #expect(first == second)
        #expect(first.id == second.id)
    }

    @Test
    func videoIdentityUsesPhotoLibraryIdentifier() {
        let video = LargeVideoItem(
            id: "video-1",
            creationDate: nil,
            duration: 42,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )

        #expect(video.id == "video-1")
        #expect(video.duration == 42)
    }

    @Test
    func photoGroupExcludesKeeperFromDeletionCandidates() {
        let keeper = PhotoCandidate(
            id: "keeper",
            creationDate: nil,
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            isFavorite: true
        )
        let duplicate = PhotoCandidate(
            id: "duplicate",
            creationDate: nil,
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            isFavorite: false
        )
        let group = PhotoGroup(
            id: "exact-test",
            kind: .exact,
            members: [keeper, duplicate],
            keeperID: keeper.id,
            recommendation: .favorite
        )

        #expect(group.deletionCandidates.map(\.id) == ["duplicate"])
    }

    @Test
    func exactAndSimilarClassificationsRemainDistinct() {
        #expect(PhotoGroupKind.exact != PhotoGroupKind.similar)
        #expect(PhotoGroupKind.exact.rawValue != PhotoGroupKind.similar.rawValue)
    }

    @Test
    func contactsWithSharedNormalizedPhoneAreStrongMatches() {
        let first = ContactRecord(
            id: "one",
            givenName: "Asha",
            familyName: "Sharma",
            organizationName: "",
            phoneNumbers: ["+91 98765 43210"],
            emailAddresses: []
        )
        let second = ContactRecord(
            id: "two",
            givenName: "Asha",
            familyName: "S.",
            organizationName: "",
            phoneNumbers: ["+91-98765-43210"],
            emailAddresses: []
        )

        let groups = ContactMatcher.groups(from: [first, second])

        #expect(groups.count == 1)
        #expect(groups[0].confidence == .strong)
        #expect(groups[0].reason == .sharedPhone)
    }

    @Test
    func matchingNameAloneDoesNotCreateDuplicateGroup() {
        let first = ContactRecord(
            id: "one",
            givenName: "Alex",
            familyName: "Kim",
            organizationName: "",
            phoneNumbers: ["111"],
            emailAddresses: []
        )
        let second = ContactRecord(
            id: "two",
            givenName: "Alex",
            familyName: "Kim",
            organizationName: "",
            phoneNumbers: ["222"],
            emailAddresses: []
        )

        #expect(ContactMatcher.groups(from: [first, second]).isEmpty)
    }

    @Test
    func emailNormalizationIsCaseAndWhitespaceInsensitive() {
        #expect(
            ContactMatcher.normalizedEmail("  Person@Example.COM ") ==
                ContactMatcher.normalizedEmail("person@example.com")
        )
    }
}
