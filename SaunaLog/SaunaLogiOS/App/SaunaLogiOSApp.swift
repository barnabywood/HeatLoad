import SwiftUI
import UserNotifications

@main
struct SaunaLogiOSApp: App {
    @StateObject private var trial = TrialManager()
    @StateObject private var purchase: PurchaseManager
    @StateObject private var store = SessionStore()
    @StateObject private var health = HealthKitManager()
    private let debugRootBounds = false

    init() {
        let trial = TrialManager()
        _trial = StateObject(wrappedValue: trial)
        _purchase = StateObject(wrappedValue: PurchaseManager(trialManager: trial))
        SaunaLogLocalNotificationManager.shared.configure()
        SaunaLogLocalNotificationManager.shared.requestAuthorizationIfNeeded()
        SaunaLogLocalNotificationManager.shared.scheduleUnlockReminderIfNeeded(
            sessionsCompleted: trial.sessionsCompleted,
            hasUnlocked: trial.hasUnlocked
        )
    }

    var body: some Scene {
        WindowGroup {
            RootScaffold(debugRootBounds: debugRootBounds) {
                HomeView()
            }
            .environmentObject(trial)
            .environmentObject(purchase)
            .environmentObject(store)
            .task {
                WatchSyncManager.shared.activate()
                WatchSyncManager.shared.onSessionReceived = { session in
                    store.addSession(session)
                }
                WatchSyncManager.shared.onTrialProgressReceived = { sessionsCompleted, lifetimeSessionsCompleted, hasUnlocked in
                    trial.syncFromPeer(
                        sessionsCompleted: sessionsCompleted,
                        lifetimeSessionsCompleted: lifetimeSessionsCompleted,
                        hasUnlocked: hasUnlocked
                    )
                    SaunaLogLocalNotificationManager.shared.scheduleUnlockReminderIfNeeded(
                        sessionsCompleted: trial.sessionsCompleted,
                        hasUnlocked: trial.hasUnlocked
                    )
                }
                WatchSyncManager.shared.onPresetsReceived = { presets, selectedPreset in
                    store.replacePresets(presets, preferredSelected: selectedPreset)
                }

                WatchSyncManager.shared.sendTrialProgress(
                    sessionsCompleted: trial.sessionsCompleted,
                    lifetimeSessionsCompleted: trial.lifetimeSessionsCompleted,
                    hasUnlocked: trial.hasUnlocked
                )
                WatchSyncManager.shared.sendPresets(store.presets, selectedPresetSeconds: store.selectedPresetSeconds)

                purchase.startObservingTransactions()
                await purchase.loadProducts()
                SaunaLogLocalNotificationManager.shared.scheduleUnlockReminderIfNeeded(
                    sessionsCompleted: trial.sessionsCompleted,
                    hasUnlocked: trial.hasUnlocked
                )

                do {
                    try await health.requestAuthorization()
                    let recovered = try await health.fetchRecentSessions(limit: 120)
                    store.mergeRecoveredSessions(recovered)
                } catch {
                    // Keep local history if Health access is unavailable.
                }
            }
        }
    }
}

private struct RootScaffold<Content: View>: View {
    let debugRootBounds: Bool
    @ViewBuilder let content: Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsLaunchSplash = true

    var body: some View {
        ZStack(alignment: .top) {
            if debugRootBounds {
                DebugRootBackgroundView()
            } else {
                AppBackgroundView()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if showsLaunchSplash {
                LaunchSplashView()
                    .transition(.opacity)
                    .zIndex(999)
                    .task(id: showsLaunchSplash) {
                        guard showsLaunchSplash else { return }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard showsLaunchSplash else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            showsLaunchSplash = false
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                showsLaunchSplash = true
            }
        }
    }
}

private struct DebugRootBackgroundView: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.green

                VStack {
                    Color.red.frame(height: 96)
                    Spacer()
                    Color.blue.frame(height: 96)
                }

                HStack {
                    Color.yellow.frame(width: 18)
                    Spacer()
                    Color.purple.frame(width: 18)
                }

                Rectangle()
                    .stroke(.white, lineWidth: 3)
                    .padding(4)

                VStack {
                    Text("DEBUG ROOT")
                        .font(.system(size: 14, weight: .bold))
                    Text("\(Int(proxy.size.width)) x \(Int(proxy.size.height))")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea()
        }
    }
}

private struct AppBackgroundView: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.iOSBackground)
            .overlay(
                RadialGradient(
                    colors: [AppTheme.ember.opacity(0.22), .clear],
                    center: .topLeading,
                    startRadius: 12,
                    endRadius: 420
                )
            )
            .overlay(
                RadialGradient(
                    colors: [AppTheme.steam.opacity(0.14), .clear],
                    center: .bottomTrailing,
                    startRadius: 24,
                    endRadius: 380
                )
            )
            .ignoresSafeArea()
    }
}

private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            AppTheme.charcoal.opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image("SplashLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 164, height: 164)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 7)

                Text("Sauna Log")
                    .font(AppTheme.titleFont(34))
                    .foregroundStyle(AppTheme.sand)
            }
            .padding(24)
        }
        .contentShape(Rectangle())
    }
}
