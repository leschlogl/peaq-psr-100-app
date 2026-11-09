# Bluetooth protocol notes

My PEAQ uses Core Bluetooth to discover the PSR 100, subscribe to history notifications, and request stored readings. The main service is `4CDABAA0-2CEA-C0C1-B38D-A0481AE60A97`, with `4CDABAA1-2CEA-C0C1-B38D-A0481AE60A97` for writes and `4CDABAA2-2CEA-C0C1-B38D-A0481AE60A97` for notifications. The implementation also recognizes an alternate service profile. The app uses only known write characteristics.

The Swift decoder checks framing, length, and CRC before processing responses. It handles split notifications and bounded fragment assembly. Repeated imports merge by ring and record identity. Firmware may differ across rings. The verified PSR 100 accepted history queries without a session token. Legacy connection credentials, if already present, are read from the Keychain.

| Data | Response | Layout notes |
| --- | --- | --- |
| Battery | `04/41` | Percent and state bytes. This takes precedence over the standard Battery Level characteristic for the connection. |
| Firmware | `01/13` | The first three body bytes provide the vendor firmware version. Standard Device Information revisions are displayed separately. |
| Sleep | `0A/A2` | Date followed by stage, hour, and minute triples. Stage codes 0, 1, and 2 represent awake, light, and deep. Hours before 19:00 belong to the following day. Only intervals closed by a subsequent transition are counted. |
| Exercise | `0A/A5` | Supported layouts are 16-byte legacy summaries and 49-byte summaries. |
| PAI | `0A/C8` | Date and score records from the ring. The UI shows the activity date. |
| Unidentified daily index | `0A/C7` | Date and value records kept separate from PAI. |

Ring timestamps are interpreted in the iPhone’s time zone. Travel and daylight-saving behavior on physical firmware still need validation. Activity frames without a sample timestamp are stored with their receipt time.

## Provenance

Extended record layouts were researched through static inspection and checked against observed device responses where available. My PEAQ implements the wire formats in Swift. The repository’s MIT license covers this project’s own source.
