import CryptoKit
import Foundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum VaultLockState: Equatable {
    case setupRequired
    case locked
    case unlocked
}

struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let importedAt: Date
    let originalByteCount: Int
    let contentType: String
}

private struct VaultEnvelope: Codable, Sendable {
    let item: VaultItem
    let encryptedData: Data
}

@MainActor
@Observable
final class PrivateVaultModel {
    private(set) var lockState: VaultLockState
    private(set) var items: [VaultItem] = []
    private(set) var isBusy = false
    private(set) var importCompleted = 0
    private(set) var importTotal = 0
    private(set) var failedPINAttempts = 0
    private(set) var lockoutUntil: Date?
    var errorMessage: String?
    var successMessage: String?

    let security: VaultSecurity

    private var encryptionKey: SymmetricKey?
    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let security = VaultSecurity()
        self.security = security
        lockState = security.isConfigured ? .locked : .setupRequired

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        directoryURL = applicationSupport.appendingPathComponent(
            "PrivateVault",
            isDirectory: true
        )
        encoder.outputFormatting = [.sortedKeys]
    }

    var biometricName: String {
        security.biometricName
    }

    var totalProtectedBytes: Int64 {
        items.reduce(0) { $0 + Int64($1.originalByteCount) }
    }

    var remainingLockoutSeconds: Int? {
        guard let lockoutUntil else { return nil }
        let remaining = Int(ceil(lockoutUntil.timeIntervalSinceNow))
        return remaining > 0 ? remaining : nil
    }

    func configure(pin: String, confirmation: String) {
        guard isValidPIN(pin) else {
            errorMessage = "Choose a 6-digit PIN."
            return
        }
        guard pin == confirmation else {
            errorMessage = "The PINs do not match."
            return
        }

        do {
            encryptionKey = try security.configure(pin: pin)
            try prepareDirectory()
            failedPINAttempts = 0
            lockoutUntil = nil
            lockState = .unlocked
            loadItems()
        } catch {
            show(error)
        }
    }

    func unlockWithPIN(_ pin: String) {
        if let remainingLockoutSeconds {
            errorMessage = "Try again in \(remainingLockoutSeconds) seconds."
            return
        }
        guard isValidPIN(pin) else {
            errorMessage = "Enter your 6-digit PIN."
            return
        }

        do {
            encryptionKey = try security.verify(pin: pin)
            failedPINAttempts = 0
            lockoutUntil = nil
            lockState = .unlocked
            loadItems()
        } catch VaultSecurityError.invalidPIN {
            failedPINAttempts += 1
            if failedPINAttempts >= 5 {
                lockoutUntil = Date().addingTimeInterval(30)
                failedPINAttempts = 0
                errorMessage = "Too many attempts. Try again in 30 seconds."
            } else {
                errorMessage = "Incorrect PIN. \(5 - failedPINAttempts) attempts remaining."
            }
        } catch {
            show(error)
        }
    }

    func unlockWithDeviceAuthentication() async {
        isBusy = true
        defer { isBusy = false }

        do {
            encryptionKey = try await security.authenticateDevice()
            failedPINAttempts = 0
            lockoutUntil = nil
            lockState = .unlocked
            loadItems()
        } catch VaultSecurityError.authenticationFailed {
            // Cancellation is not an app error and needs no additional alert.
        } catch {
            show(error)
        }
    }

    func lock() {
        encryptionKey = nil
        items = []
        errorMessage = nil
        successMessage = nil
        lockState = security.isConfigured ? .locked : .setupRequired
    }

    func importPhotos(_ selections: [PhotosPickerItem]) async {
        guard let encryptionKey, !selections.isEmpty else { return }

        isBusy = true
        importCompleted = 0
        importTotal = selections.count
        defer {
            isBusy = false
            importCompleted = 0
            importTotal = 0
        }

        do {
            try prepareDirectory()
            var importedCount = 0

            for selection in selections {
                guard let data = try await selection.loadTransferable(type: Data.self),
                      !data.isEmpty else {
                    importCompleted += 1
                    continue
                }

                let contentType = selection.supportedContentTypes.first?.identifier
                    ?? UTType.image.identifier
                let item = VaultItem(
                    id: UUID(),
                    importedAt: Date(),
                    originalByteCount: data.count,
                    contentType: contentType
                )
                let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
                guard let encryptedData = sealedBox.combined else {
                    throw CocoaError(.fileWriteUnknown)
                }

                let envelope = VaultEnvelope(item: item, encryptedData: encryptedData)
                let encoded = try encoder.encode(envelope)
                try encoded.write(
                    to: fileURL(for: item.id),
                    options: [Data.WritingOptions.atomic, Data.WritingOptions.completeFileProtection]
                )

                importedCount += 1
                importCompleted += 1
            }

            loadItems()
            if importedCount == selections.count {
                successMessage = "\(importedCount) photo\(importedCount == 1 ? "" : "s") encrypted in the vault. Originals remain in Photos."
            } else {
                successMessage = "\(importedCount) of \(selections.count) photos were encrypted. Originals remain in Photos."
            }
        } catch {
            show(error)
            loadItems()
        }
    }

    func image(for item: VaultItem) -> UIImage? {
        guard let data = try? decryptedData(for: item) else { return nil }
        return UIImage(data: data)
    }

    func exportToPhotos(_ item: VaultItem) async {
        guard lockState == .unlocked else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let status = await requestAddOnlyPhotoAccess()
            guard status == .authorized || status == .limited else {
                errorMessage = "Allow Photos access to restore this item."
                return
            }

            let data = try decryptedData(for: item)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = item.contentType
                request.addResource(with: .photo, data: data, options: options)
            }
            successMessage = "A decrypted copy was saved to Photos. The encrypted vault copy remains protected."
        } catch {
            show(error)
        }
    }

    func delete(_ item: VaultItem) {
        do {
            try FileManager.default.removeItem(at: fileURL(for: item.id))
            items.removeAll { $0.id == item.id }
            successMessage = "The encrypted vault copy was deleted."
        } catch {
            show(error)
        }
    }

    func clearMessage() {
        errorMessage = nil
        successMessage = nil
    }

    private func isValidPIN(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try mutableURL.setResourceValues(resourceValues)
    }

    private func loadItems() {
        guard lockState == .unlocked else { return }

        do {
            try prepareDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            items = urls
                .filter { $0.pathExtension == "vault" }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url),
                          let envelope = try? decoder.decode(VaultEnvelope.self, from: data) else {
                        return nil
                    }
                    return envelope.item
                }
                .sorted { $0.importedAt > $1.importedAt }
        } catch {
            show(error)
        }
    }

    private func decryptedData(for item: VaultItem) throws -> Data {
        guard let encryptionKey else {
            throw VaultSecurityError.authenticationFailed
        }

        let encoded = try Data(contentsOf: fileURL(for: item.id))
        let envelope = try decoder.decode(VaultEnvelope.self, from: encoded)
        let sealedBox = try AES.GCM.SealedBox(combined: envelope.encryptedData)
        return try AES.GCM.open(sealedBox, using: encryptionKey)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("vault")
    }

    private func requestAddOnlyPhotoAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}
