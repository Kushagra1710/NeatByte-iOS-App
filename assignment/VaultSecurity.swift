import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum VaultSecurityError: LocalizedError {
    case keychain(OSStatus)
    case invalidPIN
    case pinNotConfigured
    case authenticationUnavailable
    case authenticationFailed
    case corruptedKey

    var errorDescription: String? {
        switch self {
        case .keychain:
            "The secure Keychain could not be accessed."
        case .invalidPIN:
            "The PIN is incorrect."
        case .pinNotConfigured:
            "Set up a PIN before using the vault."
        case .authenticationUnavailable:
            "Device authentication is not available."
        case .authenticationFailed:
            "Authentication did not complete."
        case .corruptedKey:
            "The vault encryption key is unavailable or invalid."
        }
    }
}

struct VaultPINRecord: Codable {
    let salt: Data
    let digest: Data
}

enum VaultKeychain {
    private static let service = "com.kushagrasharma.Neatbyte.private-vault"

    static func data(for account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw VaultSecurityError.keychain(status)
        }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw VaultSecurityError.keychain(updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw VaultSecurityError.keychain(insertStatus)
        }
    }
}

@MainActor
final class VaultSecurity {
    private enum Account {
        static let masterKey = "master-key"
        static let pinRecord = "pin-record"
    }

    private static let pinHashRounds = 25_000

    var isConfigured: Bool {
        (try? VaultKeychain.data(for: Account.pinRecord)) != nil
    }

    var biometricName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Device authentication"
        }

        switch context.biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        case .none:
            return "Device authentication"
        @unknown default:
            return "Device authentication"
        }
    }

    func configure(pin: String) throws -> SymmetricKey {
        let key = try loadOrCreateMasterKey()
        try savePIN(pin)
        return key
    }

    func verify(pin: String) throws -> SymmetricKey {
        guard let recordData = try VaultKeychain.data(for: Account.pinRecord) else {
            throw VaultSecurityError.pinNotConfigured
        }
        let record = try JSONDecoder().decode(VaultPINRecord.self, from: recordData)
        let candidate = Self.pinDigest(pin: pin, salt: record.salt)
        guard candidate == record.digest else {
            throw VaultSecurityError.invalidPIN
        }
        return try loadMasterKey()
    }

    func authenticateDevice() async throws -> SymmetricKey {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw VaultSecurityError.authenticationUnavailable
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your encrypted Neatbyte private vault."
            )
            guard authenticated else {
                throw VaultSecurityError.authenticationFailed
            }
            return try loadMasterKey()
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
            throw VaultSecurityError.authenticationFailed
        }
    }

    func changePIN(currentPIN: String, newPIN: String) throws {
        _ = try verify(pin: currentPIN)
        try savePIN(newPIN)
    }

    private func loadOrCreateMasterKey() throws -> SymmetricKey {
        if let data = try VaultKeychain.data(for: Account.masterKey) {
            guard data.count == 32 else {
                throw VaultSecurityError.corruptedKey
            }
            return SymmetricKey(data: data)
        }

        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultSecurityError.keychain(status)
        }
        try VaultKeychain.set(bytes, for: Account.masterKey)
        return SymmetricKey(data: bytes)
    }

    private func loadMasterKey() throws -> SymmetricKey {
        guard let data = try VaultKeychain.data(for: Account.masterKey),
              data.count == 32 else {
            throw VaultSecurityError.corruptedKey
        }
        return SymmetricKey(data: data)
    }

    private func savePIN(_ pin: String) throws {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultSecurityError.keychain(status)
        }

        let record = VaultPINRecord(
            salt: salt,
            digest: Self.pinDigest(pin: pin, salt: salt)
        )
        try VaultKeychain.set(try JSONEncoder().encode(record), for: Account.pinRecord)
    }

    private static func pinDigest(pin: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 1..<pinHashRounds {
            digest = Data(SHA256.hash(data: digest + salt))
        }
        return digest
    }
}
