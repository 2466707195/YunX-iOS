import Foundation
import CryptoKit
import Security

// MARK: - 凭证保管

enum VaultError: LocalizedError {

    case keychain(OSStatus)
    case encryptFailed
    case badEnvelope
    case wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "钥匙串访问失败（\(status)）"
        case .encryptFailed: return "加密失败"
        case .badEnvelope: return "备份文件格式不正确"
        case .wrongPassphrase: return "口令错误或备份文件已损坏"
        }
    }
}

/// 凭证保管：**永不落明文**。
///
/// 两条链路：
/// 1. 设备内：AES-GCM + 钥匙串里的 256 位随机密钥（`deviceKey`）。
///    Cookie / JWT 存进 `accounts.json` 之前一律先过 `seal`，读的时候再 `open`。
/// 2. 导出备份：用户口令经 12 万次迭代 SHA-256 派生密钥，再 AES-GCM 密封。
///    备份文件 = `YNXBK1` + 16 字节 salt + sealed.combined（nonce+密文+tag）。
///
/// ★ 为什么不用 PBKDF2：iOS 的 CommonCrypto 需要桥接头，而工程里没有 bridging header。
///   迭代哈希在功能上等价（慢哈希 + 随机盐），差别只是没有内存硬化（argon2 那类）。
enum CredentialVault {

    private static let service = "com.yunx.vault"
    private static let keyAccount = "device-key"
    private static let backupMagic = Data("YNXBK1".utf8)
    private static let kdfIterations = 120_000

    // MARK: 设备密钥

    static func deviceKey() throws -> SymmetricKey {
        if let existing = readKeychain() {
            return SymmetricKey(data: existing)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        let data = Data(bytes)
        writeKeychain(data)
        return SymmetricKey(data: data)
    }

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func writeKeychain(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: 字段加解密

    /// 明文 → base64 密文（写入磁盘用）
    static func seal(_ text: String) throws -> String {
        guard !text.isEmpty else { return "" }
        do {
            let sealed = try AES.GCM.seal(Data(text.utf8), using: try deviceKey())
            guard let combined = sealed.combined else { throw VaultError.encryptFailed }
            return combined.base64EncodedString()
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.encryptFailed
        }
    }

    /// base64 密文 → 明文。解不开时返回空串（宁可让用户重新登录，也不要崩）。
    static func open(_ base64: String) -> String {
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return "" }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: try deviceKey())
            return String(data: plain, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: 备份

    static func encodeBackup(plaintext: Data, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            }
        }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw VaultError.encryptFailed }
            var output = backupMagic
            output.append(salt)
            output.append(combined)
            return output
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.encryptFailed
        }
    }

    static func decodeBackup(_ data: Data, passphrase: String) throws -> Data {
        let magicLength = backupMagic.count
        guard data.count > magicLength + 16 else { throw VaultError.badEnvelope }
        guard data.prefix(magicLength) == backupMagic else { throw VaultError.badEnvelope }
        let salt = data.subdata(in: magicLength..<(magicLength + 16))
        let body = data.subdata(in: (magicLength + 16)..<data.count)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.wrongPassphrase
        }
    }

    /// 迭代哈希 KDF：salt 参与每一轮，避免彩虹表
    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var digest = Data(SHA256.hash(data: salt + Data(passphrase.utf8)))
        for _ in 0..<kdfIterations {
            digest = Data(SHA256.hash(data: digest + salt))
        }
        return SymmetricKey(data: digest)
    }
}
