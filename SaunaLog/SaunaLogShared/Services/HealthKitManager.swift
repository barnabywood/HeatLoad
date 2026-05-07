import Foundation
import Combine
import HealthKit

@MainActor
public final class HealthKitManager: NSObject, ObservableObject {
    public static let metadataHeatActivityKey = "com.heatload.activityType"
    public static let metadataColdShowerKey = "com.heatload.hadColdShower"

    @Published public private(set) var currentHeartRate: Double?
    @Published public private(set) var currentActiveCalories: Double = 0
    @Published public private(set) var currentTotalCalories: Double = 0

#if os(watchOS)
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var heartRateReadings: [HeartRateReading] = []
    private var pendingSessionEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var liveMetricsPollingTask: Task<Void, Never>?
    private var lastPolledHeartRateBPM: Double?

    public private(set) var lastEndedWorkoutUUID: UUID?

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let workoutType = HKObjectType.workoutType()
        let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        let basalEnergy = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!

        try await healthStore.requestAuthorization(
            toShare: [workoutType],
            read: [heartRate, activeEnergy, basalEnergy, workoutType]
        )

        let workoutShareStatus = healthStore.authorizationStatus(for: workoutType)
        switch workoutShareStatus {
        case .sharingDenied:
            throw NSError(
                domain: "HealthKitManager",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Health permission denied. Enable Workout write access for Sauna Log in Health permissions."]
            )
        case .notDetermined:
            throw NSError(
                domain: "HealthKitManager",
                code: 402,
                userInfo: [NSLocalizedDescriptionKey: "Health permission not granted yet. Please allow access when prompted."]
            )
        case .sharingAuthorized:
            break
        default:
            break
        }
    }

    public func startWorkout(activityType: HeatActivityType, startDate: Date = Date()) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = mappedWorkoutActivityType(for: activityType)
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()

        attach(to: session, builder: builder, configuration: configuration)

        heartRateReadings = []
        currentHeartRate = nil
        currentActiveCalories = 0
        currentTotalCalories = 0
        lastEndedWorkoutUUID = nil

        let metadata: [String: Any] = [
            Self.metadataHeatActivityKey: activityType.rawValue,
            "com.heatload.activityDisplayName": activityType.displayName,
            HKMetadataKeyWorkoutBrandName: "Sauna Log \(activityType.displayName)",
            HKMetadataKeyIndoorWorkout: true
        ]

        session.startActivity(with: startDate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: startDate) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        builder.addMetadata(metadata) { _, _ in }
    }

    public func recoverActiveWorkoutSession(_ session: HKWorkoutSession) {
        let builder = session.associatedWorkoutBuilder()
        attach(to: session, builder: builder, configuration: session.workoutConfiguration)
    }

    private func attach(to session: HKWorkoutSession, builder: HKLiveWorkoutBuilder, configuration: HKWorkoutConfiguration) {
        session.delegate = self
        builder.delegate = self
        if builder.dataSource == nil {
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        }
        workoutSession = session
        workoutBuilder = builder
        startLiveMetricsPolling()
    }

    private func mappedWorkoutActivityType(for activityType: HeatActivityType) -> HKWorkoutActivityType {
        // HealthKit has no native sauna/steam activity types; map to closest available category.
        return .preparationAndRecovery
    }

    public func endWorkout(
        endDate: Date = Date(),
        hadColdShower: Bool,
        plannedDurationSeconds: Int,
        startDate: Date? = nil,
        activityType: HeatActivityType? = nil
    ) async throws -> (average: Double, max: Double, activeCalories: Double, totalCalories: Double) {
        lastEndedWorkoutUUID = nil

        guard let session = workoutSession, let builder = workoutBuilder else {
            if let startDate, let activityType {
                try await saveFallbackWorkout(
                    startDate: startDate,
                    endDate: endDate,
                    activityType: activityType,
                    hadColdShower: hadColdShower,
                    plannedDurationSeconds: plannedDurationSeconds
                )
            }
            return currentMetricsSnapshot()
        }

        switch session.state {
        case .running, .paused:
            session.stopActivity(with: endDate)
            session.end()
        case .prepared, .stopped:
            session.end()
        case .ended:
            break
        default:
            session.end()
        }

        await waitForSessionToEnd(session, timeoutSeconds: 18)

        guard session.state == .ended else {
            if let startDate, let activityType {
                try? await saveFallbackWorkout(
                    startDate: startDate,
                    endDate: endDate,
                    activityType: activityType,
                    hadColdShower: hadColdShower,
                    plannedDurationSeconds: plannedDurationSeconds
                )
            }
            clearWorkoutState()
            return currentMetricsSnapshot()
        }

        let coldShowerKey = Self.metadataColdShowerKey

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(average: Double, max: Double, activeCalories: Double, totalCalories: Double), Error>) in
            builder.endCollection(withEnd: endDate) { [weak self] _, endError in
                guard let self else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitManager",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Workout manager unavailable while finishing session."]
                    ))
                    return
                }
                if let endError {
                    if Self.isWorkoutAlreadyInactiveError(endError) {
                        Task { @MainActor in
                            if let startDate, let activityType {
                                try? await self.saveFallbackWorkout(
                                    startDate: startDate,
                                    endDate: endDate,
                                    activityType: activityType,
                                    hadColdShower: hadColdShower,
                                    plannedDurationSeconds: plannedDurationSeconds
                                )
                            }
                            self.clearWorkoutState()
                            continuation.resume(returning: self.currentMetricsSnapshot())
                        }
                        return
                    }
                    continuation.resume(throwing: endError)
                    return
                }

                builder.addMetadata([
                    coldShowerKey: hadColdShower,
                    HKMetadataKeyIndoorWorkout: true,
                    "com.heatload.plannedDurationSeconds": plannedDurationSeconds
                ]) { _, metadataError in
                    if let metadataError {
                        if Self.isWorkoutAlreadyInactiveError(metadataError) {
                            Task { @MainActor in
                                if let startDate, let activityType {
                                    try? await self.saveFallbackWorkout(
                                        startDate: startDate,
                                        endDate: endDate,
                                        activityType: activityType,
                                        hadColdShower: hadColdShower,
                                        plannedDurationSeconds: plannedDurationSeconds
                                    )
                                }
                                self.clearWorkoutState()
                                continuation.resume(returning: self.currentMetricsSnapshot())
                            }
                            return
                        }
                        continuation.resume(throwing: metadataError)
                        return
                    }

                    builder.finishWorkout { workout, finishError in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(throwing: NSError(
                                    domain: "HealthKitManager",
                                    code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "Workout manager unavailable after finishing session."]
                                ))
                                return
                            }

                            self.lastEndedWorkoutUUID = workout?.uuid
                            self.clearWorkoutState()

                            if let finishError {
                                if Self.isWorkoutAlreadyInactiveError(finishError) {
                                    if let startDate, let activityType {
                                        try? await self.saveFallbackWorkout(
                                            startDate: startDate,
                                            endDate: endDate,
                                            activityType: activityType,
                                            hadColdShower: hadColdShower,
                                            plannedDurationSeconds: plannedDurationSeconds
                                        )
                                    }
                                    continuation.resume(returning: self.currentMetricsSnapshot())
                                    return
                                }
                                continuation.resume(throwing: finishError)
                                return
                            }

                            continuation.resume(returning: self.currentMetricsSnapshot())
                        }
                    }
                }
            }
        }
    }

    private func waitForSessionToEnd(_ session: HKWorkoutSession, timeoutSeconds: Double = 18.0) async {
        if session.state == .ended { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if session.state == .ended {
                        continuation.resume()
                    } else {
                        self.pendingSessionEndWaiters.append(continuation)
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            }

            _ = await group.next()
            group.cancelAll()
        }
    }

    private func resumePendingSessionEndWaiters() {
        let waiters = pendingSessionEndWaiters
        pendingSessionEndWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func clearWorkoutState() {
        workoutSession = nil
        workoutBuilder = nil
        pendingSessionEndWaiters.removeAll()
    }

    private func startLiveMetricsPolling() {
        liveMetricsPollingTask?.cancel()
        liveMetricsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.refreshLiveMetricsFromBuilder()
            }
        }
    }

    private func refreshLiveMetricsFromBuilder() {
        guard let workoutBuilder else { return }

        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
           let statistics = workoutBuilder.statistics(for: heartRateType),
           let quantity = statistics.mostRecentQuantity() {
            let bpm = quantity.doubleValue(for: HKUnit(from: "count/min"))
            currentHeartRate = bpm

            if let last = lastPolledHeartRateBPM {
                if abs(last - bpm) >= 0.5 {
                    heartRateReadings.append(HeartRateReading(timestamp: Date(), bpm: bpm))
                    lastPolledHeartRateBPM = bpm
                }
            } else {
                heartRateReadings.append(HeartRateReading(timestamp: Date(), bpm: bpm))
                lastPolledHeartRateBPM = bpm
            }
        }

        let kcalUnit = HKUnit.kilocalorie()

        var active = currentActiveCalories
        if let activeType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
           let activeStats = workoutBuilder.statistics(for: activeType),
           let activeSum = activeStats.sumQuantity() {
            active = activeSum.doubleValue(for: kcalUnit)
        }

        var basal = 0.0
        if let basalType = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned),
           let basalStats = workoutBuilder.statistics(for: basalType),
           let basalSum = basalStats.sumQuantity() {
            basal = basalSum.doubleValue(for: kcalUnit)
        }

        currentActiveCalories = active
        currentTotalCalories = active + basal
    }

    private func currentMetricsSnapshot() -> (average: Double, max: Double, activeCalories: Double, totalCalories: Double) {
        let values = heartRateReadings.map(\.bpm)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let max = values.max() ?? 0
        return (avg, max, currentActiveCalories, currentTotalCalories)
    }

    private static func isWorkoutAlreadyInactiveError(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("not currently active")
            || message.contains("not currently ended")
            || message.contains("unable to end a workout")
            || message.contains("unable to finish a workout")
    }

    private func saveFallbackWorkout(
        startDate: Date,
        endDate: Date,
        activityType: HeatActivityType,
        hadColdShower: Bool,
        plannedDurationSeconds: Int
    ) async throws {
        let metadata: [String: Any] = [
            Self.metadataHeatActivityKey: activityType.rawValue,
            Self.metadataColdShowerKey: hadColdShower,
            "com.heatload.activityDisplayName": activityType.displayName,
            "com.heatload.plannedDurationSeconds": plannedDurationSeconds,
            HKMetadataKeyWorkoutBrandName: "Sauna Log \(activityType.displayName)",
            HKMetadataKeyIndoorWorkout: true
        ]

        let active = HKQuantity(unit: .kilocalorie(), doubleValue: currentActiveCalories)
        let total = HKQuantity(unit: .kilocalorie(), doubleValue: currentTotalCalories)

        let workout = HKWorkout(
            activityType: mappedWorkoutActivityType(for: activityType),
            start: startDate,
            end: endDate,
            workoutEvents: nil,
            totalEnergyBurned: total.doubleValue(for: .kilocalorie()) > 0 ? total : active,
            totalDistance: nil,
            metadata: metadata
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(workout) { [weak self] success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    Task { @MainActor in
                        self?.lastEndedWorkoutUUID = workout.uuid
                        continuation.resume(returning: ())
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "HealthKitManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unable to save fallback workout."]))
                }
            }
        }
    }

#elseif os(iOS)
    private let healthStore = HKHealthStore()

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let workoutType = HKObjectType.workoutType()
        try await healthStore.requestAuthorization(
            toShare: [workoutType],
            read: [workoutType]
        )
    }

    public func startWorkout(activityType: HeatActivityType, startDate: Date = Date()) async throws {}

    public func recoverActiveWorkoutSession(_ session: HKWorkoutSession) {}

    public func endWorkout(
        endDate: Date = Date(),
        hadColdShower: Bool,
        plannedDurationSeconds: Int
    ) async throws -> (average: Double, max: Double, activeCalories: Double, totalCalories: Double) {
        (0, 0, 0, 0)
    }

    public func fetchRecentSessions(limit: Int = 100) async throws -> [HeatSession] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }

        let workoutType = HKObjectType.workoutType()
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: nil,
                limit: max(1, limit * 3),
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                let sessions = workouts.compactMap { workout -> HeatSession? in
                    guard let metadata = workout.metadata else { return nil }
                    guard let activityRaw = metadata[Self.metadataHeatActivityKey] as? String,
                          let activityType = HeatActivityType(rawValue: activityRaw) else {
                        return nil
                    }

                    let hadColdShower = (metadata[Self.metadataColdShowerKey] as? Bool)
                        ?? (metadata[Self.metadataColdShowerKey] as? NSNumber)?.boolValue
                        ?? false

                    let plannedDuration = (metadata["com.heatload.plannedDurationSeconds"] as? Int)
                        ?? (metadata["com.heatload.plannedDurationSeconds"] as? NSNumber)?.intValue
                        ?? Int(workout.duration)

                    let total = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0

                    return HeatSession(
                        id: workout.uuid,
                        activityType: activityType,
                        startDate: workout.startDate,
                        endDate: workout.endDate,
                        hadColdShower: hadColdShower,
                        plannedDurationSeconds: max(0, plannedDuration),
                        averageHeartRate: 0,
                        maxHeartRate: 0,
                        activeCalories: total,
                        totalCalories: total
                    )
                }
                .sorted(by: { $0.endDate > $1.endDate })

                continuation.resume(returning: Array(sessions.prefix(limit)))
            }

            healthStore.execute(query)
        }
    }

    public func deleteSessionFromHealth(_ session: HeatSession) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        guard let match = try await findMatchingWorkout(for: session) else {
            throw NSError(
                domain: "HealthKitManager",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Matching Apple Health/Fitness workout was not found for this session."]
            )
        }

        try await deleteWorkout(match)

        // Validate deletion propagated to Health store (Fitness reads from same store).
        for _ in 0..<3 {
            if try await findMatchingWorkout(for: session) == nil {
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        throw NSError(
            domain: "HealthKitManager",
            code: 15,
            userInfo: [NSLocalizedDescriptionKey: "Workout still present in Apple Health after delete attempt."]
        )
    }

    private func findMatchingWorkout(for session: HeatSession) async throws -> HKWorkout? {
        let byIDPredicate = HKQuery.predicateForObject(with: session.id)
        if let exactByID = try await fetchWorkouts(predicate: byIDPredicate, limit: 1).first {
            return exactByID
        }

        let windowStart = session.startDate.addingTimeInterval(-900)
        let windowEnd = session.endDate.addingTimeInterval(900)
        let windowPredicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])
        let candidates = try await fetchWorkouts(predicate: windowPredicate, limit: 80)

        let appBundleID = (Bundle.main.bundleIdentifier ?? "").lowercased()
        let acceptedBundleIDs = Set([
            appBundleID,
            "\(appBundleID).watchkitapp",
            "com.barnabywood.saunalog",
            "com.barnabywood.saunalog.watchkitapp"
        ].filter { !$0.isEmpty })

        func score(_ workout: HKWorkout) -> Double {
            let startDelta = abs(workout.startDate.timeIntervalSince(session.startDate))
            let endDelta = abs(workout.endDate.timeIntervalSince(session.endDate))
            let durationDelta = abs(workout.duration - session.endDate.timeIntervalSince(session.startDate))
            return startDelta + endDelta + (durationDelta * 0.5)
        }

        if let exactMetadataMatch = candidates
            .filter({ workout in
                guard let metadata = workout.metadata,
                      let activityRaw = metadata[Self.metadataHeatActivityKey] as? String else { return false }
                return activityRaw == session.activityType.rawValue
            })
            .min(by: { score($0) < score($1) }) {
            return exactMetadataMatch
        }

        return candidates
            .filter { workout in
                let sourceBundle = workout.sourceRevision.source.bundleIdentifier.lowercased()
                return acceptedBundleIDs.contains(sourceBundle)
            }
            .min(by: { score($0) < score($1) })
    }

    private func fetchWorkouts(predicate: NSPredicate?, limit: Int) async throws -> [HKWorkout] {
        let workoutType = HKObjectType.workoutType()
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: max(1, limit),
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func deleteWorkout(_ workout: HKWorkout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.delete(workout) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(domain: "HealthKitManager", code: 13, userInfo: [NSLocalizedDescriptionKey: "Unable to delete workout from Health."]))
                }
            }
        }
    }

#else
    public func requestAuthorization() async throws {}

    public func startWorkout(activityType: HeatActivityType, startDate: Date = Date()) async throws {}

    public func recoverActiveWorkoutSession(_ session: HKWorkoutSession) {}

    public func endWorkout(
        endDate: Date = Date(),
        hadColdShower: Bool,
        plannedDurationSeconds: Int
    ) async throws -> (average: Double, max: Double, activeCalories: Double, totalCalories: Double) {
        (0, 0, 0, 0)
    }
#endif
}

#if os(watchOS)
extension HealthKitManager: HKWorkoutSessionDelegate {
    public func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        resumePendingSessionEndWaiters()
    }

    public func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended {
            resumePendingSessionEndWaiters()
        }
    }
}

extension HealthKitManager: HKLiveWorkoutBuilderDelegate {
    public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { [weak self] in
            self?.refreshLiveMetricsFromBuilder()
        }
    }
}
#endif
