# Local data storage

My PEAQ reads the ring over Bluetooth and saves decoded history inside its app container on your iPhone. The app has no account or backend. Today and Insights read saved history from the phone, so you can browse it while the ring is disconnected.

## What the app saves

| Data | Where it is stored |
| --- | --- |
| Health and activity readings, sleep stages, exercise summaries, and PAI scores | A SwiftData database in the app container |
| Activity goals, optional profile details, sync interval, and remembered ring and sync state | App preferences using UserDefaults |
| A legacy ring session token, if present | The iOS Keychain, separately from the history database |
| Recent connection diagnostics | A bounded report in the app’s cache |

The app discards raw Bluetooth packets after processing. Older development builds may have left local packet archives under `Application Support/PendingRingHistory`.

## How history imports work

The app saves decoded records in batches. Each record belongs to the ring that supplied it. Syncing an overlapping period updates matching records when values have changed and adds records for new measurements.

- A metric reading is identified by its ring, metric, timestamp, and timestamp type. When the ring sends an activity total without a timestamp, the app records when it arrived and groups repeated totals within the same minute.
- A sleep segment is identified by its ring and start time. An exercise session also uses its activity type when available.
- Hourly and daily chart averages are calculated from the saved readings when you view a chart. The database stores the underlying readings.

If a batch fails to save, the app rolls back that batch. If the database fails to open, the app offers **Try again** and keeps the existing store files.

## Disconnecting, forgetting, and sharing

- **Disconnect** pauses automatic reconnection across launches. Select **Reconnect** or choose a ring to resume.
- **Forget connection** clears the remembered selection. Saved history and any existing Keychain token remain associated with the original ring. Selecting that same ring again makes its saved history available.
- **Share diagnostics** opens the iOS share sheet with connection details, firmware revisions, and packet counts. Review the report before posting it publicly. History records and session token values are outside the report.

Device backups are managed by iOS. Your iCloud Backup settings may include the app’s local data. [Apple’s guide to iCloud Backup](https://support.apple.com/en-ie/108770)

## Implementation

- [RingStore.swift](../PeaqRing/Data/RingStore.swift) defines the stored records, batch imports, history queries, and Keychain access.
- [RingBluetooth.swift](../PeaqRing/Bluetooth/RingBluetooth.swift) manages connection preferences, sync state, and the diagnostics cache.
- [ReferencePreferences.swift](../PeaqRing/Data/ReferencePreferences.swift) and [RingSettingsView.swift](../PeaqRing/Views/RingSettingsView.swift) manage profile settings and activity goals.
