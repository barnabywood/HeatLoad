import SwiftUI
import WatchKit
import UserNotifications

struct WatchHomeView: View {
    private enum SetupPage: Int {
        case type
        case timer
    }

    @EnvironmentObject private var trial: TrialManager
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var health: HealthKitManager

    @State private var setupPage: SetupPage = .type
    @State private var hadColdShower = false
    @State private var alertText: String?
    @State private var completionReminderTask: Task<Void, Never>?
    @State private var didTriggerCompletionReminder = false
    @State private var isEndingSession = false
    @State private var lastMinHRAlertDate: Date?
    @State private var lastMaxHRAlertDate: Date?
    @State private var showingAddTimeOptions = false
    @State private var showingEnvironmentEditor = false
    @State private var editingTemperatureCelsius = 0.0
    @State private var editingHumidityPercent = 0.0

    var body: some View {
        ZStack {
            AppTheme.watchBackground.ignoresSafeArea()

            Group {
                if store.isSessionActive {
                    if showingEnvironmentEditor {
                        environmentEditorScreen
                    } else {
                        activeScreen
                    }
                } else {
                    setupFlow
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .onChange(of: store.countdownRemainingSeconds) { _, newValue in
            if store.isSessionActive && newValue == 0 {
                startCompletionReminderIfNeeded()
            } else if newValue > 0 {
                stopCompletionReminder(resetTrigger: true)
            }
        }
        .onChange(of: store.isSessionActive) { _, isActive in
            if !isActive {
                stopCompletionReminder(resetTrigger: true)
                setupPage = .type
                isEndingSession = false
            }
        }
        .onDisappear {
            stopCompletionReminder(resetTrigger: false)
        }
        .onAppear {
            requestNotificationAuthorizationIfNeeded()
            requestUnlockStateIfNeeded()
        }
        .onChange(of: trial.sessionsCompleted) { _, _ in
            requestUnlockStateIfNeeded()
        }
        .onChange(of: trial.hasUnlocked) { _, _ in
            requestUnlockStateIfNeeded()
        }
        .onChange(of: health.currentHeartRate) { _, bpm in
            evaluateHeartRateAlerts(bpm)
        }
        .alert(L10n.string("watch.alert.session_title"), isPresented: Binding(get: { alertText != nil }, set: { _ in alertText = nil })) {
            Button(L10n.string("actions.ok"), role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        .confirmationDialog(L10n.string("session.add_time.dialog_title"), isPresented: $showingAddTimeOptions, titleVisibility: .visible) {
            ForEach(store.presets.prefix(4), id: \.self) { seconds in
                Button(store.format(seconds: seconds)) {
                    addMoreTime(seconds)
                }
            }

            Button(L10n.string("actions.cancel"), role: .cancel) {}
        } message: {
            Text("session.add_time.dialog_message")
        }
    }

    private var setupFlow: some View {
        TabView(selection: $setupPage) {
            setupTypeScreen
                .tag(SetupPage.type)

            setupTimerScreen
                .tag(SetupPage.timer)
        }
        .tabViewStyle(.verticalPage)
        .animation(.easeInOut(duration: 0.15), value: setupPage)
    }

    private var setupTypeScreen: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 10)

            activityButton(.sauna, symbol: "flame.fill", subtitleKey: "activity.sauna.subtitle", isPrimary: true)
            activityButton(.steamRoom, symbol: "drop.fill", subtitleKey: "activity.steam_room.subtitle", isPrimary: false)

            Spacer(minLength: 6)
        }
    }

    private var setupTimerScreen: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 12)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(store.presets.prefix(4), id: \.self) { seconds in
                    Button(store.format(seconds: seconds)) {
                        store.setPreset(seconds)
                        WKInterfaceDevice.current().play(.click)
                    }
                    .buttonStyle(.plain)
                    .font(AppTheme.accentFont(17))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(store.selectedPresetSeconds == seconds ? AppTheme.steam.opacity(0.82) : AppTheme.card.opacity(0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(store.selectedPresetSeconds == seconds ? AppTheme.steam.opacity(0.95) : AppTheme.hairline, lineWidth: store.selectedPresetSeconds == seconds ? 1.6 : 1)
                            )
                    )
                    .foregroundStyle(.white)
                }
            }
            SlideToConfirm(
                label: trial.canStartSession ? L10n.string("session.start_slider") : L10n.string("session.unlock_on_iphone"),
                tint: AppTheme.sand,
                enabled: trial.canStartSession
            ) {
                startSession()
            }
            .padding(.bottom, 6)

            Spacer(minLength: 6)
        }
    }

    private var activeScreen: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                compactPanel {
                    Text(store.format(seconds: store.countdownRemainingSeconds))
                        .font(AppTheme.titleFont(40))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.sand)
                        .frame(maxWidth: .infinity)
                        .minimumScaleFactor(0.7)
                }

                guidancePanel

                compactPanel {
                    metricRow("metric.heart_rate.short", value: heartRateText)
                    metricRow("metric.active_calories", value: String(Int(health.currentActiveCalories.rounded())))
                    metricRow("metric.total_calories", value: String(Int(health.currentTotalCalories.rounded())))

                    Button {
                        beginEnvironmentEditing()
                    } label: {
                        HStack {
                            Text(L10n.string("session.heat_conditions"))
                            Spacer()
                            Text(environmentSummary)
                                .foregroundStyle(.white.opacity(0.76))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.steam)
                        }
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(AppTheme.steam.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(AppTheme.steam.opacity(0.62), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Toggle(L10n.string("session.cold_shower"), isOn: $hadColdShower)
                        .tint(AppTheme.steam)
                        .foregroundStyle(.white)
                        .font(AppTheme.bodyFont(12))
                        .lineLimit(2)
                        .padding(.top, 1)

                    if store.countdownRemainingSeconds == 0 {
                        Button(L10n.string("session.add_time.button")) {
                            showingAddTimeOptions = true
                            WKInterfaceDevice.current().play(.click)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.steam)
                        .foregroundStyle(.white)
                        .font(AppTheme.accentFont(14))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .padding(.top, 1)
                    }
                }

                SlideToConfirm(
                    label: isEndingSession ? L10n.string("session.saving") : L10n.string("session.stop_slider"),
                    tint: AppTheme.sand,
                    enabled: !isEndingSession
                ) {
                    endSession()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }

    private var environmentEditorScreen: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        showingEnvironmentEditor = false
                        WKInterfaceDevice.current().play(.click)
                    } label: {
                        Label(L10n.string("actions.cancel"), systemImage: "chevron.left")
                            .font(AppTheme.bodyFont(13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.84))

                    Spacer()

                    Text(L10n.string("session.heat_conditions"))
                        .font(AppTheme.accentFont(16))
                        .foregroundStyle(AppTheme.sand)
                }

                Text(L10n.string("session.heat_conditions.detail"))
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                compactPanel {
                    Stepper(value: $editingTemperatureCelsius, in: 0...120, step: 1) {
                        environmentStepperLabel(
                            titleKey: "session.temperature",
                            value: "\(Int(editingTemperatureCelsius.rounded()))°C"
                        )
                    }

                    Stepper(value: $editingHumidityPercent, in: 0...100, step: 1) {
                        environmentStepperLabel(
                            titleKey: "session.humidity",
                            value: "\(Int(editingHumidityPercent.rounded()))%"
                        )
                    }
                }

                Button(L10n.string("actions.save")) {
                    store.updateEnvironment(
                        temperatureCelsius: editingTemperatureCelsius,
                        humidityPercent: editingHumidityPercent,
                        rememberFor: store.selectedActivity
                    )
                    showingEnvironmentEditor = false
                    WKInterfaceDevice.current().play(.success)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.steam)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            editingTemperatureCelsius = store.currentTemperatureCelsius ?? store.environmentalDefaults(for: store.selectedActivity).temperatureCelsius
            editingHumidityPercent = store.currentHumidityPercent ?? store.environmentalDefaults(for: store.selectedActivity).humidityPercent
        }
    }

    private var heartRateText: String {
        if let bpm = health.currentHeartRate {
            return "\(Int(bpm))"
        }
        return "--"
    }

    private var environmentSummary: String {
        let temperature = store.currentTemperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? "--"
        let humidity = store.currentHumidityPercent.map { "\(Int($0.rounded()))%" } ?? "--"
        return "\(temperature) · \(humidity)"
    }

    private func beginEnvironmentEditing() {
        editingTemperatureCelsius = store.currentTemperatureCelsius ?? store.environmentalDefaults(for: store.selectedActivity).temperatureCelsius
        editingHumidityPercent = store.currentHumidityPercent ?? store.environmentalDefaults(for: store.selectedActivity).humidityPercent
        showingEnvironmentEditor = true
        WKInterfaceDevice.current().play(.click)
    }

    private func environmentStepperLabel(titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.string(titleKey))
                .font(AppTheme.bodyFont(11))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            Text(value)
                .font(AppTheme.accentFont(20))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var guidancePanel: some View {
        let guidance = currentGuidance

        return compactPanel {
            HStack(spacing: 8) {
                Circle()
                    .fill(guidance.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string(guidance.titleKey))
                        .font(AppTheme.accentFont(17))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(L10n.string(guidance.detailKey))
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 2)
            }
        }
    }

    private var currentGuidance: WatchGuidance {
        let planned = max(60, store.currentPlannedDurationSeconds)
        let elapsed = max(0, planned - store.countdownRemainingSeconds)
        let progress = Double(elapsed) / Double(planned)

        guard let bpm = health.currentHeartRate else {
            return .warmingUp
        }

        if let maxBPM = store.maxHeartRateAlertBPM, Int(bpm.rounded()) >= maxBPM {
            return .highStrain
        }

        let typicalHeartRate = recentTypicalHeartRate
        if typicalHeartRate.map({ bpm >= $0 * 1.12 }) ?? false {
            return .aboveUsual
        }

        if typicalHeartRate.map({ bpm <= $0 * 0.90 }) ?? false {
            return .belowUsual
        }

        if typicalHeartRate.map({ bpm >= $0 * 1.05 }) ?? false {
            return .building
        }

        if progress >= 0.85 {
            return .coolDownSoon
        }

        if progress < 0.2 {
            return .settlingIn
        }

        return .steady
    }

    private var recentTypicalHeartRate: Double? {
        let values = store.recentSessions
            .filter { $0.activityType == store.selectedActivity && $0.averageHeartRate > 0 }
            .prefix(5)
            .map(\.averageHeartRate)

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func activityButton(_ type: HeatActivityType, symbol: String, subtitleKey: String, isPrimary: Bool) -> some View {
        Button {
            selectActivity(type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: isPrimary ? 17 : 15, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(type.displayName)
                        .font(AppTheme.accentFont(isPrimary ? 17 : 16))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(L10n.string(subtitleKey))
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isPrimary ? 16 : 14)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(store.selectedActivity == type ? AppTheme.steam.opacity(0.82) : AppTheme.card.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(store.selectedActivity == type ? AppTheme.steam.opacity(0.95) : AppTheme.hairline, lineWidth: store.selectedActivity == type ? 1.6 : 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func metricRow(_ labelKey: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(L10n.string(labelKey))
                .font(AppTheme.bodyFont(13))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Spacer()

            Text(value)
                .font(AppTheme.accentFont(labelKey == "metric.heart_rate.short" ? 24 : 19))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    private func addMoreTime(_ seconds: Int) {
        store.addTime(seconds)
        scheduleSessionEndAlert(after: max(1, store.countdownRemainingSeconds))
        WKInterfaceDevice.current().play(.success)
    }

    private func compactPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppTheme.card.opacity(0.94), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    private func selectActivity(_ type: HeatActivityType) {
        store.selectedActivity = type
        WKInterfaceDevice.current().play(.click)
        withAnimation(.easeInOut(duration: 0.12)) {
            setupPage = .timer
        }
    }

    private func startCompletionReminderIfNeeded() {
        guard completionReminderTask == nil, !didTriggerCompletionReminder else { return }
        didTriggerCompletionReminder = true

        completionReminderTask = Task { @MainActor in
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)

            while !Task.isCancelled && store.isSessionActive && store.countdownRemainingSeconds == 0 {
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                guard !Task.isCancelled, store.isSessionActive, store.countdownRemainingSeconds == 0 else { break }
                WKInterfaceDevice.current().play(.notification)
            }

            completionReminderTask = nil
        }
    }

    private func stopCompletionReminder(resetTrigger: Bool) {
        completionReminderTask?.cancel()
        completionReminderTask = nil
        if resetTrigger {
            didTriggerCompletionReminder = false
        }
    }

    private func requestUnlockStateIfNeeded() {
        guard !trial.canStartSession else { return }
        WatchSyncManager.shared.requestTrialProgressSync()
    }

    private func startSession() {
        guard trial.canStartSession else {
            requestUnlockStateIfNeeded()
            alertText = L10n.string("trial.watch_complete")
            WKInterfaceDevice.current().play(.failure)
            return
        }

        stopCompletionReminder(resetTrigger: true)

        Task { @MainActor in
            do {
                try await health.requestAuthorization()
                try await health.startWorkout(activityType: store.selectedActivity)
                store.startSession()
                self.hadColdShower = false
                isEndingSession = false
                lastMinHRAlertDate = nil
                lastMaxHRAlertDate = nil
                scheduleSessionEndAlert(after: store.selectedPresetSeconds)
                WKInterfaceDevice.current().play(.start)
            } catch {
                alertText = L10n.format("session.error.start_failed", error.localizedDescription)
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private func endSession() {
        guard !isEndingSession else { return }
        isEndingSession = true

        stopCompletionReminder(resetTrigger: true)
        cancelSessionEndAlert()

        let sessionTemperature = store.currentTemperatureCelsius
        let sessionHumidity = store.currentHumidityPercent
        let environmentWasDefault = !store.currentEnvironmentWasEdited

        store.stopSession { start in
            let end = Date()
            let selectedActivity = store.selectedActivity
            let plannedDuration = store.currentPlannedDurationSeconds
            let hadShower = hadColdShower

            Task { @MainActor in
                do {
                    let metrics = try await health.endWorkout(
                        endDate: end,
                        hadColdShower: hadShower,
                        plannedDurationSeconds: plannedDuration,
                        startDate: start,
                        activityType: selectedActivity
                    )

                    finalizeEndedSession(
                        start: start,
                        end: end,
                        activityType: selectedActivity,
                        hadColdShower: hadShower,
                        plannedDurationSeconds: plannedDuration,
                        metrics: metrics,
                        temperatureCelsius: sessionTemperature,
                        humidityPercent: sessionHumidity,
                        environmentWasDefault: environmentWasDefault
                    )
                } catch {
                    let fallbackMetrics = (
                        average: health.currentHeartRate ?? 0,
                        max: health.currentHeartRate ?? 0,
                        activeCalories: health.currentActiveCalories,
                        totalCalories: health.currentTotalCalories
                    )

                    finalizeEndedSession(
                        start: start,
                        end: end,
                        activityType: selectedActivity,
                        hadColdShower: hadShower,
                        plannedDurationSeconds: plannedDuration,
                        metrics: fallbackMetrics,
                        temperatureCelsius: sessionTemperature,
                        humidityPercent: sessionHumidity,
                        environmentWasDefault: environmentWasDefault
                    )

                    alertText = L10n.format("session.error.saved_health_failed", error.localizedDescription)
                }
            }
            return nil
        }
    }

    private func finalizeEndedSession(
        start: Date,
        end: Date,
        activityType: HeatActivityType,
        hadColdShower: Bool,
        plannedDurationSeconds: Int,
        metrics: (average: Double, max: Double, activeCalories: Double, totalCalories: Double),
        temperatureCelsius: Double?,
        humidityPercent: Double?,
        environmentWasDefault: Bool
    ) {
        let session = HeatSession(
            id: health.lastEndedWorkoutUUID ?? UUID(),
            activityType: activityType,
            startDate: start,
            endDate: end,
            hadColdShower: hadColdShower,
            plannedDurationSeconds: plannedDurationSeconds,
            averageHeartRate: metrics.average,
            maxHeartRate: metrics.max,
            activeCalories: metrics.activeCalories,
            totalCalories: metrics.totalCalories,
            temperatureCelsius: temperatureCelsius,
            humidityPercent: humidityPercent,
            environmentWasDefault: environmentWasDefault
        )

        store.addSession(session)
        WatchSyncManager.shared.send(session: session)
        trial.recordCompletedSession()
        WatchSyncManager.shared.sendTrialProgress(
            sessionsCompleted: trial.sessionsCompleted,
            lifetimeSessionsCompleted: trial.lifetimeSessionsCompleted,
            hasUnlocked: trial.hasUnlocked
        )

        self.hadColdShower = false
        isEndingSession = false
        WKInterfaceDevice.current().play(.success)
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func scheduleSessionEndAlert(after seconds: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["heat.session.end"])

        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("notification.session_complete.title")
        content.body = L10n.string("notification.session_complete.body")
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: "heat.session.end", content: content, trigger: trigger)
        center.add(request)
    }

    private func cancelSessionEndAlert() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["heat.session.end"])
    }

    private func evaluateHeartRateAlerts(_ bpm: Double?) {
        guard store.isSessionActive, let bpm else { return }

        let now = Date()
        let cooldown: TimeInterval = 45

        if let minBPM = store.minHeartRateAlertBPM, Int(bpm.rounded()) <= minBPM {
            if let last = lastMinHRAlertDate, now.timeIntervalSince(last) < cooldown {
                // cooldown active
            } else {
                lastMinHRAlertDate = now
                pushHeartRateAlert(
                    title: L10n.string("notification.low_hr.title"),
                    body: L10n.format("notification.low_hr.body", Int(bpm.rounded()), minBPM)
                )
                WKInterfaceDevice.current().play(.directionDown)
            }
        }

        if let maxBPM = store.maxHeartRateAlertBPM, Int(bpm.rounded()) >= maxBPM {
            if let last = lastMaxHRAlertDate, now.timeIntervalSince(last) < cooldown {
                // cooldown active
            } else {
                lastMaxHRAlertDate = now
                pushHeartRateAlert(
                    title: L10n.string("notification.high_hr.title"),
                    body: L10n.format("notification.high_hr.body", Int(bpm.rounded()), maxBPM)
                )
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private func pushHeartRateAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let id = "heat.hr.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

}

private struct SlideToConfirm: View {
    let label: String
    let tint: Color
    var enabled: Bool = true
    let onConfirm: () -> Void

    @State private var knobOffset: CGFloat = 0
    @State private var didConfirm = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobSize: CGFloat = 28
            let maxOffset = max(0, width - knobSize)
            let autoCompleteThreshold = maxOffset * 0.5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.card.opacity(0.96))

                Capsule()
                    .fill(tint.opacity(0.3))
                    .frame(width: knobSize + knobOffset)

                Text(label)
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.6))
                    .frame(maxWidth: .infinity)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .offset(x: knobOffset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        guard !didConfirm else { return }

                        knobOffset = min(max(0, value.translation.width), maxOffset)

                        if knobOffset >= autoCompleteThreshold {
                            didConfirm = true
                            withAnimation(.easeOut(duration: 0.08)) {
                                knobOffset = maxOffset
                            }
                            onConfirm()
                            resetSliderAfterConfirmation()
                        }
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        guard !didConfirm else { return }

                        if knobOffset >= autoCompleteThreshold {
                            didConfirm = true
                            withAnimation(.easeOut(duration: 0.08)) {
                                knobOffset = maxOffset
                            }
                            onConfirm()
                            resetSliderAfterConfirmation()
                            return
                        }

                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            knobOffset = 0
                        }
                    }
            )
            .opacity(enabled ? 1 : 0.6)
        }
        .frame(height: 36)
    }

    private func resetSliderAfterConfirmation() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                knobOffset = 0
            }
            didConfirm = false
        }
    }
}


private enum WatchGuidance {
    case warmingUp
    case settlingIn
    case building
    case steady
    case aboveUsual
    case belowUsual
    case highStrain
    case coolDownSoon

    var titleKey: String {
        switch self {
        case .warmingUp: return "guidance.warming_up.title"
        case .settlingIn: return "guidance.settling_in.title"
        case .building: return "guidance.building.title"
        case .steady: return "guidance.steady.title"
        case .aboveUsual: return "guidance.above_usual.title"
        case .belowUsual: return "guidance.below_usual.title"
        case .highStrain: return "guidance.high_strain.title"
        case .coolDownSoon: return "guidance.cool_down_soon.title"
        }
    }

    var detailKey: String {
        switch self {
        case .warmingUp: return "guidance.warming_up.detail"
        case .settlingIn: return "guidance.settling_in.detail"
        case .building: return "guidance.building.detail"
        case .steady: return "guidance.steady.detail"
        case .aboveUsual: return "guidance.above_usual.detail"
        case .belowUsual: return "guidance.below_usual.detail"
        case .highStrain: return "guidance.high_strain.detail"
        case .coolDownSoon: return "guidance.cool_down_soon.detail"
        }
    }

    var color: Color {
        switch self {
        case .warmingUp, .settlingIn: return AppTheme.sand
        case .building: return AppTheme.steam
        case .steady: return AppTheme.steam
        case .aboveUsual: return AppTheme.ember
        case .belowUsual: return AppTheme.sand
        case .highStrain: return AppTheme.ember
        case .coolDownSoon: return Color.yellow.opacity(0.95)
        }
    }
}
