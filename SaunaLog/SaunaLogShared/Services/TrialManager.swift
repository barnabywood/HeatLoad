import Foundation
import Combine
import Security

@MainActor
public final class TrialManager: ObservableObject {
    private enum Keys {
        static let sessionsCompleted = "trial.sessions.completed"
        static let lifetimeSessionsCompleted = "trial.sessions.lifetime.completed"
        static let hasUnlocked = "trial.has.unlocked"
        static let hasRequestedReviewPrompt = "trial.has.requested.review.prompt"
    }

    public static let freeSessionLimit = 3
    public static let reviewPromptThreshold = 5

    @Published public private(set) var sessionsCompleted: Int
    @Published public private(set) var lifetimeSessionsCompleted: Int
    @Published public private(set) var hasUnlocked: Bool
    @Published public private(set) var hasRequestedReviewPrompt: Bool

    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "com.barnabywood.saunalog.trial")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultsSessions = defaults.integer(forKey: Keys.sessionsCompleted)
        let defaultsLifetime = defaults.integer(forKey: Keys.lifetimeSessionsCompleted)
        let defaultsUnlocked = defaults.bool(forKey: Keys.hasUnlocked)
        let defaultsReviewPrompt = defaults.bool(forKey: Keys.hasRequestedReviewPrompt)

        sessionsCompleted = max(defaultsSessions, keychain.int(for: Keys.sessionsCompleted) ?? 0)
        lifetimeSessionsCompleted = max(defaultsLifetime, keychain.int(for: Keys.lifetimeSessionsCompleted) ?? 0)
        hasUnlocked = defaultsUnlocked || (keychain.bool(for: Keys.hasUnlocked) ?? false)
        hasRequestedReviewPrompt = defaultsReviewPrompt || (keychain.bool(for: Keys.hasRequestedReviewPrompt) ?? false)

        persistAll()
    }

    public var remainingFreeSessions: Int {
        max(0, Self.freeSessionLimit - sessionsCompleted)
    }

    public var canStartSession: Bool {
        hasUnlocked || sessionsCompleted < Self.freeSessionLimit
    }

    public var shouldPromptForReview: Bool {
        lifetimeSessionsCompleted >= Self.reviewPromptThreshold && !hasRequestedReviewPrompt
    }

    public func recordCompletedSession() {
        lifetimeSessionsCompleted += 1
        persistLifetime()

        guard !hasUnlocked else { return }
        sessionsCompleted += 1
        persistSessions()
    }

    public func syncFromPeer(
        sessionsCompleted peerCompleted: Int,
        lifetimeSessionsCompleted peerLifetimeCompleted: Int,
        hasUnlocked peerUnlocked: Bool
    ) {
        sessionsCompleted = max(sessionsCompleted, peerCompleted)
        lifetimeSessionsCompleted = max(lifetimeSessionsCompleted, peerLifetimeCompleted)

        persistSessions()
        persistLifetime()

        if peerUnlocked {
            unlock()
        }
    }

    public func markReviewPromptShown() {
        hasRequestedReviewPrompt = true
        persistReviewPrompt()
    }

    public func unlock() {
        hasUnlocked = true
        persistUnlocked()
    }

    public func resetUsageForTesting() {
#if DEBUG
        sessionsCompleted = 0
        persistSessions()
#endif
    }

    private func persistSessions() {
        defaults.set(sessionsCompleted, forKey: Keys.sessionsCompleted)
        keychain.set(sessionsCompleted, for: Keys.sessionsCompleted)
    }

    private func persistLifetime() {
        defaults.set(lifetimeSessionsCompleted, forKey: Keys.lifetimeSessionsCompleted)
        keychain.set(lifetimeSessionsCompleted, for: Keys.lifetimeSessionsCompleted)
    }

    private func persistUnlocked() {
        defaults.set(hasUnlocked, forKey: Keys.hasUnlocked)
        keychain.set(hasUnlocked, for: Keys.hasUnlocked)
    }

    private func persistReviewPrompt() {
        defaults.set(hasRequestedReviewPrompt, forKey: Keys.hasRequestedReviewPrompt)
        keychain.set(hasRequestedReviewPrompt, for: Keys.hasRequestedReviewPrompt)
    }

    private func persistAll() {
        persistSessions()
        persistLifetime()
        persistUnlocked()
        persistReviewPrompt()
    }
}

private struct KeychainStore {
    let service: String

    func int(for key: String) -> Int? {
        guard let string = string(for: key) else { return nil }
        return Int(string)
    }

    func bool(for key: String) -> Bool? {
        guard let string = string(for: key) else { return nil }
        return (string as NSString).boolValue
    }

    func set(_ value: Int, for key: String) {
        set(String(value), for: key)
    }

    func set(_ value: Bool, for key: String) {
        set(value ? "1" : "0", for: key)
    }

    private func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }
}
