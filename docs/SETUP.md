# Heat Load: Zero-to-One Setup

This project currently contains source files only (no `.xcodeproj` yet). Follow these steps exactly.

## 1. Create Xcode project shell
1. Open Xcode.
2. File -> New -> Project.
3. Select iOS -> App.
4. Product Name: `HeatLoad`
5. Interface: `SwiftUI`
6. Language: `Swift`
7. Check `Include Tests` (optional)
8. Save into `/Users/barnabywood/Documents/GitHub/HeatLoad`

## 2. Add Watch target
1. File -> New -> Target.
2. watchOS -> App.
3. Product Name: `HeatLoadWatchApp`
4. Interface: `SwiftUI`
5. Language: `Swift`
6. Add to project.

## 3. Add existing source folders
Drag these folders into Xcode ("Create folder references" unchecked):
- `HeatLoadShared`
- `HeatLoadiOS`
- `HeatLoadWatchApp`

Target membership:
- iPhone target: include `HeatLoadShared` + `HeatLoadiOS`
- Watch target: include `HeatLoadShared` + `HeatLoadWatchApp`

## 4. Capabilities and entitlements
For iPhone and Watch targets, enable:
- HealthKit
- In-App Purchase
- App Groups (optional for stronger sync)

For Watch target, in `Info.plist` add:
- `NSHealthShareUsageDescription` = "Heat Load reads heart rate during sauna/steam sessions."
- `NSHealthUpdateUsageDescription` = "Heat Load writes workout sessions to Health."

## 5. StoreKit product
In App Store Connect, create non-consumable:
- Product ID: `com.heatload.unlock`

## 6. Build and run order
1. Run iPhone app once.
2. Run Watch app on paired simulator/device.
3. Start/end a watch session and confirm it appears on iPhone "Recent Sessions".

## 7. Important current state
- Trial gating is local (3 completed sessions).
- Paywall is wired to StoreKit 2 and product fetch.
- Workout logging uses HealthKit workout session + HR live data.
- Session metadata includes custom fields for activity type and cold shower.

## 8. Next implementation tasks
- Replace local session list with persistence (SwiftData).
- Add local notifications/haptics at timer completion.
- Add robust WatchConnectivity retry queue.
- Add charts and trend insights.
