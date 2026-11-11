import Foundation
import Security

/// The Notion token in the login Keychain.
enum Keychain {
    static let service = "local.notionbar.NotionBar"
    static let account = "notion-token"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum Lookup: Equatable {
        case found(String)
        /// Nothing saved.
        case missing
        /// Something is saved, but macOS wouldn't hand it over just now: the screen is locked,
        /// or the "allow NotionBar to use your keychain" question hasn't been answered yet.
        case unavailable(OSStatus)
    }

    static func lookup(account: String = Keychain.account) -> Lookup {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return .missing }
        return .found(token)
    }

    /// The saved token, or nil when there isn't one (or the Keychain wouldn't hand it over).
    static func read(account: String = Keychain.account) -> String? {
        if case .found(let token) = lookup(account: account) { return token }
        return nil
    }

    @discardableResult
    static func save(_ token: String, account: String = Keychain.account) -> Bool {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "NotionBar: Notion token"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String = Keychain.account) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Where the app gets its token. The value itself is never logged or shown.
@MainActor
final class TokenStore: ObservableObject {
    /// The plain text file the SwiftBar plugin used.
    nonisolated static let legacyFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notion-menubar-token")

    enum Source: String {
        case none, keychain, importedFromFile, file, demo
        /// A token is saved, but macOS hasn't let the app read it yet. Tried again on the next fetch.
        case keychainLocked
    }

    @Published private(set) var source: Source = .none
    private var cached: String?
    private let demo: Bool
    private let file: URL
    private let account: String

    /// `file` and `account` are only ever changed by the self-test, so it can't touch the real token.
    init(demo: Bool = false, file: URL = TokenStore.legacyFile, account: String = Keychain.account) {
        self.demo = demo
        self.file = file
        self.account = account
        if demo {
            cached = "demo-token"
            source = .demo
        } else {
            load()
        }
    }

    var token: String? { cached }
    var hasToken: Bool { !(cached ?? "").isEmpty }

    /// Keychain first. If it's empty, import from `~/.notion-menubar-token` (first launch).
    func load() {
        guard !demo else { return }
        let lookup = Keychain.lookup(account: account)
        if case .found(let saved) = lookup {
            if source == .keychainLocked { Log.write("keychain: token readable now") }
            cached = saved
            source = .keychain
            return
        }
        guard let fromFile = TokenStore.readFile(file) else {
            cached = nil
            if case .unavailable(let status) = lookup {
                if source != .keychainLocked { Log.write("keychain: a token is saved but couldn't be read (status \(status)); will try again") }
                source = .keychainLocked
            } else {
                source = .none
            }
            return
        }
        cached = fromFile
        // If the Keychain refuses the write, keep using the file for this run.
        source = Keychain.save(fromFile, account: account) ? .importedFromFile : .file
    }

    /// Saves a new token from the Settings window. An empty string removes it.
    @discardableResult
    func set(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo else {
            cached = trimmed
            return true
        }
        if trimmed.isEmpty {
            Keychain.delete(account: account)
            cached = nil
            source = .none
            return true
        }
        let saved = Keychain.save(trimmed, account: account)
        cached = trimmed
        source = saved ? .keychain : .none
        return saved
    }

    static func readFile(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
