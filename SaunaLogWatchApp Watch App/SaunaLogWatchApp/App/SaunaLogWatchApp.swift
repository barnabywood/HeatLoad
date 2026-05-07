import SwiftUI
import WatchKit
import HealthKit

final class SaunaLogWatchExtensionDelegate: NSObject, WKApplicationDelegate {
    private let healthStore = HKHealthStore()
    var onRecoveredWorkoutSession: ((HKWorkoutSession) -> Void)?

    func handleActiveWorkoutRecovery() {
        healthStore.recoverActiveWorkoutSession { [weak self] session, _ in
            guard let session else { return }
            DispatchQueue.main.async {
                self?.onRecoveredWorkoutSession?(session)
            }
        }
    }
}

@main
struct SaunaLogWatchApp: App {
    @WKApplicationDelegateAdaptor(SaunaLogWatchExtensionDelegate.self) private var extensionDelegate

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var trial = TrialManager()
    @StateObject private var store = SessionStore()
    @StateObject private var health = HealthKitManager()
    @State private var didBootstrap = false
    @State private var showsLaunchSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                WatchHomeView()
                    .environmentObject(trial)
                    .environmentObject(store)
                    .environmentObject(health)

                if showsLaunchSplash {
                    WatchLaunchSplashView()
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
            .onAppear {
                extensionDelegate.onRecoveredWorkoutSession = { session in
                    health.recoverActiveWorkoutSession(session)
                }
                bootstrapIfNeeded()
                scheduleSplashDismiss()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    WatchSyncManager.shared.activate()
                    showsLaunchSplash = true
                    scheduleSplashDismiss()
                }
            }
        }
    }

    private func scheduleSplashDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                showsLaunchSplash = false
            }
        }
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        WatchSyncManager.shared.activate()

        WatchSyncManager.shared.onTrialProgressReceived = { sessionsCompleted, lifetimeSessionsCompleted, hasUnlocked in
            trial.syncFromPeer(
                sessionsCompleted: sessionsCompleted,
                lifetimeSessionsCompleted: lifetimeSessionsCompleted,
                hasUnlocked: hasUnlocked
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
    }
}

private struct WatchLaunchSplashView: View {
    var body: some View {
        ZStack {
            AppTheme.charcoal.opacity(0.98)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Image("SplashLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                Text("Sauna Log")
                    .font(AppTheme.accentFont(18))
                    .foregroundStyle(AppTheme.sand)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
        }
    }
}
