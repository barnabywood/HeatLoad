import Foundation
import Combine
import WatchConnectivity

public final class WatchSyncManager: NSObject, ObservableObject {
    private enum Keys {
        static let payload = "payload"
        static let trialSessionsCompleted = "trialSessionsCompleted"
        static let trialLifetimeSessionsCompleted = "trialLifetimeSessionsCompleted"
        static let trialHasUnlocked = "trialHasUnlocked"
        static let presetSeconds = "presetSeconds"
        static let selectedPresetSeconds = "selectedPresetSeconds"
        static let minHeartRateAlertBPM = "minHeartRateAlertBPM"
        static let maxHeartRateAlertBPM = "maxHeartRateAlertBPM"
        static let trialStateRequest = "trialStateRequest"
    }

    public static let shared = WatchSyncManager()

    @Published public private(set) var isReachable = false
    @Published public private(set) var isPaired = false
    @Published public private(set) var isWatchAppInstalled = false

    public var isWatchReady: Bool {
        guard WCSession.isSupported() else { return false }
#if os(iOS)
        return isPaired && isWatchAppInstalled
#else
        return true
#endif
    }

    public var onSessionReceived: ((HeatSession) -> Void)?
    public var onTrialProgressReceived: ((Int, Int, Bool) -> Void)?
    public var onTrialProgressRequested: (() -> Void)?
    public var onPresetsReceived: (([Int], Int) -> Void)?
    public var onHeartRateAlertsReceived: ((Int?, Int?) -> Void)?

    private let session = WCSession.default

    private override init() {
        super.init()
    }

    private func publishOnMain(_ updates: @escaping () -> Void) {
        if Thread.isMainThread {
            updates()
        } else {
            DispatchQueue.main.async(execute: updates)
        }
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        refreshStatus()
    }

    public func refreshStatus() {
        guard WCSession.isSupported() else {
            publishOnMain {
                self.isReachable = false
                self.isPaired = false
                self.isWatchAppInstalled = false
            }
            return
        }

        publishOnMain {
            self.isReachable = self.session.isReachable
#if os(iOS)
            self.isPaired = self.session.isPaired
            self.isWatchAppInstalled = self.session.isWatchAppInstalled
#else
            self.isPaired = true
            self.isWatchAppInstalled = true
#endif
        }
    }

    public func send(session heatSession: HeatSession) {
        guard WCSession.isSupported() else { return }

        do {
            let payload = try JSONEncoder().encode(SessionSyncPayload(session: heatSession))

            if session.isReachable {
                session.sendMessageData(payload, replyHandler: nil) { _ in }
            }

            var context = session.applicationContext
            context[Keys.payload] = payload
            try session.updateApplicationContext(context)

            session.transferUserInfo([Keys.payload: payload])
        } catch {
            // Intentionally ignored for starter template.
        }
    }

    public func sendTrialProgress(sessionsCompleted: Int, lifetimeSessionsCompleted: Int, hasUnlocked: Bool) {
        guard WCSession.isSupported() else { return }

        let message: [String: Any] = [
            Keys.trialSessionsCompleted: sessionsCompleted,
            Keys.trialLifetimeSessionsCompleted: lifetimeSessionsCompleted,
            Keys.trialHasUnlocked: hasUnlocked
        ]

        do {
            var context = session.applicationContext
            context[Keys.trialSessionsCompleted] = sessionsCompleted
            context[Keys.trialLifetimeSessionsCompleted] = lifetimeSessionsCompleted
            context[Keys.trialHasUnlocked] = hasUnlocked
            try session.updateApplicationContext(context)
        } catch {
            // Best effort; sendMessage/transferUserInfo below still have a chance to deliver.
        }

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] _ in
                self?.session.transferUserInfo(message)
            }
        }

        if hasUnlocked {
            session.transferUserInfo(message)
        }
    }

    public func requestTrialProgressSync() {
        guard WCSession.isSupported() else { return }

        let message: [String: Any] = [
            Keys.trialStateRequest: Date().timeIntervalSince1970
        ]

        do {
            var context = session.applicationContext
            context[Keys.trialStateRequest] = Date().timeIntervalSince1970
            try session.updateApplicationContext(context)
        } catch {
            // Best effort; sendMessage/transferUserInfo below still have a chance to deliver.
        }

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] _ in
                self?.session.transferUserInfo(message)
            }
        }

        session.transferUserInfo(message)
    }

    public func sendPresets(_ presetSeconds: [Int], selectedPresetSeconds: Int) {
        guard WCSession.isSupported(), presetSeconds.count == 4 else { return }

        let message: [String: Any] = [
            Keys.presetSeconds: presetSeconds,
            Keys.selectedPresetSeconds: selectedPresetSeconds
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in }
        } else {
            do {
                var context = session.applicationContext
                context[Keys.presetSeconds] = presetSeconds
                context[Keys.selectedPresetSeconds] = selectedPresetSeconds
                try session.updateApplicationContext(context)
            } catch {
                // Intentionally ignored for starter template.
            }
        }
    }

    public func sendHeartRateAlerts(min: Int?, max: Int?) {
        guard WCSession.isSupported() else { return }

        let minValue = min ?? 0
        let maxValue = max ?? 0

        let message: [String: Any] = [
            Keys.minHeartRateAlertBPM: minValue,
            Keys.maxHeartRateAlertBPM: maxValue
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in }
        } else {
            do {
                var context = session.applicationContext
                context[Keys.minHeartRateAlertBPM] = minValue
                context[Keys.maxHeartRateAlertBPM] = maxValue
                try session.updateApplicationContext(context)
            } catch {
                // Intentionally ignored.
            }
        }
    }
}

extension WatchSyncManager: WCSessionDelegate {
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        refreshStatus()
    }

#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        refreshStatus()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        refreshStatus()
    }
#endif

    public func sessionReachabilityDidChange(_ session: WCSession) {
        refreshStatus()
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        handle(context: applicationContext)
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handle(data: messageData)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handle(context: message)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handle(context: userInfo)
    }

    private func handle(context: [String: Any]) {
        if let data = context[Keys.payload] as? Data {
            handle(data: data)
        }

        if let sessionsCompleted = context[Keys.trialSessionsCompleted] as? Int,
           let lifetimeSessionsCompleted = context[Keys.trialLifetimeSessionsCompleted] as? Int,
           let hasUnlocked = context[Keys.trialHasUnlocked] as? Bool {
            publishOnMain {
                self.onTrialProgressReceived?(sessionsCompleted, lifetimeSessionsCompleted, hasUnlocked)
            }
        }

        if context[Keys.trialStateRequest] != nil {
            publishOnMain {
                self.onTrialProgressRequested?()
            }
        }

        if let presetSeconds = context[Keys.presetSeconds] as? [Int],
           presetSeconds.count == 4,
           let selectedPresetSeconds = context[Keys.selectedPresetSeconds] as? Int {
            publishOnMain {
                self.onPresetsReceived?(presetSeconds, selectedPresetSeconds)
            }
        }

        if let minRaw = context[Keys.minHeartRateAlertBPM] as? Int,
           let maxRaw = context[Keys.maxHeartRateAlertBPM] as? Int {
            let minValue = minRaw > 0 ? minRaw : nil
            let maxValue = maxRaw > 0 ? maxRaw : nil
            publishOnMain {
                self.onHeartRateAlertsReceived?(minValue, maxValue)
            }
        }
    }

    private func handle(data: Data) {
        guard let payload = try? JSONDecoder().decode(SessionSyncPayload.self, from: data) else { return }
        publishOnMain {
            self.onSessionReceived?(payload.session)
        }
    }
}
