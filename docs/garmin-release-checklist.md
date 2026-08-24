# Garmin Release Checklist

Before publishing the Garmin Connect IQ app:

- Replace `GarminCompanionManager.storeUUID` with the actual Connect IQ Store UUID assigned to Sauna Log.
- Confirm the UUID matches the published Garmin app manifest and the iPhone companion lookup.
- Test: iPhone trial user can activate Garmin and complete a session.
- Test: paid iPhone user can switch between Apple Watch and Garmin without losing entitlement.
- Test: Garmin session history arrives in the iPhone Recent list after reconnecting.
- Test: imported Garmin sessions appear in Apple Health with heat metadata and calories.
- Test: a session transmitted more than once is shown only once in Recent.
