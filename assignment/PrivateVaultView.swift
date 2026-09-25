import PhotosUI
import SwiftUI

struct PrivateVaultCategoryCard: View {
    var body: some View {
        NavigationLink {
            PrivateVaultView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Private Vault")
                        .font(.headline)
                    Text("Encrypted photos protected by Face ID or PIN")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }
}

struct PrivateVaultView: View {
    @State private var model = PrivateVaultModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .navigationTitle("Private Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.lockState == .unlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Lock", systemImage: "lock.fill") {
                            model.lock()
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active, model.lockState == .unlocked {
                    model.lock()
                }
            }
            .alert(
                "Private Vault",
                isPresented: Binding(
                    get: {
                        model.errorMessage != nil || model.successMessage != nil
                    },
                    set: { isPresented in
                        if !isPresented { model.clearMessage() }
                    }
                )
            ) {
                Button("OK") {
                    model.clearMessage()
                }
            } message: {
                Text(model.errorMessage ?? model.successMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.lockState {
        case .setupRequired:
            VaultSetupView(
                isBusy: model.isBusy,
                configure: model.configure
            )
        case .locked:
            VaultUnlockView(
                biometricName: model.biometricName,
                isBusy: model.isBusy,
                remainingLockoutSeconds: model.remainingLockoutSeconds,
                unlockWithPIN: model.unlockWithPIN,
                unlockWithDeviceAuthentication: model.unlockWithDeviceAuthentication
            )
        case .unlocked:
            VaultUnlockedView(model: model)
        }
    }
}

struct VaultSetupView: View {
    let isBusy: Bool
    let configure: (String, String) -> Void

    @State private var pin = ""
    @State private var confirmation = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VaultSecurityHeader(
                    symbol: "lock.shield.fill",
                    title: "Create your private vault",
                    message: "Choose a 6-digit PIN. Your photos will be encrypted on this iPhone and excluded from device backups."
                )

                VStack(spacing: 14) {
                    SecureField("6-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                    SecureField("Confirm PIN", text: $confirmation)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                }
                .textFieldStyle(.roundedBorder)
                .onChange(of: pin) { _, value in
                    pin = sanitizedPIN(value)
                }
                .onChange(of: confirmation) { _, value in
                    confirmation = sanitizedPIN(value)
                }

                Button("Create encrypted vault") {
                    configure(pin, confirmation)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
                .disabled(isBusy || pin.count != 6 || confirmation.count != 6)

                VaultSafetyNotice()
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func sanitizedPIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(6))
    }
}

struct VaultUnlockView: View {
    let biometricName: String
    let isBusy: Bool
    let remainingLockoutSeconds: Int?
    let unlockWithPIN: (String) -> Void
    let unlockWithDeviceAuthentication: () async -> Void

    @State private var pin = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VaultSecurityHeader(
                symbol: "lock.fill",
                title: "Vault locked",
                message: "Authenticate to decrypt and view your private photos."
            )

            Button {
                Task { await unlockWithDeviceAuthentication() }
            } label: {
                Label("Unlock with \(biometricName)", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
            .disabled(isBusy)

            HStack {
                Divider()
                Text("or use your PIN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
            }

            SecureField("6-digit PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(6))
                }
                .onSubmit(submitPIN)

            if let remainingLockoutSeconds {
                Text("Try again in \(remainingLockoutSeconds) seconds")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("Unlock with PIN", action: submitPIN)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy || pin.count != 6 || remainingLockoutSeconds != nil)

            Spacer()
            VaultSafetyNotice()
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private func submitPIN() {
        unlockWithPIN(pin)
        pin = ""
    }
}

struct VaultSecurityHeader: View {
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct VaultSafetyNotice: View {
    var body: some View {
        Label(
            "Importing never deletes the original from Photos. Export a copy before deleting anything from the vault.",
            systemImage: "checkmark.shield.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding()
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct VaultUnlockedView: View {
    let model: PrivateVaultModel

    @State private var photoSelections: [PhotosPickerItem] = []

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VaultStatusHeader(
                itemCount: model.items.count,
                protectedBytes: model.totalProtectedBytes
            )

            if model.items.isEmpty {
                VaultEmptyView(selection: $photoSelections)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.items) { item in
                            NavigationLink {
                                VaultItemDetailView(item: item, model: model)
                            } label: {
                                VaultItemTile(item: item, model: model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom) {
                    VaultImportBar(selection: $photoSelections)
                }
            }

            if model.isBusy {
                VaultProgressOverlay(
                    completed: model.importCompleted,
                    total: model.importTotal
                )
            }
        }
        .onChange(of: photoSelections) { _, selections in
            guard !selections.isEmpty else { return }
            Task {
                await model.importPhotos(selections)
                photoSelections = []
            }
        }
    }
}

struct VaultStatusHeader: View {
    let itemCount: Int
    let protectedBytes: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vault unlocked")
                    .font(.headline)
                Text("\(itemCount) protected • \(protectedBytes, format: .byteCount(style: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.green.opacity(0.08))
    }
}

struct VaultEmptyView: View {
    @Binding var selection: [PhotosPickerItem]

    var body: some View {
        ContentUnavailableView {
            Label("Your vault is empty", systemImage: "lock.shield")
        } description: {
            Text("Choose photos to encrypt inside Neatbyte. Originals stay in Photos until you delete them yourself.")
        } actions: {
            PhotosPicker(
                selection: $selection,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label("Choose Photos", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }
}

struct VaultImportBar: View {
    @Binding var selection: [PhotosPickerItem]

    var body: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: 20,
            matching: .images
        ) {
            Label("Add encrypted photos", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .foregroundStyle(.white)
                .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal)
                .padding(.top, 8)
        }
        .buttonStyle(.plain)
        .background(.bar)
    }
}

struct VaultItemTile: View {
    let item: VaultItem
    let model: PrivateVaultModel

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.secondary.opacity(0.12)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(item.importedAt, format: .dateTime.day().month().year())
                .font(.caption.bold())
            Text(Int64(item.originalByteCount), format: .byteCount(style: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: item.id) {
            image = model.image(for: item)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Encrypted photo")
        .accessibilityValue(
            "\(Int64(item.originalByteCount).formatted(.byteCount(style: .file))), imported \(item.importedAt.formatted(date: .abbreviated, time: .omitted))"
        )
    }
}

struct VaultItemDetailView: View {
    let item: VaultItem
    let model: PrivateVaultModel

    @State private var image: UIImage?
    @State private var showsDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Color.secondary.opacity(0.1)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 4) {
                Text(item.importedAt, format: .dateTime.day().month().year().hour().minute())
                Text(Int64(item.originalByteCount), format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            HStack {
                Button {
                    Task { await model.exportToPhotos(item) }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .disabled(model.isBusy)
        }
        .padding()
        .navigationTitle("Encrypted Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) {
            image = model.image(for: item)
        }
        .confirmationDialog(
            "Delete encrypted copy?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from vault", role: .destructive) {
                model.delete(item)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the encrypted vault copy. Confirm that the photo exists elsewhere if you need it.")
        }
    }
}

struct VaultProgressOverlay: View {
    let completed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(total > 0 ? "Encrypting \(completed) of \(total)…" : "Working securely…")
                .font(.footnote.bold())
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
        .accessibilityElement(children: .combine)
    }
}
