import SwiftUI
import Charts
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
    @State private var showingInsights = false
    @State private var selectedInsightScale: InsightScale = .month
    @State private var pendingDeletionSession: HeatSession?
    @State private var showingDeleteConfirmation = false
    @State private var deleteFailureMessage: String?
    @State private var hasCountedLaunch = false
    @AppStorage("ios.launchCount") private var launchCount = 0

    private let appReviewURL = URL(string: "itms-apps://itunes.apple.com/app/viewContentsUserReviews/id6759159351?action=write-review")!

    private var privacyPolicyURL: URL {
        URL(string: L10n.string("support.privacy_policy_url"))
            ?? URL(string: "https://barnabywood.github.io/HeatLoad/privacy-policy.html")!
    }

    private var contactURL: URL {
        mailURL(subjectKey: "support.email.subject")
    }

    private var featureRequestURL: URL {
        mailURL(subjectKey: "support.feature_request.subject")
    }

    private var watchReady: Bool {
        watchSync.isWatchReady
    }

    var body: some View {
        Group {
            if showingSupport {
                supportPage
            } else if showingInsights {
                insightsPage
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
            scheduleWatchInstallReminderIfNeeded()
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
        .onChange(of: watchSync.isPaired) { _, _ in
            scheduleWatchInstallReminderIfNeeded()
        }
        .onChange(of: watchSync.isWatchAppInstalled) { _, _ in
            scheduleWatchInstallReminderIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: SaunaLogLocalNotificationManager.routeNotificationName)) { notification in
            guard let route = notification.object as? SaunaLogLocalNotificationManager.Route else { return }
            handleNotificationRoute(route)
        }
        .alert(L10n.string("timer.edit.alert_title"), isPresented: Binding(
            get: { editingPresetIndex != nil },
            set: { isPresented in
                if !isPresented {
                    editingPresetIndex = nil
                }
            }
        )) {
            TextField(L10n.string("timer.edit.minutes_placeholder"), text: $editingMinutesInput)
                .keyboardType(.numberPad)

            Button(L10n.string("actions.save")) {
                saveEditedPreset()
            }

            Button(L10n.string("actions.cancel"), role: .cancel) {}
        } message: {
            Text("timer.edit.message")
        }
        .alert(L10n.string("history.delete.alert_title"), isPresented: $showingDeleteConfirmation, presenting: pendingDeletionSession) { session in
            Button(L10n.string("actions.delete"), role: .destructive) {
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
                            deleteFailureMessage = L10n.format(
                                "history.delete.health_failed",
                                nsError.domain,
                                nsError.code,
                                nsError.localizedDescription
                            )
                        }
                    }
                }
            }
            Button(L10n.string("actions.cancel"), role: .cancel) {
                pendingDeletionSession = nil
            }
        } message: { session in
            Text(L10n.format("history.delete.message", session.activityType.displayName.lowercased()))
        }
        .alert(L10n.string("history.delete.failed_title"), isPresented: Binding(get: { deleteFailureMessage != nil }, set: { if !$0 { deleteFailureMessage = nil } })) {
            Button(L10n.string("actions.ok"), role: .cancel) {
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
                            showingInsights = true
                        }
                    } label: {
                        Label(L10n.string("insights.open_button"), systemImage: "chart.xyaxis.line")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(AppTheme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("insights.open_button"))

                    Button {
                        softTap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSupport = true
                        }
                    } label: {
                        Label(L10n.string("support.settings_button"), systemImage: "gearshape")
                            .labelStyle(.iconOnly)
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

    private var insightsPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        softTap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingInsights = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("support.back")
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

                insightsHeaderPanel
                insightScalePicker
                insightsSummaryPanel
                heatTimeChartPanel
                durationTrendChartPanel
                heatMixPanel
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
                            Text("support.back")
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

                Text(watchReady ? L10n.string("watch.status.ready") : L10n.string("watch.status.not_ready"))
                    .font(AppTheme.accentFont(14))
                    .lineLimit(2)

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
            return L10n.string("watch.status.unsupported")
        }

        if !watchSync.isPaired {
            return L10n.string("watch.status.not_paired")
        }

        if !watchSync.isWatchAppInstalled {
            return L10n.string("watch.status.not_installed")
        }

        if !watchSync.isReachable {
            return L10n.string("watch.status.offline_sync")
        }

        return L10n.string("watch.status.ready_detail")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("app.name")
                .font(AppTheme.titleFont(36))
                .foregroundStyle(AppTheme.sand)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Text("home.hero.subtitle")
                .font(AppTheme.bodyFont(14))
                .foregroundStyle(.white.opacity(0.94))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("timer.section_title")
                    .font(AppTheme.accentFont(16))

                Spacer()

                Text(watchReady ? L10n.string("timer.edit_hint") : L10n.string("timer.edit_disabled_hint"))
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ForEach(Array(store.presets.enumerated()), id: \.offset) { index, preset in
                    Button {
                        beginEditingPreset(index: index)
                        softTap()
                    } label: {
                        Text(store.format(seconds: preset))
                            .frame(maxWidth: .infinity)
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
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
            Text("heart_rate.section_title")
                .font(AppTheme.accentFont(16))

            Toggle(L10n.string("heart_rate.minimum_alert"), isOn: minAlertEnabledBinding)
                .tint(AppTheme.steam)
                .font(AppTheme.bodyFont(14))
                .fixedSize(horizontal: false, vertical: true)

            if store.minHeartRateAlertBPM != nil {
                Stepper(value: minAlertValueBinding, in: 40...220, step: 1) {
                    Text(L10n.format("heart_rate.min_value", store.minHeartRateAlertBPM ?? 90))
                        .font(AppTheme.bodyFont(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(L10n.string("heart_rate.maximum_alert"), isOn: maxAlertEnabledBinding)
                .tint(AppTheme.steam)
                .font(AppTheme.bodyFont(14))
                .fixedSize(horizontal: false, vertical: true)

            if store.maxHeartRateAlertBPM != nil {
                Stepper(value: maxAlertValueBinding, in: 40...220, step: 1) {
                    Text(L10n.format("heart_rate.max_value", store.maxHeartRateAlertBPM ?? 170))
                        .font(AppTheme.bodyFont(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("heart_rate.help")
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
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
            Text("trial.section_title")
                .font(AppTheme.accentFont(16))

            Text(L10n.format("trial.remaining", trial.remainingFreeSessions))
                .font(AppTheme.bodyFont(14))

            Text(trial.canStartSession ? L10n.string("trial.unlock_anytime") : L10n.string("trial.unlock_to_continue"))
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            if !watchReady {
                Text("trial.watch_required")
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    unlockButton
                    restoreButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    unlockButton
                    restoreButton
                }
            }

            if purchase.isLoadingProducts {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("purchase.loading")
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message = purchase.lastErrorMessage {
                Text(message)
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("actions.retry") {
                        softTap()
                        Task { await purchase.loadProducts() }
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.steam)
                    .font(AppTheme.accentFont(12))

                    Button("actions.clear") {
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

    private var unlockButton: some View {
        Button("trial.unlock_now") {
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
        .fixedSize(horizontal: false, vertical: true)
    }

    private var restoreButton: some View {
        Button("trial.restore_purchase") {
            softTap()
            Task {
                await purchase.restore()
                syncTrialStateToWatch()
            }
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.sand)
        .font(AppTheme.accentFont(14))
        .disabled(purchase.isLoadingProducts)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var supportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("support.section_title")
                .font(AppTheme.accentFont(16))

            LinkRow(titleKey: "support.privacy_policy", subtitleKey: "support.view", destination: privacyPolicyURL)
            LinkRow(titleKey: "support.contact_feedback", subtitle: "app.inventory.me@gmail.com", destination: contactURL)
            LinkRow(titleKey: "support.request_feature", subtitleKey: "support.send_idea", destination: featureRequestURL)

            Button {
                softTap()
                Task {
                    await purchase.refreshEntitlements()
                    syncTrialStateToWatch()
                }
            } label: {
                HStack {
                    Text("support.sync_unlock_watch")
                        .font(AppTheme.accentFont(14))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .foregroundStyle(AppTheme.steam)
                }
                .padding(10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(purchase.isLoadingProducts)

            VStack(alignment: .leading, spacing: 4) {
                Text("support.watch_tip.title")
                    .font(AppTheme.accentFont(13))
                    .foregroundStyle(.white)
                Text("support.watch_tip.body")
                    .font(AppTheme.bodyFont(12))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                softTap()
                requestReview()
                openURL(appReviewURL)
            } label: {
                HStack {
                    Text("support.leave_review")
                        .font(AppTheme.accentFont(14))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "star.bubble")
                        .foregroundStyle(AppTheme.sand)
                }
                .padding(10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(appVersionText)
                .font(AppTheme.bodyFont(11))
                .foregroundStyle(.white.opacity(0.58))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .panelStyle()
    }

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("history.section_title")
                .font(AppTheme.accentFont(16))

            if store.recentSessions.isEmpty {
                Text("history.empty")
                    .font(AppTheme.bodyFont(14))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List {
                    ForEach(Array(store.recentSessions.prefix(10))) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.format("history.row.title", session.activityType.displayName, session.actualDurationSeconds / 60))
                                .font(AppTheme.accentFont(14))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.format("history.row.heart_rate", Int(session.averageHeartRate), Int(session.maxHeartRate)))
                                .font(AppTheme.bodyFont(12))
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.format(
                                "history.row.energy_cold",
                                Int(session.activeCalories.rounded()),
                                Int(session.totalCalories.rounded()),
                                session.hadColdShower ? L10n.string("common.yes") : L10n.string("common.no")
                            ))
                                .font(AppTheme.bodyFont(12))
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
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
                                Label(L10n.string("actions.delete"), systemImage: "trash")
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

                Text("history.deleted_trace.title")
                    .font(AppTheme.accentFont(14))
                    .foregroundStyle(.white.opacity(0.86))

                ForEach(Array(store.deletedSessions.prefix(10))) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("history.row.title", session.activityType.displayName, session.actualDurationSeconds / 60))
                            .font(AppTheme.accentFont(13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.format("history.row.heart_rate", Int(session.averageHeartRate), Int(session.maxHeartRate)))
                            .font(AppTheme.bodyFont(11))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.format("history.row.energy", Int(session.activeCalories.rounded()), Int(session.totalCalories.rounded())))
                            .font(AppTheme.bodyFont(11))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("history.deleted_trace.note")
                            .font(AppTheme.bodyFont(10))
                            .foregroundStyle(.orange.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .panelStyle()
    }


    private var insightsHeaderPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("insights.section_title")
                .font(AppTheme.titleFont(30))
                .foregroundStyle(AppTheme.sand)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Text("insights.subtitle")
                .font(AppTheme.bodyFont(13))
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }

    private var insightScalePicker: some View {
        Picker(L10n.string("insights.scale.picker"), selection: $selectedInsightScale) {
            ForEach(InsightScale.displayOrder) { scale in
                Text(L10n.string(scale.titleKey)).tag(scale)
            }
        }
        .pickerStyle(.segmented)
        .tint(AppTheme.steam)
        .accessibilityLabel(Text("insights.scale.picker"))
    }

    private var insightsSummaryPanel: some View {
        let summary = insightSummary

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            InsightMetricCard(titleKey: "insights.metric.total_heat", value: formatMinutes(summary.totalHeatMinutes))
            InsightMetricCard(titleKey: "insights.metric.heat_per_day", value: formatMinutes(summary.heatMinutesPerDay))
            InsightMetricCard(titleKey: "insights.metric.sessions", value: "\(summary.sessions)")
            InsightMetricCard(titleKey: "insights.metric.average_hr", value: summary.averageHeartRate > 0 ? L10n.format("insights.value.bpm", summary.averageHeartRate) : L10n.string("insights.value.no_data"))
        }
        .panelStyle()
    }

    private var heatTimeChartPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("insights.chart.heat_time", L10n.string(selectedInsightScale.bucketTitleKey).lowercased()))
                .font(AppTheme.accentFont(16))

            if heatTimeRows.isEmpty {
                insightEmptyText
            } else {
                Chart(heatTimeRows) { row in
                    BarMark(
                        x: .value(L10n.string(selectedInsightScale.bucketAxisKey), row.label),
                        y: .value(L10n.string("insights.axis.minutes"), row.minutes)
                    )
                    .foregroundStyle(AppTheme.steam.gradient)
                    .cornerRadius(5)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.12))
                        AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 190)
            }
        }
        .panelStyle()
    }

    private var durationTrendChartPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("insights.chart.duration_trend")
                .font(AppTheme.accentFont(16))

            if durationTrendRows.count < 2 {
                insightEmptyText
            } else {
                Chart(durationTrendRows) { row in
                    LineMark(
                        x: .value(L10n.string(selectedInsightScale.bucketAxisKey), row.label),
                        y: .value(L10n.string("insights.axis.minutes"), row.averageMinutes)
                    )
                    .foregroundStyle(AppTheme.ember)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value(L10n.string(selectedInsightScale.bucketAxisKey), row.label),
                        y: .value(L10n.string("insights.axis.minutes"), row.averageMinutes)
                    )
                    .foregroundStyle(AppTheme.sand)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.12))
                        AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 190)
            }
        }
        .panelStyle()
    }

    private var heatMixPanel: some View {
        let mix = heatMix
        let total = max(1, mix.sauna + mix.steam)
        let saunaRatio = CGFloat(mix.sauna) / CGFloat(total)
        let steamRatio = CGFloat(mix.steam) / CGFloat(total)

        return VStack(alignment: .leading, spacing: 10) {
            Text("insights.chart.heat_mix")
                .font(AppTheme.accentFont(16))

            if mix.sauna + mix.steam == 0 {
                insightEmptyText
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(AppTheme.ember.gradient)
                            .frame(width: proxy.size.width * saunaRatio)
                        Rectangle()
                            .fill(AppTheme.steam.gradient)
                            .frame(width: proxy.size.width * steamRatio)
                    }
                }
                .frame(height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    mixLegend(color: AppTheme.ember, title: L10n.string("activity.sauna"), count: mix.sauna)
                    Spacer(minLength: 8)
                    mixLegend(color: AppTheme.steam, title: L10n.string("activity.steam_room"), count: mix.steam)
                }
            }
        }
        .panelStyle()
    }

    private var insightEmptyText: some View {
        Text("insights.empty")
            .font(AppTheme.bodyFont(13))
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mixLegend(color: Color, title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) · \(count)")
                .font(AppTheme.bodyFont(12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var insightSessions: [HeatSession] {
        store.recentSessions
            .filter { selectedInsightScale.contains($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var insightSummary: InsightSummary {
        let sessions = insightSessions
        let totalDurationMinutes = sessions.reduce(0) { $0 + max(0, $1.actualDurationSeconds / 60) }
        let hrSessions = sessions.filter { $0.averageHeartRate > 0 }
        let averageHR = hrSessions.isEmpty ? 0 : Int((hrSessions.reduce(0.0) { $0 + $1.averageHeartRate } / Double(hrSessions.count)).rounded())
        let dayCount = max(1, selectedInsightScale.elapsedDayCount)

        return InsightSummary(
            totalHeatMinutes: totalDurationMinutes,
            heatMinutesPerDay: Int((Double(totalDurationMinutes) / Double(dayCount)).rounded()),
            sessions: sessions.count,
            averageHeartRate: averageHR
        )
    }

    private var heatTimeRows: [InsightBucketRow] {
        selectedInsightScale.buckets().map { bucket in
            let minutes = store.recentSessions
                .filter { $0.startDate >= bucket.start && $0.startDate < bucket.end }
                .reduce(0) { $0 + max(0, $1.actualDurationSeconds / 60) }
            return InsightBucketRow(id: bucket.start, label: bucket.label, minutes: minutes)
        }
    }

    private var durationTrendRows: [DurationTrendRow] {
        selectedInsightScale.buckets().compactMap { bucket in
            let sessions = store.recentSessions.filter { $0.startDate >= bucket.start && $0.startDate < bucket.end }
            guard !sessions.isEmpty else { return nil }
            let totalMinutes = sessions.reduce(0) { $0 + max(0, $1.actualDurationSeconds / 60) }
            return DurationTrendRow(id: bucket.start, label: bucket.label, averageMinutes: max(1, totalMinutes / sessions.count))
        }
    }

    private var heatMix: HeatMix {
        HeatMix(
            sauna: insightSessions.filter { $0.activityType == .sauna }.count,
            steam: insightSessions.filter { $0.activityType == .steamRoom }.count
        )
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            return L10n.format("insights.value.hours_minutes", minutes / 60, minutes % 60)
        }
        return L10n.format("insights.value.minutes", minutes)
    }

    private func handleNotificationRoute(_ route: SaunaLogLocalNotificationManager.Route) {
        switch route {
        case .insights:
            selectedInsightScale = .month
            withAnimation(.easeInOut(duration: 0.2)) {
                showingSupport = false
                showingInsights = true
            }
        }
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

    private func scheduleWatchInstallReminderIfNeeded() {
        SaunaLogLocalNotificationManager.shared.scheduleWatchInstallReminderIfNeeded(
            isPaired: watchSync.isPaired,
            isWatchAppInstalled: watchSync.isWatchAppInstalled
        )
    }

    private func softTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func successTap() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return L10n.format("support.version_format", version, build)
    }

    private func mailURL(subjectKey: String) -> URL {
        let subject = L10n.string(subjectKey)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:app.inventory.me@gmail.com?subject=\(subject)")!
    }
}


private struct InsightMetricCard: View {
    let titleKey: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(titleKey))
                .font(AppTheme.bodyFont(11))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(AppTheme.accentFont(22))
                .foregroundStyle(AppTheme.sand)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum InsightScale: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    static let displayOrder: [InsightScale] = [.week, .month, .year]

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .week: return "insights.scale.week"
        case .month: return "insights.scale.month"
        case .year: return "insights.scale.year"
        }
    }

    var bucketTitleKey: String {
        switch self {
        case .week: return "insights.bucket.day"
        case .month: return "insights.bucket.week"
        case .year: return "insights.bucket.month"
        }
    }

    var bucketAxisKey: String {
        switch self {
        case .week: return "insights.axis.day"
        case .month: return "insights.axis.week"
        case .year: return "insights.axis.month"
        }
    }

    var elapsedDayCount: Int {
        let calendar = Calendar.current
        let now = Date()
        let start = range(containing: now).start
        let days = calendar.dateComponents([.day], from: start, to: now).day ?? 0
        return days + 1
    }

    func contains(_ date: Date) -> Bool {
        range(containing: Date()).contains(date)
    }

    func range(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        switch self {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 24 * 60 * 60)
        case .month:
            return calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 30 * 24 * 60 * 60)
        case .year:
            return calendar.dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 365 * 24 * 60 * 60)
        }
    }

    func buckets() -> [InsightBucket] {
        let calendar = Calendar.current
        let now = Date()
        let range = range(containing: now)
        let formatter = DateFormatter()

        switch self {
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return (0..<7).compactMap { offset in
                guard let start = calendar.date(byAdding: .day, value: offset, to: range.start),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return InsightBucket(start: start, end: end, label: formatter.string(from: start))
            }
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            var buckets: [InsightBucket] = []
            var start = range.start
            while start < range.end {
                guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { break }
                buckets.append(InsightBucket(start: start, end: min(end, range.end), label: formatter.string(from: start)))
                start = end
            }
            return buckets
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("MMM")
            return (0..<12).compactMap { offset in
                guard let start = calendar.date(byAdding: .month, value: offset, to: range.start),
                      let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
                return InsightBucket(start: start, end: end, label: formatter.string(from: start))
            }
        }
    }
}

private struct InsightSummary {
    let totalHeatMinutes: Int
    let heatMinutesPerDay: Int
    let sessions: Int
    let averageHeartRate: Int
}

private struct InsightBucket {
    let start: Date
    let end: Date
    let label: String
}

private struct InsightBucketRow: Identifiable {
    let id: Date
    let label: String
    let minutes: Int
}

private struct DurationTrendRow: Identifiable {
    let id: Date
    let label: String
    let averageMinutes: Int
}

private struct HeatMix {
    let sauna: Int
    let steam: Int
}

private struct LinkRow: View {
    let titleKey: String
    var subtitle: String? = nil
    var subtitleKey: String? = nil
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(titleKey))
                        .font(AppTheme.accentFont(14))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle ?? L10n.string(subtitleKey ?? ""))
                        .font(AppTheme.bodyFont(12))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
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
