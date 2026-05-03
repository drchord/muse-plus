# MusePlus — STATUS

**Last updated:** 2026-05-03

## Build State

| Build | Feature | TestFlight | Notes |
|-------|---------|-----------|-------|
| 40 | Audio crash fix | ✅ Uploaded | Explicit format + delayed restart + main-thread BT capture |
| 41 | Chime preview + meditation timer | ✅ Uploaded | Timer-end triple gong, 5–90 min presets |
| 42 | Session recording (JSON → Files app) | ✅ Uploaded | ShareLink for Google Drive export |
| 43 | Idle timer disable + auto-reconnect | ✅ Uploaded | 3 attempts × 3s, preserves calibration |
| 44 | Signal quality view | ✅ Uploaded | Replaced raw µV with HSI Excellent/Good/Fair/Poor |
| 45 | Chart X-axis rolling 60s window | ❌ Compile fail | Never reached TestFlight |
| 46 | Mind Monitor dark chart redesign | ❌ Compile fail | Never reached TestFlight |
| 47 | Spectral peak Hz per band | ❌ Compile fail | Never reached TestFlight |
| 48 | Compile fixes (BandPowers + chartScale) | ❌ Upload limit | Apple daily limit hit |
| 49 | Empty trigger commit | ❌ Upload limit | Still blocked |
| 50 | All of 45–48 features | ✅ **Current TestFlight build** | CI run 25291031222 — uploaded 2026-05-03 |

**Current blocker:** None. Build 50 live in TestFlight.

## What Build 48 Contains (over build 44)

1. **Chart X-axis** — rolling 60s window anchored to latest sample (was freezing/compressing)
2. **Mind Monitor dark chart** — `Color(white: 0.07)` card, MM colors (Delta=red, Theta=violet, Alpha=cyan, Beta=lime-green, Gamma=orange), 3pt catmullRom lines, faint Y gridlines, hidden legend
3. **Spectral peak Hz** — header above chart shows `δ Delta  1–4 Hz  [live Hz bold]` for each band using `vDSP_maxvi` on FFT mag2 within each band's bin range

## Gate Status

| Gate | Description | Status |
|------|-------------|--------|
| 0 | Skeleton + SDK reference app | ✅ Done |
| 1 | MuseClient CI build + TestFlight | ✅ Done |
| 2 | EEGPipeline FFT band-power + DepthScore | ✅ Done |
| 3 | UI flow (depth badge, band chart, signal quality) | ✅ Done |
| 4 | Audio (chimes + soundscapes + timer) | ✅ Done |
| 5 | Spotify Web API + PKCE | ✅ Code done / needs device test |
| 6 | Session recording + export | ✅ Done |
| 7 | Auto-reconnect + idle timer | ✅ Done |
| 8 | Mind Monitor chart + spectral peaks | ⏳ In build 48 — pending upload |

## Key Config

- Bundle ID: `com.drchord.museplus`
- Display name: `Muse++`
- Version: `1.2.0` (MARKETING_VERSION)
- Build number: `github.run_number` (CI auto-increment)
- Framework: `Frameworks/Muse.framework` (fat static, arm64+x86_64, embed:false)
- Device family: iPhone only (TARGETED_DEVICE_FAMILY=1)
- Deployment target: iOS 17.0
- Bluetooth perm: NSBluetoothAlwaysUsageDescription
- Background modes: bluetooth-central, audio
- Files app: UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace

## Critical Architecture Notes

- **AVAudioEngine format**: always explicit — mono for ChimeEngine (`channels: 1`), stereo for SoundscapePlayer (`channels: 2`). `format: nil` causes crash after BT route change.
- **Config change handler**: `asyncAfter(0.5s)` delay required in `AVAudioEngineConfigurationChange` notification.
- **Binaural beat**: `beatHz` captured on main thread before background dispatch (was race condition).
- **BandPowers struct field order**: `delta,theta,alpha,beta,gamma` then `deltaPeak,thetaPeak,alphaPeak,betaPeak,gammaPeak` — init call must match exactly.
- **chartForegroundStyleScale**: use `domain:/range:` overload with arrays, not `[String:Color]` dict.
- **Frontal channels**: AF7=ch1, AF8=ch2 for depth scoring.
- **DepthGate**: EMA α=0.15, 20s sustain to enter deep, 15s to exit, 3-min cooldown.

## App Store Submission — Step by Step

> Use this when you're ready to submit to the App Store (while still distributing via TestFlight).

### Phase 1 — Prepare (before touching App Store Connect)

1. **Stable TestFlight period**: Use the app for at least 1–2 weeks. No crashes, no forced closes. Build 48 should be that baseline.
2. **Privacy policy**: Required by Apple. Minimum: a page stating the app does not collect/share personal data. Host free on GitHub Pages or Notion. Save the URL.
3. **Screenshots**: Required sizes:
   - 6.7" (iPhone 15 Pro Max): **1290 × 2796 px** — take on device or Simulator
   - 6.5" (iPhone 14 Plus / 13 Pro Max): **1242 × 2688 px**
   - At least 3 screenshots per size. Capture: main session screen, band chart, signal quality, timer.
4. **App icon**: Must be 1024×1024 px PNG (no alpha/transparency). The CI-generated placeholder may not be App Store quality — consider a real icon.
5. **No placeholder text**: Description, subtitle, keywords must be final.

### Phase 2 — App Store Connect Setup

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. Click **My Apps** → **+** → **New App**
   - Platform: iOS
   - Name: `Muse++` (or whatever you want displayed)
   - Primary language: English
   - Bundle ID: `com.drchord.museplus` (must already exist from TestFlight)
   - SKU: any unique string, e.g. `museplus-2026`
3. Fill **App Information**:
   - Subtitle (30 chars max): e.g. `EEG Meditation Companion`
   - Category: Health & Fitness (primary), Utilities (secondary)
   - Privacy Policy URL: your hosted page
4. Fill **Pricing and Availability**: Free, All countries (or select)
5. Fill **App Privacy**: declare no data collected (since sessions stay on device)
6. **Age Rating**: complete questionnaire — should result in 4+

### Phase 3 — Version Metadata

1. Under **1.2 Prepare for Submission**:
   - Upload screenshots (drag into correct size slots)
   - Description (up to 4000 chars) — explain what the app does, who it's for
   - Keywords (100 chars) — meditation, EEG, Muse, brainwave, mindfulness
   - Support URL (GitHub or personal site)
   - Marketing URL (optional)
2. **Build**: click **+** next to Build — select the TestFlight build you want to ship (e.g. build 48 or later). The same binary goes to App Store.
3. **Review notes** (optional but smart): `App requires Muse S or Muse 2 EEG headband connected via Bluetooth. No in-app purchases. App was developed for personal meditation use.`

### Phase 4 — Submit

1. Click **Add for Review**
2. Answer export compliance (no encryption beyond standard HTTPS → select No)
3. **Submit for Review**
4. Review time: typically 24–72 hours. Health/BLE apps sometimes get extra scrutiny.

### Phase 5 — Common Rejection Reasons (avoid these)

| Risk | How to avoid |
|------|-------------|
| Bluetooth perm string too vague | Already good: `connects to your Muse S headband to read EEG data` |
| App crashes on reviewer's device | Reviewer won't have a Muse — add a **demo mode** or graceful "no device" state |
| Missing privacy policy | Have URL ready before submitting |
| Placeholder icon | Use a real 1024×1024 icon |
| App doesn't work without accessory | Most important: the app must not crash or show error screens when no Muse connected — show a "connect your headband" onboarding screen instead |

### After Approval

- Set **release date**: Manually release (gives you control) vs. auto-release after approval
- Monitor **App Store reviews** in App Store Connect
- Future updates: same flow — build, TestFlight test, then submit new version

---

## Continuation Prompt

```
MusePlus iOS app — Muse S EEG real-time meditation companion.
Project: C:\Users\sugat\MusePlus. Git remote: drchord/muse-plus.

CURRENT STATE (2026-05-03):
- Last TestFlight build: 50 ✅ — uploaded successfully 2026-05-03
- CI run: 25291031222 (github.run_number=50)
- CI uses github.run_number as build number

WHAT BUILD 50 CONTAINS (over build 44):
1. BandChart: Mind Monitor dark style — Color(white:0.07) card, MM colors, 3pt catmullRom lines
2. BandChart header: δ Delta 1–4 Hz | live dominant Hz bold per band (vDSP_maxvi on FFT mag2)
3. Chart X-axis: rolling 60s window (xDomain = max(0, last.time-60)...last.time)

KEY BUG FIXES THAT WERE IN BUILDS 45-48:
- EEGPipeline BandPowers init: labels must be delta,theta,alpha,beta,gamma THEN deltaPeak...gammaPeak
- BandChart chartForegroundStyleScale: use domain:/range: arrays, NOT [String:Color] dict

AUDIO INVARIANTS (do not change or crash returns):
- ChimeEngine: explicit mono format (channels:1) on engine.connect()
- SoundscapePlayer: explicit stereo format (channels:2) on engine.connect()
- asyncAfter(0.5s) in AVAudioEngineConfigurationChange handler
- binauralPreset.beatHz captured on main thread before background dispatch

PENDING:
- Spotify flow: muse-monitor://callback registered in Spotify dev dashboard — needs device test
- App Store submission: see STATUS.md Phase 1-5 checklist when ready

Read STATUS.md and run `gh run list --limit 5` before doing anything.
```
