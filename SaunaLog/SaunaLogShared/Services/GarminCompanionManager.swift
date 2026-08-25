import Foundation
import Combine

#if canImport(ConnectIQ) && !targetEnvironment(simulator)
import ConnectIQ
#endif

@MainActor
public final class GarminCompanionManager: NSObject, ObservableObject {
    public static let shared = GarminCompanionManager()

    private enum Keys {
        static let devices = "garmin.companion.devices"
        static let receivedSessionIDs = "garmin.companion.receivedSessionIDs"
    }

    private static let appUUID = UUID(uuidString: "913001B8-7113-4A89-B5B9-C0F166398FE6")!
    // The Connect IQ Store UUID is normally supplied when the app is published.
    // Until then, the manifest UUID is used for development builds.
    private static let storeUUID = appUUID

    @Published public private(set) var isAvailable = false
    @Published public private(set) var isAppInstalled = false
    @Published public private(set) var deviceName: String?
    @Published public private(set) var hasSelectedDevice = false

    public var onSessionReceived: ((HeatSession) -> Void)?

#if canImport(ConnectIQ) && !targetEnvironment(simulator)
    private let connectIQ = ConnectIQ.sharedInstance()!
    private var devices: [IQDevice] = []
#endif

    private override init() {
        super.init()
    }

    public func activate() {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        connectIQ.initialize(
            withUrlScheme: "saunalog-ciq",
            uiOverrideDelegate: nil,
            stateRestorationIdentifier: "SaunaLogGarmin"
        )
        isAvailable = true
        restoreDevices()
#else
        isAvailable = false
#endif
    }

    public func requestDeviceSelection() {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        connectIQ.showDeviceSelection()
#endif
    }

    public func refresh() {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        guard let device = devices.first else { return }
        refreshAppStatus(for: device)
#endif
    }

    public func installOrConnect() {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        guard let device = devices.first else {
            requestDeviceSelection()
            return
        }
        let app = IQApp(uuid: Self.appUUID, store: Self.storeUUID, device: device)
        if isAppInstalled {
            refreshAppStatus(for: device)
        } else {
            connectIQ.showStore(for: app)
        }
#endif
    }

    public func handleOpenURL(_ url: URL) {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        guard let selected = connectIQ.parseDeviceSelectionResponse(from: url) as? [IQDevice],
              let device = selected.first else { return }

        devices = selected
        deviceName = device.friendlyName
        hasSelectedDevice = true
        saveDevices(selected)
        connectIQ.register(forDeviceEvents: device, delegate: self)
        registerAppMessages(for: device)
        refreshAppStatus(for: device)
#else
        _ = url
#endif
    }

    public func sendEntitlement(sessionsCompleted: Int, hasUnlocked: Bool) {
#if canImport(ConnectIQ) && !targetEnvironment(simulator)
        guard let device = devices.first else { return }
        let app = IQApp(uuid: Self.appUUID, store: Self.storeUUID, device: device)
        let message: [String: Any] = [
            "type": "saunaLog.entitlement",
            "authorized": true,
            "unlocked": hasUnlocked,
            "sessionsCompleted": sessionsCompleted,
            "freeSessionLimit": 3
        ]
        connectIQ.sendMessage(message, to: app, progress: nil) { _ in }
#else
        _ = sessionsCompleted
        _ = hasUnlocked
#endif
    }

#if canImport(ConnectIQ) && !targetEnvironment(simulator)
    private func saveDevices(_ devices: [IQDevice]) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: devices,
            requiringSecureCoding: true
        ) else { return }
        UserDefaults.standard.set(data, forKey: Keys.devices)
    }

    private func restoreDevices() {
        guard let data = UserDefaults.standard.data(forKey: Keys.devices),
              let restored = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSArray.self, IQDevice.self],
                from: data
              ) as? [IQDevice],
              let device = restored.first else {
            hasSelectedDevice = false
            return
        }

        devices = restored
        deviceName = device.friendlyName
        hasSelectedDevice = true
        connectIQ.register(forDeviceEvents: device, delegate: self)
        registerAppMessages(for: device)
        refreshAppStatus(for: device)
    }

    private func registerAppMessages(for device: IQDevice) {
        let app = IQApp(uuid: Self.appUUID, store: Self.storeUUID, device: device)
        connectIQ.register(forAppMessages: app, delegate: self)
    }
#endif

#if canImport(ConnectIQ) && !targetEnvironment(simulator)
    private func refreshAppStatus(for device: IQDevice) {
        let app = IQApp(uuid: Self.appUUID, store: Self.storeUUID, device: device)
        connectIQ.getAppStatus(app) { [weak self] status in
            let installed = status?.isInstalled ?? false
            Task { @MainActor [weak self] in
                self?.isAppInstalled = installed
            }
        }
    }
#endif
}

#if canImport(ConnectIQ) && !targetEnvironment(simulator)
extension GarminCompanionManager: IQDeviceEventDelegate, IQAppMessageDelegate {
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        Task { @MainActor [weak self] in
            self?.isAvailable = status == .connected
        }
    }

    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {}

    public func receivedMessage(_ message: Any, from app: IQApp) {
        _ = app
        guard let payload = message as? [String: Any],
              payload["type"] as? String == "saunaLog.session",
              let sourceID = payload["sourceId"] as? String,
              let heatSession = decodeSession(payload) else { return }

        var receivedIDs = UserDefaults.standard.stringArray(forKey: Keys.receivedSessionIDs) ?? []
        guard !receivedIDs.contains(sourceID) else { return }
        receivedIDs.append(sourceID)
        UserDefaults.standard.set(Array(receivedIDs.suffix(200)), forKey: Keys.receivedSessionIDs)

        Task { @MainActor [weak self] in
            self?.onSessionReceived?(heatSession)
        }
    }

    private func decodeSession(_ payload: [String: Any]) -> HeatSession? {
        func number(_ key: String) -> Double? {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? NSNumber { return value.doubleValue }
            return nil
        }

        guard let activityRaw = payload["activityType"] as? String,
              let activityType = HeatActivityType(rawValue: activityRaw),
              let start = number("startTime"),
              let end = number("endTime"),
              let planned = number("plannedDurationSeconds") else { return nil }

        return HeatSession(
            activityType: activityType,
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: end),
            hadColdShower: payload["hadColdShower"] as? Bool ?? false,
            plannedDurationSeconds: Int(planned),
            averageHeartRate: number("averageHeartRate") ?? 0,
            maxHeartRate: number("maxHeartRate") ?? 0,
            activeCalories: number("activeCalories") ?? 0,
            totalCalories: number("totalCalories") ?? 0,
            temperatureCelsius: number("temperatureCelsius"),
            humidityPercent: number("humidityPercent"),
            environmentWasDefault: payload["environmentWasDefault"] as? Bool
        )
    }
}
#endif
