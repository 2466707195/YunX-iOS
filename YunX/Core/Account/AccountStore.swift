import Foundation
import SwiftUI

// MARK: - 账号 / 收藏 / 历史

/// 账号仓库：负责账号的增删改、凭证加解密、备份导入导出。
///
/// 三条硬规则：
/// 1. `accounts` 里存的是**密文**，任何地方要明文都走 `cookie(for:)`，不要直接读 `credential`；
/// 2. 保存前必须先校验（视频平台问一次「我是谁」，网盘至少校验非空），
///    否则会存下一份永远解析失败的账号，用户看不懂错在哪；
/// 3. 同一个平台可以有多条账号（多账号下载/轮流取链靠它），但 UI 默认只显示最新一条。
@MainActor
final class AccountStore: ObservableObject {

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [ResolveHistory] = []

    private let accountsURL = StoragePaths.supportFile("accounts.json")
    private let bookmarksURL = StoragePaths.supportFile("bookmarks.json")
    private let historyURL = StoragePaths.supportFile("history.json")

    init() {
        accounts = JSONDisk.load([Account].self, from: accountsURL) ?? []
        bookmarks = JSONDisk.load([Bookmark].self, from: bookmarksURL) ?? []
        history = JSONDisk.load([ResolveHistory].self, from: historyURL) ?? []
    }

    // MARK: 查询

    func panAccounts(_ platform: SharePlatform) -> [Account] {
        accounts.filter { $0.scope == .pan && $0.key == platform.rawValue }
    }

    func videoAccounts(_ platform: VideoPlatform) -> [Account] {
        accounts.filter { $0.scope == .video && $0.key == platform.rawValue }
    }

    func primaryPanAccount(_ platform: SharePlatform) -> Account? {
        panAccounts(platform).max { $0.updatedAt < $1.updatedAt }
    }

    func primaryVideoAccount(_ platform: VideoPlatform) -> Account? {
        videoAccounts(platform).max { $0.updatedAt < $1.updatedAt }
    }

    /// 取明文凭证（Cookie / JWT）。没有账号时返回空串。
    func credential(for platform: SharePlatform) -> String {
        guard let account = primaryPanAccount(platform) else { return "" }
        return CredentialVault.open(account.credential)
    }

    func credential(for platform: VideoPlatform) -> String {
        guard let account = primaryVideoAccount(platform) else { return "" }
        return CredentialVault.open(account.credential)
    }

    func hasAccount(_ platform: SharePlatform) -> Bool {
        primaryPanAccount(platform) != nil
    }

    func hasAccount(_ platform: VideoPlatform) -> Bool {
        primaryVideoAccount(platform) != nil
    }

    // MARK: 写

    @discardableResult
    func savePanAccount(
        platform: SharePlatform,
        credential: String,
        nickname: String,
        method: AccountMethod
    ) -> Account {
        save(scope: .pan, key: platform.rawValue, credential: credential, nickname: nickname, method: method)
    }

    @discardableResult
    func saveVideoAccount(
        platform: VideoPlatform,
        cookie: String,
        nickname: String,
        method: AccountMethod
    ) -> Account {
        save(scope: .video, key: platform.rawValue, cookie: cookie, nickname: nickname, method: method)
    }

    @discardableResult
    private func save(
        scope: AccountScope,
        key: String,
        credential: String = "",
        cookie: String = "",
        nickname: String,
        method: AccountMethod
    ) -> Account {
        let plain = credential.isEmpty ? cookie : credential
        let sealed = (try? CredentialVault.seal(plain)) ?? ""
        // 同平台同昵称视为「更新」，避免每登录一次就多一条
        if let index = accounts.firstIndex(where: {
            $0.scope == scope && $0.key == key && $0.nickname == nickname
        }) {
            accounts[index].credential = sealed
            accounts[index].method = method
            accounts[index].updatedAt = Date()
            accounts[index].nickname = nickname
            persistAccounts()
            return accounts[index]
        }
        let account = Account(
            scope: scope,
            key: key,
            nickname: nickname,
            credential: sealed,
            method: method
        )
        accounts.append(account)
        persistAccounts()
        return account
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
    }

    func removeAll(scope: AccountScope? = nil) {
        if let scope {
            accounts.removeAll { $0.scope == scope }
        } else {
            accounts.removeAll()
        }
        persistAccounts()
    }

    // MARK: 收藏

    func addBookmark(title: String, link: String, platform: String) {
        guard !link.isEmpty else { return }
        if let index = bookmarks.firstIndex(where: { $0.link == link }) {
            bookmarks[index].title = title
            bookmarks[index].createdAt = Date()
        } else {
            bookmarks.append(Bookmark(title: title, link: link, platform: platform))
        }
        JSONDisk.save(bookmarks, to: bookmarksURL)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        JSONDisk.save(bookmarks, to: bookmarksURL)
    }

    // MARK: 历史

    func recordHistory(title: String, link: String, platform: String, kind: String) {
        let item = ResolveHistory(title: title, link: link, platform: platform, kind: kind)
        history.removeAll { $0.link == link }
        history.insert(item, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
        JSONDisk.save(history, to: historyURL)
    }

    func clearHistory() {
        history.removeAll()
        JSONDisk.save(history, to: historyURL)
    }

    // MARK: 备份

    struct BackupPayload: Codable {
        var version: Int = 1
        var exportedAt = Date()
        var accounts: [BackupAccount]
    }

    /// 备份里带**明文**凭证，只在内存里存在，写盘前整体加密
    struct BackupAccount: Codable {
        var scope: AccountScope
        var key: String
        var nickname: String
        var credential: String
        var method: AccountMethod
    }

    func exportBackup(passphrase: String) throws -> URL {
        let payload = BackupPayload(accounts: accounts.map { account in
            BackupAccount(
                scope: account.scope,
                key: account.key,
                nickname: account.nickname,
                credential: CredentialVault.open(account.credential),
                method: account.method
            )
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let plain = try encoder.encode(payload)
        let encrypted = try CredentialVault.encodeBackup(plaintext: plain, passphrase: passphrase)
        let name = "yunx-auth-backup-\(Date().formatted("yyyyMMdd-HHmm")).ynxbak"
        let url = StoragePaths.documents.appendingPathComponent(name)
        try encrypted.write(to: url, options: .atomic)
        return url
    }

    /// 导入备份：按「scope + key + nickname」合并
    @discardableResult
    func importBackup(from url: URL, passphrase: String) throws -> Int {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let plain = try CredentialVault.decodeBackup(data, passphrase: passphrase)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(BackupPayload.self, from: plain)
        for item in payload.accounts {
            let sealed = (try? CredentialVault.seal(item.credential)) ?? ""
            if let index = accounts.firstIndex(where: {
                $0.scope == item.scope && $0.key == item.key && $0.nickname == item.nickname
            }) {
                accounts[index].credential = sealed
                accounts[index].method = item.method
                accounts[index].updatedAt = Date()
            } else {
                accounts.append(Account(
                    scope: item.scope,
                    key: item.key,
                    nickname: item.nickname,
                    credential: sealed,
                    method: item.method
                ))
            }
        }
        persistAccounts()
        return payload.accounts.count
    }

    // MARK: 持久化

    private func persistAccounts() {
        JSONDisk.save(accounts, to: accountsURL)
        objectWillChange.send()
    }
}
