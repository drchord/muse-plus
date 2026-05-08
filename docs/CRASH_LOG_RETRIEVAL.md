# iOS Log & Crash Log Retrieval — MusePlus

Use this guide to retrieve diagnostic data after a session anomaly or crash.

---

## Option 1: In-App Diagnostics (fastest)

1. Open MusePlus → tap the gear icon → Settings
2. Scroll to the **Diagnostics** section → tap **View Logs**
3. The last 24 h of OSLog entries are displayed (connection, recording, audio, eeg categories)
4. Tap the **share** button (top right) → AirDrop or Files → send to developer

---

## Option 2: iPhone Analytics Data (no Mac needed)

1. **Settings** → **Privacy & Security** → **Analytics & Improvements** → **Analytics Data**
2. Sort or search for filenames starting with `MusePlus-` and the relevant date (YYYY-MM-DD)
3. Tap the entry → tap the **share** button (top right)
4. AirDrop to Mac, or save to Files app → share via email or Messages

---

## Option 3: Xcode Device Logs (most complete)

1. Connect iPhone to Mac via USB (trust if prompted)
2. In Xcode: **Window** → **Devices and Simulators**
3. Select the iPhone in the left panel
4. Click **View Device Logs** → filter by "MusePlus"
5. Right-click the crash entry → **Export Log** → save as `.ips` or `.crash`
6. Share the exported file with the developer

---

## What to include in a bug report

- The in-app Diagnostics export (covers connection/recording/audio/eeg events)
- The session JSON from MuseSessions/ folder (visible in Files app → On My iPhone → MusePlus)
- Approximate time of the anomaly (so log entries can be correlated)
- Build number (visible in Settings sheet, bottom of list)
