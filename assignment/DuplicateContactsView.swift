import SwiftUI
import UIKit

struct DuplicateContactsCategoryCard: View {
    let model: ClearNestModel

    var body: some View {
        NavigationLink {
            DuplicateContactsView(model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.teal.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Contacts")
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Storage estimate not applicable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Duplicate Contacts")
            .accessibilityValue(Text(subtitle))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: LocalizedStringResource {
        switch model.contactAccessState {
        case .notDetermined:
            "Ready to scan"
        case .denied:
            "Contacts access denied"
        case .restricted:
            "Contacts access restricted"
        case .limited:
            "\(model.contactGroups.count) groups in limited access"
        case .authorized:
            model.contactScanPhase == .ready
                ? "\(model.contactGroups.count) groups found"
                : "Ready to scan"
        }
    }
}

struct DuplicateContactsView: View {
    let model: ClearNestModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContactAccessContent(model: model, openSettings: openSettings)
            .navigationTitle("Duplicate Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.contactAccessState == .authorized || model.contactAccessState == .limited {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Rescan") {
                            Task { await model.scanContacts() }
                        }
                    }
                }
            }
            .task {
                model.refreshContactAuthorization()
                if model.contactAccessState == .authorized || model.contactAccessState == .limited {
                    await model.scanContacts()
                }
            }
            .alert(
                contactOutcomeTitle,
                isPresented: Binding(
                    get: { model.contactCleanupOutcome != nil },
                    set: { if !$0 { model.dismissContactOutcome() } }
                )
            ) {
                Button("OK") { model.dismissContactOutcome() }
            } message: {
                Text(contactOutcomeMessage)
            }
    }

    private var contactOutcomeTitle: LocalizedStringKey {
        switch model.contactCleanupOutcome {
        case .merged: "Contacts merged"
        case .deleted: "Contact deleted"
        case .failed: "Contacts unchanged"
        case nil: "Contacts"
        }
    }

    private var contactOutcomeMessage: LocalizedStringResource {
        switch model.contactCleanupOutcome {
        case .merged:
            "The approved fields were saved to the chosen contact and the other records were deleted."
        case .deleted:
            "The selected contact was deleted."
        case .failed(let message):
            message
        case nil:
            ""
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

struct ContactAccessContent: View {
    let model: ClearNestModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.contactAccessState {
            case .notDetermined:
                ContactsPermissionView(model: model)
            case .denied:
                ContactsUnavailableView(
                    title: "Contacts access denied",
                    message: "Allow Contacts access in Settings to look for possible duplicates.",
                    openSettings: openSettings
                )
            case .restricted:
                ContactsUnavailableView(
                    title: "Contacts access restricted",
                    message: "A device restriction prevents ClearNest from accessing contacts.",
                    openSettings: nil
                )
            case .limited, .authorized:
                ContactResultsView(model: model)
            }
        }
    }
}

struct ContactsPermissionView: View {
    let model: ClearNestModel

    var body: some View {
        ContentUnavailableView {
            Label("Find duplicate contacts", systemImage: "person.2.badge.gearshape")
        } description: {
            Text("ClearNest compares names, phone numbers, and email addresses on this iPhone. No contact changes happen without a separate review and confirmation.")
        } actions: {
            Button("Continue") {
                Task { await model.requestContactsAndScan() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
        }
    }
}

struct ContactsUnavailableView: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let openSettings: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let openSettings {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ContactResultsView: View {
    let model: ClearNestModel

    var body: some View {
        VStack(spacing: 0) {
            if model.contactAccessState == .limited {
                Label("Results include only contacts you allowed. Manage access in Settings.", systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.yellow.opacity(0.12))
            }

            switch model.contactScanPhase {
            case .idle, .scanning:
                ProgressView("Comparing contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Contact scan failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready:
                if model.contactGroups.isEmpty {
                    ContentUnavailableView(
                        "No duplicate contacts found",
                        systemImage: "person.2",
                        description: Text("ClearNest found no strong or carefully qualified possible matches.")
                    )
                } else {
                    List(model.contactGroups) { group in
                        ContactGroupRow(group: group, model: model)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

struct ContactGroupRow: View {
    let group: ContactGroup
    let model: ClearNestModel

    var body: some View {
        NavigationLink {
            ContactMergeReviewView(group: group, model: model)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(group.confidence == .strong ? .teal : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.members[0].displayName)
                        .font(.headline)
                    Text("\(group.members.count) contact records")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(group.confidence.title)
                        .font(.caption.bold())
                        .foregroundStyle(group.confidence == .strong ? .teal : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ContactMergeReviewView: View {
    let group: ContactGroup
    let model: ClearNestModel

    @State private var survivorID: String
    @State private var showsMergeConfirmation = false
    @State private var contactPendingDeletion: ContactRecord?
    @Environment(\.dismiss) private var dismiss

    init(group: ContactGroup, model: ClearNestModel) {
        self.group = group
        self.model = model
        _survivorID = State(initialValue: group.members[0].id)
    }

    var body: some View {
        List {
            ContactMatchExplanationSection(
                confidence: group.confidence,
                reason: group.reason
            )
            ContactSourcesSection(
                members: group.members,
                survivorID: $survivorID,
                delete: { contactPendingDeletion = $0 }
            )
            ContactMergedPreviewSection(contact: mergedPreview)
            ContactSafetySection()
        }
        .navigationTitle("Review Contact Merge")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Review and merge \(group.members.count) contacts") {
                showsMergeConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(model.isChangingContacts)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .confirmationDialog(
            "Merge these contacts?",
            isPresented: $showsMergeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Merge and delete other records", role: .destructive) {
                Task {
                    await model.mergeContactGroup(
                        groupID: group.id,
                        survivorID: survivorID
                    )
                    if model.contactCleanupOutcome == .merged {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The previewed fields will be saved to the chosen contact. The other contact records will then be deleted in the same Contacts transaction.")
        }
        .alert(
            "Delete this contact?",
            isPresented: Binding(
                get: { contactPendingDeletion != nil },
                set: { if !$0 { contactPendingDeletion = nil } }
            ),
            presenting: contactPendingDeletion
        ) { contact in
            Button("Delete \(contact.displayName)", role: .destructive) {
                Task {
                    await model.deleteContact(contactID: contact.id)
                    if model.contactCleanupOutcome == .deleted {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { contact in
            Text("This deletes only \(contact.displayName). Contacts does not provide the same Recently Deleted protection as Photos.")
        }
    }

    private var mergedPreview: ContactRecord {
        guard let survivor = group.members.first(where: { $0.id == survivorID }) else {
            return group.mergedPreview
        }
        return ContactRecord(
            id: survivor.id,
            givenName: survivor.givenName.isEmpty ? group.mergedPreview.givenName : survivor.givenName,
            familyName: survivor.familyName.isEmpty ? group.mergedPreview.familyName : survivor.familyName,
            organizationName: survivor.organizationName.isEmpty
                ? group.mergedPreview.organizationName
                : survivor.organizationName,
            phoneNumbers: group.mergedPreview.phoneNumbers,
            emailAddresses: group.mergedPreview.emailAddresses
        )
    }
}

struct ContactMatchExplanationSection: View {
    let confidence: ContactMatchConfidence
    let reason: ContactMatchReason

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(confidence.title)
                        .font(.headline)
                    Text(reason.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: confidence == .strong ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(confidence == .strong ? .teal : .orange)
            }
        }
    }
}

struct ContactSourcesSection: View {
    let members: [ContactRecord]
    @Binding var survivorID: String
    let delete: (ContactRecord) -> Void

    var body: some View {
        Section("Source contacts") {
            ForEach(members) { contact in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        survivorID = contact.id
                    } label: {
                        HStack {
                            Image(systemName: survivorID == contact.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.teal)
                            Text(contact.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if survivorID == contact.id {
                                Text("Survivor")
                                    .font(.caption.bold())
                                    .foregroundStyle(.teal)
                            }
                        }
                    }

                    ContactValuesView(
                        phoneNumbers: contact.phoneNumbers,
                        emailAddresses: contact.emailAddresses
                    )

                    if survivorID != contact.id {
                        Button("Delete only this record", role: .destructive) {
                            delete(contact)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct ContactMergedPreviewSection: View {
    let contact: ContactRecord

    var body: some View {
        Section("Result after merge") {
            Text(contact.displayName)
                .font(.headline)
            if !contact.organizationName.isEmpty {
                LabeledContent("Organization", value: contact.organizationName)
            }
            ContactValuesView(
                phoneNumbers: contact.phoneNumbers,
                emailAddresses: contact.emailAddresses
            )
        }
    }
}

struct ContactValuesView: View {
    let phoneNumbers: [String]
    let emailAddresses: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(phoneNumbers, id: \.self) { phone in
                Label(phone, systemImage: "phone")
            }
            ForEach(emailAddresses, id: \.self) { email in
                Label(email, systemImage: "envelope")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

struct ContactSafetySection: View {
    var body: some View {
        Section("Important") {
            Label("No changes occur until you confirm.", systemImage: "checkmark.shield")
            Label("Managed or read-only contacts may reject the whole transaction.", systemImage: "lock")
            Label("Unlike Photos, contact deletion may not have a Recently Deleted recovery step.", systemImage: "exclamationmark.triangle")
        }
    }
}
