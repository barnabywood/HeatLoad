# Heat Load Release Checklist

## 1. Identity and Signing
- [ ] Confirm final bundle IDs for iOS app and Watch app targets (no temporary/dev suffixes).
- [ ] Ensure each target has a valid provisioning profile and signing team selected.
- [ ] Confirm app display name is **Heat Load** on iPhone and Apple Watch.
- [ ] Verify app icons are fully populated for iOS and watchOS asset catalogs.

## 2. App Store Connect Setup
- [ ] Create the app record in App Store Connect.
- [ ] Complete Paid Apps agreement, tax, and banking.
- [ ] Add screenshots and metadata for iPhone + Apple Watch.
- [ ] Add support URL and marketing URL if required.
- [ ] Add privacy policy URL:
  - `https://raw.githubusercontent.com/barnabywood/HeatLoad/main/privacy-policy.md`

## 3. In-App Purchase (Unlock)
- [ ] Create non-consumable IAP product with Product ID:
  - `com.heatload.unlock`
- [ ] Add localized title/description and pricing.
- [ ] Submit IAP for review with the app version.
- [ ] Confirm product status is available for testing (Sandbox/TestFlight).

## 4. StoreKit Behavior Validation
- [ ] Fresh install: app starts with free trial state.
- [ ] Complete 3 sessions: trial limits appear correctly.
- [ ] Tap **Unlock Now**: purchase succeeds in Sandbox/TestFlight.
- [ ] Relaunch app: unlock state persists.
- [ ] Tap **Restore** on a previously purchased account: unlock restores.
- [ ] Verify no purchase blocks during local DEBUG development builds.

## 5. Apple Watch Functional Validation
- [ ] App installs on physical watch from paired iPhone.
- [ ] Setup screen: choose heat type, choose timer, slide to start.
- [ ] Active screen: countdown, HR, active kcal, total kcal update correctly.
- [ ] Timer completion triggers haptic reminders until extend or stop.
- [ ] Stop session saves without HealthKit errors.
- [ ] Background/resume: app reopens from icon/app switcher reliably.

## 6. HealthKit / Fitness Validation
- [ ] Health permission prompts appear and are approved.
- [ ] Workout writes successfully to Apple Health.
- [ ] Metadata includes selected heat activity and cold shower flag.
- [ ] Session duration, heart-rate stats, and calories are recorded.
- [ ] Workout category behavior in Fitness is acceptable for review/demo.

## 7. iPhone App UX Validation
- [ ] Home screen fills full device height edge-to-edge.
- [ ] Timer management works (default + custom).
- [ ] Links open correctly:
  - Privacy Policy
  - Contact / Feedback (`app.inventory.me@gmail.com`)
  - Leave a Review
- [ ] Review prompt triggers after 5 lifetime sessions.
- [ ] Free Trial card disappears after unlock.

## 8. Compliance and Submission
- [ ] Confirm privacy policy text matches app behavior.
- [ ] Verify all required usage descriptions are present (HealthKit, etc.).
- [ ] Run final archive build in **Release** configuration.
- [ ] Upload build to App Store Connect.
- [ ] Complete App Review notes (include watch-specific testing notes).

## 9. Pre-Submission Smoke Pass (Physical Devices)
- [ ] iPhone + Watch paired test on current OS versions.
- [ ] End-to-end session from watch start -> stop -> Health save -> iPhone history.
- [ ] Trial -> unlock -> restore flows all pass.
- [ ] No blocking errors in Xcode device logs during key flows.
