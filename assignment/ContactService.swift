import Contacts
import Foundation

@MainActor
final class ContactService {
    private let store = CNContactStore()

    var authorizationState: ContactAccessState {
        mapAuthorization(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAuthorization() async -> ContactAccessState {
        do {
            _ = try await store.requestAccess(for: .contacts)
        } catch {
            return .denied
        }
        return authorizationState
    }

    func fetchDuplicateGroups() throws -> [ContactGroup] {
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.unifyResults = true
        var records: [ContactRecord] = []
        try store.enumerateContacts(with: request) { contact, _ in
            records.append(Self.record(from: contact))
        }
        return ContactMatcher.groups(from: records)
    }

    func merge(group: ContactGroup, survivorID: String) throws {
        let contacts = try group.members.map {
            try store.unifiedContact(withIdentifier: $0.id, keysToFetch: Self.keysToFetch)
        }
        guard let survivor = contacts.first(where: { $0.identifier == survivorID }),
              let mutableSurvivor = survivor.mutableCopy() as? CNMutableContact else {
            throw CNError(.recordDoesNotExist)
        }

        let sources = contacts.filter { $0.identifier != survivorID }
        mergeNames(from: sources, into: mutableSurvivor)
        mergePhoneNumbers(from: sources, into: mutableSurvivor)
        mergeEmailAddresses(from: sources, into: mutableSurvivor)

        let saveRequest = CNSaveRequest()
        saveRequest.transactionAuthor = "ClearNest"
        saveRequest.update(mutableSurvivor)
        for source in sources {
            guard let mutableSource = source.mutableCopy() as? CNMutableContact else { continue }
            saveRequest.delete(mutableSource)
        }
        try store.execute(saveRequest)
    }

    func delete(contactID: String) throws {
        let contact = try store.unifiedContact(
            withIdentifier: contactID,
            keysToFetch: Self.keysToFetch
        )
        guard let mutableContact = contact.mutableCopy() as? CNMutableContact else {
            throw CNError(.recordDoesNotExist)
        }
        let request = CNSaveRequest()
        request.transactionAuthor = "ClearNest"
        request.delete(mutableContact)
        try store.execute(request)
    }

    private func mapAuthorization(_ status: CNAuthorizationStatus) -> ContactAccessState {
        if status == .notDetermined { return .notDetermined }
        if status == .restricted { return .restricted }
        if status == .denied { return .denied }
        if status == .authorized { return .authorized }
        if #available(iOS 18.0, *), status == .limited { return .limited }
        return .restricted
    }

    private func mergeNames(from sources: [CNContact], into survivor: CNMutableContact) {
        if survivor.givenName.isEmpty {
            survivor.givenName = sources.first(where: { !$0.givenName.isEmpty })?.givenName ?? ""
        }
        if survivor.familyName.isEmpty {
            survivor.familyName = sources.first(where: { !$0.familyName.isEmpty })?.familyName ?? ""
        }
        if survivor.organizationName.isEmpty {
            survivor.organizationName = sources.first(where: { !$0.organizationName.isEmpty })?.organizationName ?? ""
        }
    }

    private func mergePhoneNumbers(from sources: [CNContact], into survivor: CNMutableContact) {
        var known = Set(survivor.phoneNumbers.map {
            ContactMatcher.normalizedPhone($0.value.stringValue)
        })
        var merged = survivor.phoneNumbers
        for value in sources.flatMap(\.phoneNumbers) {
            let normalized = ContactMatcher.normalizedPhone(value.value.stringValue)
            if !normalized.isEmpty, known.insert(normalized).inserted {
                merged.append(value)
            }
        }
        survivor.phoneNumbers = merged
    }

    private func mergeEmailAddresses(from sources: [CNContact], into survivor: CNMutableContact) {
        var known = Set(survivor.emailAddresses.map {
            ContactMatcher.normalizedEmail(String($0.value))
        })
        var merged = survivor.emailAddresses
        for value in sources.flatMap(\.emailAddresses) {
            let normalized = ContactMatcher.normalizedEmail(String(value.value))
            if !normalized.isEmpty, known.insert(normalized).inserted {
                merged.append(value)
            }
        }
        survivor.emailAddresses = merged
    }

    private static func record(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            id: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
            emailAddresses: contact.emailAddresses.map { String($0.value) }
        )
    }

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor
    ]
}

struct ContactMatcher {
    static func groups(from contacts: [ContactRecord]) -> [ContactGroup] {
        var parent = Array(contacts.indices)

        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        func union(_ first: Int, _ second: Int) {
            let firstRoot = root(first)
            let secondRoot = root(second)
            if firstRoot != secondRoot {
                parent[secondRoot] = firstRoot
            }
        }

        var phoneOwners: [String: Int] = [:]
        var emailOwners: [String: Int] = [:]
        var nameOrganizationOwners: [String: Int] = [:]

        for (index, contact) in contacts.enumerated() {
            for phone in contact.phoneNumbers.map({ normalizedPhone($0) }).filter({ !$0.isEmpty }) {
                if let owner = phoneOwners[phone] { union(index, owner) }
                phoneOwners[phone] = index
            }
            for email in contact.emailAddresses.map({ normalizedEmail($0) }).filter({ !$0.isEmpty }) {
                if let owner = emailOwners[email] { union(index, owner) }
                emailOwners[email] = index
            }

            let name = normalizedName(contact.displayName)
            let organization = normalizedName(contact.organizationName)
            if !name.isEmpty, !organization.isEmpty {
                let key = "\(name)|\(organization)"
                if let owner = nameOrganizationOwners[key] { union(index, owner) }
                nameOrganizationOwners[key] = index
            }
        }

        var components: [Int: [ContactRecord]] = [:]
        for index in contacts.indices {
            components[root(index), default: []].append(contacts[index])
        }

        return components.values
            .filter { $0.count > 1 }
            .map { makeGroup($0) }
            .sorted { first, second in
                if first.confidence != second.confidence {
                    return first.confidence == .strong
                }
                return first.members[0].displayName.localizedCaseInsensitiveCompare(
                    second.members[0].displayName
                ) == .orderedAscending
            }
    }

    static func normalizedPhone(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        return digits.hasPrefix("00") ? String(digits.dropFirst(2)) : digits
    }

    static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func makeGroup(_ members: [ContactRecord]) -> ContactGroup {
        let reason = matchReason(for: members)
        let confidence: ContactMatchConfidence =
            reason == .matchingNameAndOrganization ? .possible : .strong
        let ids = members.map(\.id).sorted()
        return ContactGroup(
            id: ids.joined(separator: "-"),
            confidence: confidence,
            reason: reason,
            members: members,
            mergedPreview: mergedPreview(from: members)
        )
    }

    private static func matchReason(for members: [ContactRecord]) -> ContactMatchReason {
        var phones: Set<String> = []
        for phone in members.flatMap(\.phoneNumbers).map({ normalizedPhone($0) }) where !phone.isEmpty {
            if !phones.insert(phone).inserted { return .sharedPhone }
        }
        var emails: Set<String> = []
        for email in members.flatMap(\.emailAddresses).map({ normalizedEmail($0) }) where !email.isEmpty {
            if !emails.insert(email).inserted { return .sharedEmail }
        }
        return .matchingNameAndOrganization
    }

    private static func mergedPreview(from members: [ContactRecord]) -> ContactRecord {
        let first = members[0]
        return ContactRecord(
            id: first.id,
            givenName: first.givenName.isEmpty
                ? members.first(where: { !$0.givenName.isEmpty })?.givenName ?? ""
                : first.givenName,
            familyName: first.familyName.isEmpty
                ? members.first(where: { !$0.familyName.isEmpty })?.familyName ?? ""
                : first.familyName,
            organizationName: first.organizationName.isEmpty
                ? members.first(where: { !$0.organizationName.isEmpty })?.organizationName ?? ""
                : first.organizationName,
            phoneNumbers: unique(members.flatMap(\.phoneNumbers), normalizer: { normalizedPhone($0) }),
            emailAddresses: unique(members.flatMap(\.emailAddresses), normalizer: { normalizedEmail($0) })
        )
    }

    private static func unique(
        _ values: [String],
        normalizer: (String) -> String
    ) -> [String] {
        var seen: Set<String> = []
        return values.filter {
            let normalized = normalizer($0)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }
}
