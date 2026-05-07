import SwiftUI
import StoreKit
import UIKit
import WatchConnectivity

struct HomeView: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    @EnvironmentObject private var trial: TrialManager
    @EnvironmentObject private var purchase: PurchaseManager
    @EnvironmentObject private var store: SessionStore
    @StateObject private var health = HealthKitManager()

    @ObservedObject private var watchSync = WatchSyncManager.shared

    @State private var editingPresetIndex: Int?
    @State private var editingMinutesInput = ""
    @State private var showingSupport = false
@State private var pendingDeletionSession: HeatSession?
@State private var showingDeleteConfirmation = false
    @State private var deleteFailureMessage: String?
    @State private var hasCountedLaunch = false
    @AppStorage("ios.launchCount") private var launchCount = 0

    private let privacyPolicyURL = URL(string: "https://raw.githubusercontent.com/barnabywood/HeatLoad/main/privacy-policy.md")!
    private let contactURL = URL(string: "mailto:app.inventory.me@gmail.com?subject=Sauna%20Log%20Support")!
    private let featureRequestURL = URL(string: "mailto:app.inventory.me@gmail.com?subject=Sauna%20Log%20Feature%20Request")!
    private let appReviewURL = URL(string: "itms-apps://itunes.apple.com/app/viewContentsUserReviews/id6759159351?action=write-review")!

    private var watchReady: Bool {
        watchSync.isWatchReady
    }

    var body: some View {
        Group {
            if showingSupport {
                supportPage
            } else {
                mainPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !hasCountedLaunch {
                launchCount += 1
                hasCountedLaunch = true
            }
            watchSync.refreshStatus()
            maybePromptForReview()
            syncTrialStateToWatch()
            syncPresetStateToWatch()
            syncHeartRateAlertStateToWatch()
        }
        .onChange(of: trial.lifetimeSessionsCompleted) { _, _ in
            maybePromptForReview()
            syncTrialStateToWatch()
        }
        .onChange(of: trial.hasUnlocked) { _, _ in
            syncTrialStateToWatch()
        }
        .onChange(of: store.presets) { _, _ in
            syncPresetStateToWatch()
        }
        .onChange(of: store.selectedPresetSeconds) { _, _ in
            syncPresetStateToWatch()
        }
        .onChange(of: store.minHeartRateAlertBPM) { _, _ in
            syncHeartRateAlertStateToWatch()
        }
        .onChange(of: store.maxHeartRateAlertBPM) { _, _ in
            syncHeartRateAlertStateToWatch()
        }
        .alert("Edit Timer", isPresented: Binding(
            get: { editingPresetIndex != nil },
            set: { isPresented in
                if !isPresented {
                    editingPresetIndex = nil
                }
            }
        )) {
            TextField("Minutes", text: $editingMinutesInput)
                .keyboardType(.numberPad)

            Button("Save") {
                saveEditedPreset()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set the timer length in minutes.")
        }
        .alert("Delete Session?", isPresented: $showingDeleteConfirmation, presenting: pendingDeletionSession) { session in
            Button("Delete", role: .destructive) {
                Task {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.deleteSession(session)
                        }
                        pendingDeletionSession = nil
                    }

                    do {
                        try await health.requestAuthorization()
                        try await health.deleteSessionFromHealth(session)
                    } catch {
                        let nsError = error as NSError
                        await MainActor.run {
                            deleteFailureMessage = "Removed from Recent, but Apple Health delete failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletionSession = nil
            }
        } message: { session in
            Text("Remove this \(session.activityType.displayName.lowercased()) record from Recent and Apple Health?")
        }
        .alert("Delete Failed", isPresented: Binding(get: { deleteFailureMessage != nil }, set: { if !$0 { deleteFailureMessage = nil } })) {
            Button("OK", role: .cancel) {
                deleteFailureMessage = nil
            }
        } message: {
            Text(deleteFailureMessage ?? "")
        }
    }

    private var mainPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Spacer()

                    Button {
                        softTap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSupport = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(AppTheme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if !watchSync.isWatchAppInstalled {
                    watchStatusPanel
                }

                hero
                presetsPanel
                heartRateAlertsPanel

                if !trial.hasUnlocked {
                    trialPanel
                }

                sessionsPanel
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 8)
            .safeAreaPadding(.top, 56)
            .safeAreaPadding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollIndicators(.hidden)
    }

    private var supportPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        softTap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSupport = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(AppTheme.accentFont(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AppTheme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                supportPanel
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 8)
            .safeAreaPadding(.top, 56)
            .safeAreaPadding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollIndicators(.hidden)
    }

    private var watchStatusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(watchReady ? Color.green : AppTheme.ember)
                    .frame(width: 9, height: 9)

                Text(watchReady ? "Watch Ready" : "Watch Not Ready")
                    .font(AppTheme.accentFont(14))

                Spacer()
            }

            Text(watchStatusDetail)
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.84))
        }
        .panelStyle()
    }

    private var watchStatusDetail: String {
        guard WCSession.isSupported() else {
            return "Watch connectivity is not supported on this device."
        }

        if !watchSync.isPaired {
            return "No paired Apple Watch detected."
        }

        if !watchSync.isWatchAppInstalled {
            return "Sauna Log is not installed on your Apple Watch."
        }

        if !watchSync.isReachable {
            return "Watch app installed. Sessions sync back to iPhone automatically when connected."
        }

        return "Ready to sync sessions with your watch."
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sauna Log")
                .font(AppTheme.titleFont(36))
                .foregroundStyle(AppTheme.sand)

            Text("Track sauna or steam sessions on Apple Watch with timer presets, heart-rate capture, and Apple Health logging.")
                .font(AppTheme.bodyFont(14))
                .foregroundStyle(.white.opacity(0.94))
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    private var presetsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timers")
                    .font(AppTheme.accentFont(16))

                Spacer()

                Text(watchReady ? "Tap Timer to Edit" : "Install watch app to edit")
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 8) {
                ForEach(Array(store.presets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        beginEditingPreset(index: index)
                        softTap()
                    } label: {
                        Text(store.format(seconds: preset))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.steam)
                    .font(AppTheme.accentFont(14))
                    .disabled(!watchReady)
                }
            }
        }
        .panelStyle()
    }

    private var heartRateAlertsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart Rate Alerts")
                .font(AppTheme.accentFont(16))

            Toggle("Minimum Alert", isOn: minAlertEnabledBinding)
                .tint(AppTheme.steam)
                .font(AppTheme.bodyFont(14))

            if store.minHeartRateAlertBPM != nil {
                Stepper(value: minAlertValueBinding, in: 40...220, step: 1) {
                    Text("Min: \(store.minHeartRateAlertBPM ?? 90) bpm")
                        .font(AppTheme.bodyFont(13))
                }
            }

            Toggle("Maximum Alert", isOn: maxAlertEnabledBinding)
                .tint(AppTheme.steam)
                .font(AppTheme.bodyFont(14))

            if store.maxHeartRateAlertBPM != nil {
                Stepper(value: maxAlertValueBinding, in: 40...220, step: 1) {
                    Text("Max: \(store.maxHeartRateAlertBPM ?? 170) bpm")
                        .font(AppTheme.bodyFont(13))
                }
            }

            Text("Watch gives haptic alerts if heart rate goes outside your range.")
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.78))
        }
        .panelStyle()
    }

    private var minAlertEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.minHeartRateAlertBPM != nil },
            set: { enabled in
                softTap()
                store.setHeartRateAlerts(min: enabled ? (store.minHeartRateAlertBPM ?? 90) : nil, max: store.maxHeartRateAlertBPM)
            }
        )
    }

    private var maxAlertEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.maxHeartRateAlertBPM != nil },
            set: { enabled in
                softTap()
                store.setHeartRateAlerts(min: store.minHeartRateAlertBPM, max: enabled ? (store.maxHeartRateAlertBPM ?? 170) : nil)
            }
        )
    }

    private var minAlertValueBinding: Binding<Int> {
        Binding(
            get: { store.minHeartRateAlertBPM ?? 90 },
            set: { value in
                store.setHeartRateAlerts(min: value, max: store.maxHeartRateAlertBPM)
            }
        )
    }

    private var maxAlertValueBinding: Binding<Int> {
        Binding(
            get: { store.maxHeartRateAlertBPM ?? 170 },
            set: { value in
                store.setHeartRateAlerts(min: store.minHeartRateAlertBPM, max: value)
            }
        )
    }

    private var trialPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free Trial")
                .font(AppTheme.accentFont(16))

            Text("\(trial.remainingFreeSessions) of 3 left")
                .font(AppTheme.bodyFont(14))

            Text(trial.canStartSession ? "Unlock anytime" : "Unlock to continue")
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.82))

            if !watchReady {
                Text("Install Sauna Log on Apple Watch to start sessions. Purchase can be unlocked now.")
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 8) {
                Button("Unlock Now") {
                    softTap()
                    purchase.clearLastError()
                    Task {
                        if let product = purchase.products.first {
                            await purchase.purchase(product)
                        } else {
                            await purchase.purchaseFirstAvailableProduct()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ember)
                .font(AppTheme.accentFont(14))
                .disabled(purchase.isLoadingProducts)

                Button("Restore Purchase") {
                    softTap()
                    syncTrialStateToWatch()
                    Task { await purchase.restore() }
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.sand)
                .font(AppTheme.accentFont(14))
                .disabled(purchase.isLoadingProducts)
            }

            if purchase.isLoadingProducts {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Checking purchase availability…")
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            if let message = purchase.lastErrorMessage {
                Text(message)
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Retry") {
                        softTap()
                        Task { await purchase.loadProducts() }
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.steam)
                    .font(AppTheme.accentFont(12))

                    Button("Clear") {
                        softTap()
                        purchase.clearLastError()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.sand)
                    .font(AppTheme.accentFont(12))
                }
            }
        }
        .panelStyle()
    }

    private var supportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Support")
                .font(AppTheme.accentFont(16))

            LinkRow(title: "Privacy Policy", subtitle: "View", destination: privacyPolicyURL)
            LinkRow(title: "Contact / Feedback", subtitle: "app.inventory.me@gmail.com", destination: contactURL)
            LinkRow(title: "Request a Feature", subtitle: "Send idea", destination: featureRequestURL)

            VStack(alignment: .leading, spacing: 4) {
                Text("Watch Tip")
                    .font(AppTheme.accentFont(13))
                    .foregroundStyle(.white)
                Text("For faster return after alerts: Watch app on iPhone > General > Return to Clock > Sauna Log > Return to App.")
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                softTap()
                requestReview()
                openURL(appReviewURL)
            } label: {
                HStack {
                    Text("Leave a Review")
                        .font(AppTheme.accentFont(14))
                    Spacer()
                    Image(systemName: "star.bubble")
                        .foregroundStyle(AppTheme.sand)
                }
                .padding(10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .panelStyle()
    }

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(AppTheme.accentFont(16))

            if store.recentSessions.isEmpty {
                Text("Complete a watch session to see history")
                    .font(AppTheme.bodyFont(14))
                    .foregroundStyle(.white.opacity(0.84))
            } else {
                List {
                    ForEach(Array(store.recentSessions.prefix(10))) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(session.activityType.displayName) · \(session.actualDurationSeconds / 60)m")
                                .font(AppTheme.accentFont(14))
                            Text("Avg \(Int(session.averageHeartRate)) · Max \(Int(session.maxHeartRate))")
                                .font(AppTheme.bodyFont(12))
                                .foregroundStyle(.white.opacity(0.78))
                            Text("Active \(Int(session.activeCalories.rounded())) kcal · Total \(Int(session.totalCalories.rounded())) kcal · Cold " + (session.hadColdShower ? "Yes" : "No"))
                                .font(AppTheme.bodyFont(12))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                softTap()
                                pendingDeletionSession = session
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(false)
                .frame(height: min(CGFloat(store.recentSessions.count) * 96 + 8, 520))
                .background(Color.clear)
            }

            if !store.deletedSessions.isEmpty {
                Divider().overlay(.white.opacity(0.14))

                Text("Deleted Trace")
                    .font(AppTheme.accentFont(14))
                    .foregroundStyle(.white.opacity(0.86))

                ForEach(Array(store.deletedSessions.prefix(10))) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(session.activityType.displayName) · \(session.actualDurationSeconds / 60)m")
                            .font(AppTheme.accentFont(13))
                        Text("Avg \(Int(session.averageHeartRate)) · Max \(Int(session.maxHeartRate))")
                            .font(AppTheme.bodyFont(11))
                            .foregroundStyle(.white.opacity(0.72))
                        Text("Active \(Int(session.activeCalories.rounded())) kcal · Total \(Int(session.totalCalories.rounded())) kcal")
                            .font(AppTheme.bodyFont(11))
                            .foregroundStyle(.white.opacity(0.72))
                        Text("Removed from Recent (Health delete verified or attempted)")
                            .font(AppTheme.bodyFont(10))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .panelStyle()
    }

    private func beginEditingPreset(index: Int) {
        guard watchReady else { return }
        guard store.presets.indices.contains(index) else { return }
        editingPresetIndex = index
        editingMinutesInput = String(max(1, store.presets[index] / 60))
    }

    private func saveEditedPreset() {
        guard let index = editingPresetIndex else { return }
        guard let minutes = Int(editingMinutesInput), minutes > 0 else { return }

        if store.updatePreset(at: index, minutes: minutes) {
            syncPresetStateToWatch()
            softTap()
        }

        editingPresetIndex = nil
    }

    private func maybePromptForReview() {
        guard trial.shouldPromptForReview else { return }
        requestReview()
        trial.markReviewPromptShown()
        successTap()
    }

    private func syncTrialStateToWatch() {
        WatchSyncManager.shared.sendTrialProgress(
            sessionsCompleted: trial.sessionsCompleted,
            lifetimeSessionsCompleted: trial.lifetimeSessionsCompleted,
            hasUnlocked: trial.hasUnlocked
        )
    }

    private func syncPresetStateToWatch() {
        WatchSyncManager.shared.sendPresets(store.presets, selectedPresetSeconds: store.selectedPresetSeconds)
    }

    private func syncHeartRateAlertStateToWatch() {
        WatchSyncManager.shared.sendHeartRateAlerts(min: store.minHeartRateAlertBPM, max: store.maxHeartRateAlertBPM)
    }

    private func softTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func successTap() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

private struct LinkRow: View {
    let title: String
    let subtitle: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTheme.accentFont(14))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .foregroundStyle(AppTheme.sand)
            }
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private extension View {
    func panelStyle() -> some View {
        self
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
    }
}
