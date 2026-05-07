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

    var body: some View {
        ZStack {
            AppTheme.watchBackground.ignoresSafeArea()

            Group {
                if store.isSessionActive {
                    activeScreen
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
        }
        .onChange(of: health.currentHeartRate) { _, bpm in
            evaluateHeartRateAlerts(bpm)
        }
        .alert("Session", isPresented: Binding(get: { alertText != nil }, set: { _ in alertText = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        .confirmationDialog("Add more time", isPresented: $showingAddTimeOptions, titleVisibility: .visible) {
            ForEach(store.presets.prefix(4), id: \.self) { seconds in
                Button(store.format(seconds: seconds)) {
                    addMoreTime(seconds)
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how much time to add to this session.")
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

            activityButton(.sauna, symbol: "flame.fill", subtitle: "Dry heat", isPrimary: true)
            activityButton(.steamRoom, symbol: "drop.fill", subtitle: "Humid heat", isPrimary: false)

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
                label: trial.canStartSession ? "Slide to Start" : "Unlock on iPhone",
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

                compactPanel {
                    metricRow("HR", value: heartRateText)
                    metricRow("Active kcal", value: String(Int(health.currentActiveCalories.rounded())))
                    metricRow("Total kcal", value: String(Int(health.currentTotalCalories.rounded())))

                    Toggle("Cold Shower", isOn: $hadColdShower)
                        .tint(AppTheme.steam)
                        .foregroundStyle(.white)
                        .font(AppTheme.bodyFont(12))
                        .padding(.top, 1)

                    if store.countdownRemainingSeconds == 0 {
                        Button("Add more time") {
                            showingAddTimeOptions = true
                            WKInterfaceDevice.current().play(.click)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.steam)
                        .foregroundStyle(.white)
                        .font(AppTheme.accentFont(14))
                        .padding(.top, 1)
                    }
                }

                SlideToConfirm(
                    label: isEndingSession ? "Saving…" : "Slide to Stop",
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

    private var heartRateText: String {
        if let bpm = health.currentHeartRate {
            return "\(Int(bpm))"
        }
        return "--"
    }

    private func activityButton(_ type: HeatActivityType, symbol: String, subtitle: String, isPrimary: Bool) -> some View {
        Button {
            selectActivity(type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: isPrimary ? 17 : 15, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(type == .steamRoom ? "Steam Room" : "Sauna")
                        .font(AppTheme.accentFont(isPrimary ? 17 : 16))
                    Text(subtitle)
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.82))
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

    private func metricRow(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AppTheme.bodyFont(13))
                .foregroundStyle(.white.opacity(0.95))

            Spacer()

            Text(value)
                .font(AppTheme.accentFont(label == "HR" ? 24 : 19))
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

    private func startSession() {
        guard trial.canStartSession else {
            alertText = "Free trial complete. Unlock from iPhone to continue."
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
                alertText = "Could not start session. \(error.localizedDescription)"
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private func endSession() {
        guard !isEndingSession else { return }
        isEndingSession = true

        stopCompletionReminder(resetTrigger: true)
        cancelSessionEndAlert()

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
                        metrics: metrics
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
                        metrics: fallbackMetrics
                    )

                    alertText = "Saved session locally. Health write failed: \(error.localizedDescription)"
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
        metrics: (average: Double, max: Double, activeCalories: Double, totalCalories: Double)
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
            totalCalories: metrics.totalCalories
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
        content.title = "Session Complete"
        content.body = "Time is up. Leave heat or extend session."
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
                    title: "Low Heart Rate",
                    body: "HR \(Int(bpm.rounded())) bpm is below your minimum \(minBPM)."
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
                    title: "High Heart Rate",
                    body: "HR \(Int(bpm.rounded())) bpm is above your maximum \(maxBPM)."
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
