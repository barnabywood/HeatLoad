import Foundation
import Combine

@MainActor
public final class SessionStore: ObservableObject {
    private enum Keys {
        static let presets = "session.presets"
        static let selectedPresetSeconds = "session.selectedPresetSeconds"
        static let recentSessions = "session.recent.sessions"
        static let deletedSessions = "session.deleted.sessions"
        static let minHeartRateAlertBPM = "session.hrAlert.min"
        static let maxHeartRateAlertBPM = "session.hrAlert.max"
        static let deletedSessionIDs = "session.deleted.ids"
        static let deletedSessionSignatures = "session.deleted.signatures"
    }

    public static let defaultPresets: [Int] = [5 * 60, 10 * 60, 15 * 60, 20 * 60]

    @Published public var selectedActivity: HeatActivityType = .sauna
    @Published public var presets: [Int]
    @Published public var selectedPresetSeconds: Int
    @Published public var countdownRemainingSeconds: Int
    @Published public private(set) var activeSessionStart: Date?
    @Published public private(set) var currentPlannedDurationSeconds: Int
    @Published public private(set) var recentSessions: [HeatSession] = []
    @Published public private(set) var deletedSessions: [HeatSession] = []
    @Published public private(set) var minHeartRateAlertBPM: Int?
    @Published public private(set) var maxHeartRateAlertBPM: Int?

    private let defaults: UserDefaults
    private var timerTask: Task<Void, Never>?
    private var activeSessionEnd: Date?
    private var deletedSessionIDs: Set<UUID>
    private var deletedSessionSignatures: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let initialPresets: [Int]
        if let stored = defaults.array(forKey: Keys.presets) as? [Int],
           stored.count == 4,
           stored.allSatisfy({ $0 > 0 }) {
            initialPresets = stored
        } else {
            initialPresets = Self.defaultPresets
        }

        let storedSelected = defaults.integer(forKey: Keys.selectedPresetSeconds)
        let initialSelected: Int
        if initialPresets.contains(storedSelected) {
            initialSelected = storedSelected
        } else {
            initialSelected = initialPresets.indices.contains(1) ? initialPresets[1] : initialPresets[0]
        }

        self.presets = initialPresets
        self.selectedPresetSeconds = initialSelected
        self.countdownRemainingSeconds = initialSelected
        self.currentPlannedDurationSeconds = initialSelected

        let storedDeletedIDStrings = defaults.stringArray(forKey: Keys.deletedSessionIDs) ?? []
        self.deletedSessionIDs = Set(storedDeletedIDStrings.compactMap(UUID.init(uuidString:)))
        self.deletedSessionSignatures = Set(defaults.stringArray(forKey: Keys.deletedSessionSignatures) ?? [])

        self.deletedSessions = Self.loadDeletedSessions(defaults: defaults)
        self.recentSessions = Self.loadRecentSessions(defaults: defaults)
            .filter { !isSessionDeleted($0) }

        let storedMin = defaults.integer(forKey: Keys.minHeartRateAlertBPM)
        let storedMax = defaults.integer(forKey: Keys.maxHeartRateAlertBPM)
        self.minHeartRateAlertBPM = storedMin > 0 ? storedMin : nil
        self.maxHeartRateAlertBPM = storedMax > 0 ? storedMax : nil

        persistPresets()
        persistHeartRateAlerts()
        persistDeletedSessions()
        persistRecentSessions()
        persistDeletedArchive()
    }

    public var isSessionActive: Bool {
        activeSessionStart != nil
    }

    public func setPreset(_ seconds: Int) {
        selectedPresetSeconds = seconds
        defaults.set(seconds, forKey: Keys.selectedPresetSeconds)

        if !isSessionActive {
            countdownRemainingSeconds = seconds
            currentPlannedDurationSeconds = seconds
        }
    }

    @discardableResult
    public func updatePreset(at index: Int, minutes: Int) -> Bool {
        guard presets.indices.contains(index) else { return false }

        let newSeconds = max(1, minutes) * 60
        let oldSeconds = presets[index]
        presets[index] = newSeconds

        if selectedPresetSeconds == oldSeconds || !presets.contains(selectedPresetSeconds) {
            selectedPresetSeconds = newSeconds
            defaults.set(newSeconds, forKey: Keys.selectedPresetSeconds)

            if !isSessionActive {
                countdownRemainingSeconds = newSeconds
                currentPlannedDurationSeconds = newSeconds
            }
        }

        persistPresets()
        return true
    }

    public func replacePresets(_ newPresets: [Int], preferredSelected: Int) {
        guard newPresets.count == 4 else { return }

        presets = newPresets.map { max(60, $0) }

        if presets.contains(preferredSelected) {
            selectedPresetSeconds = preferredSelected
        } else if presets.contains(selectedPresetSeconds) {
            // Keep current selection.
        } else {
            selectedPresetSeconds = presets[0]
        }

        if !isSessionActive {
            countdownRemainingSeconds = selectedPresetSeconds
            currentPlannedDurationSeconds = selectedPresetSeconds
        }

        persistPresets()
    }

    public func setHeartRateAlerts(min minBPM: Int?, max maxBPM: Int?) {
        var normalizedMin = minBPM
        var normalizedMax = maxBPM

        if let minValue = normalizedMin {
            normalizedMin = Swift.max(40, Swift.min(220, minValue))
        }
        if let maxValue = normalizedMax {
            normalizedMax = Swift.max(40, Swift.min(220, maxValue))
        }

        if let minValue = normalizedMin, let maxValue = normalizedMax, minValue >= maxValue {
            normalizedMax = Swift.min(220, minValue + 1)
        }

        minHeartRateAlertBPM = normalizedMin
        maxHeartRateAlertBPM = normalizedMax
        persistHeartRateAlerts()
    }

    public func replaceHeartRateAlerts(min: Int?, max: Int?) {
        setHeartRateAlerts(min: min, max: max)
    }

    public func startSession() {
        guard !isSessionActive else { return }

        let start = Date()
        activeSessionStart = start
        activeSessionEnd = start.addingTimeInterval(TimeInterval(selectedPresetSeconds))
        currentPlannedDurationSeconds = selectedPresetSeconds

        syncCountdownFromClock()
        startTimerLoop()
    }

    public func addTime(_ seconds: Int) {
        guard isSessionActive, let end = activeSessionEnd else { return }

        let addedSeconds = Swift.max(60, seconds)
        selectedPresetSeconds = addedSeconds
        defaults.set(addedSeconds, forKey: Keys.selectedPresetSeconds)

        activeSessionEnd = end.addingTimeInterval(TimeInterval(addedSeconds))
        currentPlannedDurationSeconds += addedSeconds
        syncCountdownFromClock()
    }

    public func addTimeUsingPreset() {
        addTime(selectedPresetSeconds)
    }

    public func stopSession(buildSession: (Date) -> HeatSession?) {
        guard let start = activeSessionStart else { return }

        timerTask?.cancel()
        timerTask = nil
        activeSessionStart = nil
        activeSessionEnd = nil

        if let session = buildSession(start) {
            deletedSessionIDs.remove(session.id)
            deletedSessionSignatures.remove(Self.sessionSignature(for: session))
            recentSessions = dedupedSortedSessions(inserting: [session], into: recentSessions)
            persistDeletedSessions()
            persistRecentSessions()
        }

        countdownRemainingSeconds = selectedPresetSeconds
        currentPlannedDurationSeconds = selectedPresetSeconds
    }

    public func addSession(_ session: HeatSession) {
        deletedSessionIDs.remove(session.id)
        deletedSessionSignatures.remove(Self.sessionSignature(for: session))
        recentSessions = dedupedSortedSessions(inserting: [session], into: recentSessions)
        persistDeletedSessions()
        persistRecentSessions()
    }

    public func deleteSession(_ session: HeatSession) {
        deletedSessionIDs.insert(session.id)
        deletedSessionSignatures.insert(Self.sessionSignature(for: session))

        recentSessions.removeAll(where: { candidate in
            candidate.id == session.id || Self.areLikelySameSession(candidate, session)
        })

        deletedSessions = dedupedSortedSessions(inserting: [session], into: deletedSessions)

        persistDeletedSessions()
        persistRecentSessions()
        persistDeletedArchive()
    }

    public func mergeRecoveredSessions(_ sessions: [HeatSession]) {
        guard !sessions.isEmpty else { return }

        let filtered = sessions.filter { !isSessionDeleted($0) }
        guard !filtered.isEmpty else { return }

        recentSessions = dedupedSortedSessions(inserting: filtered, into: recentSessions)
        persistRecentSessions()
    }

    public func format(seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func persistPresets() {
        defaults.set(presets, forKey: Keys.presets)
        defaults.set(selectedPresetSeconds, forKey: Keys.selectedPresetSeconds)
    }

    private func persistRecentSessions() {
        if let encoded = try? JSONEncoder().encode(recentSessions) {
            defaults.set(encoded, forKey: Keys.recentSessions)
        }
    }

    private func persistDeletedArchive() {
        if let encoded = try? JSONEncoder().encode(deletedSessions) {
            defaults.set(encoded, forKey: Keys.deletedSessions)
        }
    }

    private func persistHeartRateAlerts() {
        defaults.set(minHeartRateAlertBPM ?? 0, forKey: Keys.minHeartRateAlertBPM)
        defaults.set(maxHeartRateAlertBPM ?? 0, forKey: Keys.maxHeartRateAlertBPM)
    }

    private func persistDeletedSessions() {
        defaults.set(deletedSessionIDs.map(\.uuidString), forKey: Keys.deletedSessionIDs)
        defaults.set(Array(deletedSessionSignatures), forKey: Keys.deletedSessionSignatures)
    }

    private static func loadRecentSessions(defaults: UserDefaults) -> [HeatSession] {
        guard let data = defaults.data(forKey: Keys.recentSessions),
              let sessions = try? JSONDecoder().decode([HeatSession].self, from: data) else {
            return []
        }

        return sessions.sorted(by: { $0.endDate > $1.endDate })
    }

    private static func loadDeletedSessions(defaults: UserDefaults) -> [HeatSession] {
        guard let data = defaults.data(forKey: Keys.deletedSessions),
              let sessions = try? JSONDecoder().decode([HeatSession].self, from: data) else {
            return []
        }

        return sessions.sorted(by: { $0.endDate > $1.endDate })
    }

    private func dedupedSortedSessions(inserting newSessions: [HeatSession], into existing: [HeatSession]) -> [HeatSession] {
        var all = existing
        all.append(contentsOf: newSessions)

        var result: [HeatSession] = []
        for session in all.sorted(by: { $0.endDate > $1.endDate }) {
            if result.contains(where: { Self.areLikelySameSession($0, session) }) {
                continue
            }
            result.append(session)
            if result.count >= 200 {
                break
            }
        }

        return result
    }

    private static func sessionSignature(for session: HeatSession) -> String {
        let startBucket = Int((session.startDate.timeIntervalSince1970 / 60.0).rounded())
        let endBucket = Int((session.endDate.timeIntervalSince1970 / 60.0).rounded())
        return "\(session.activityType.rawValue)|\(startBucket)|\(endBucket)"
    }

    private func isSessionDeleted(_ session: HeatSession) -> Bool {
        if deletedSessionIDs.contains(session.id) { return true }

        let signature = Self.sessionSignature(for: session)
        if deletedSessionSignatures.contains(signature) { return true }

        return deletedSessionSignatures.contains { deletedSignature in
            Self.signatureLikelyMatchesSession(deletedSignature, session: session)
        }
    }

    private static func signatureLikelyMatchesSession(_ signature: String, session: HeatSession) -> Bool {
        let parts = signature.split(separator: "|")
        guard parts.count >= 3 else { return false }
        guard parts[0] == Substring(session.activityType.rawValue) else { return false }
        guard let deletedStart = Int(parts[1]), let deletedEnd = Int(parts[2]) else { return false }

        let startBucket = Int((session.startDate.timeIntervalSince1970 / 60.0).rounded())
        let endBucket = Int((session.endDate.timeIntervalSince1970 / 60.0).rounded())

        return abs(startBucket - deletedStart) <= 2 && abs(endBucket - deletedEnd) <= 2
    }

    private static func areLikelySameSession(_ lhs: HeatSession, _ rhs: HeatSession) -> Bool {
        guard lhs.activityType == rhs.activityType else { return false }
        let startDelta = abs(lhs.startDate.timeIntervalSince(rhs.startDate))
        let endDelta = abs(lhs.endDate.timeIntervalSince(rhs.endDate))
        return startDelta <= 120 && endDelta <= 120
    }

    private func startTimerLoop() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.syncCountdownFromClock()
            }
        }
    }

    private func syncCountdownFromClock() {
        guard let end = activeSessionEnd else { return }
        let remaining = max(0, Int(ceil(end.timeIntervalSinceNow)))
        countdownRemainingSeconds = remaining
    }
}
