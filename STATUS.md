# MusePlus — STATUS

**Last updated:** 2026-05-04

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
| 51 | (docs-only commit re-uploaded) | ✅ Uploaded | Same binary as build 50; CI run 25291293534 |
| 52 | feat(build51) overhaul — first attempt | ❌ Compile fail | Accel enum bridging — `.x` → `.X` |
| 53 | feat(build51) overhaul — fixed | ✅ Uploaded | First binary with overhaul features; CI run 25351592940 |
| 54 | docs: build 51 live | ✅ **Current TestFlight build** | Same binary as 53; CI run 25351719451 — uploaded 2026-05-05 |

**Current blocker:** None. Build 54 live in TestFlight as of 2026-05-05 (binary = "Build 51 feature set" from BUILD_PLAN_51.md). Apple build number = `github.run_number`, increments on every CI run including docs.

## What Build 51 Contains (over build 50)

**Audio overhaul:**
1. SoundscapePlayer: 7 real M4A audio files (brook, rain, thunder, wind, ocean, forest, birds) with crossfade loop
2. SoundscapePlayer: adaptive binaural beat tier (>0.70=4Hz delta, >0.45=6Hz theta, else=10Hz alpha)
3. ChimeEngine: stereo (own AVAudioEngine), AVAudioUnitReverb .largeHall, Haas 53-sample delay
4. ChimeEngine: per-partial decay, 432Hz enter / 288Hz exit / 528+660Hz restored / 84Hz timer-end
5. ChimeEngine: contact-restored chime (NEW), check-in chime (NEW)
6. Timer end: SoundscapePlayer.stopAll(fadeSeconds:4) fires automatically

**EEG/signal improvements:**
7. NotchFilteredEeg: switched from .eeg to .notchFilteredEeg (45–65 Hz SDK bandstop removes 60 Hz noise)
8. Artifact rejection layer 1: SDK blink/jawClench packet → pipeline.suppressArtifact()
9. Artifact rejection layer 2: amplitude > 300 µV → drop packet + suppress
10. Artifact rejection layer 3: IsGood 10 Hz flag (frontal AF7/AF8) → suppress
11. Artifact rejection layer 4 (NEW Build 51): Accelerometer > 0.25g motion → suppress
12. PPG heart rate (NEW Build 51): Green/AMBIENT 8s window peak detection → BPM display in top bar

**Depth scoring:**
13. Peniston-Kulkosky meditationIndex: 0.7×((α+θ)−2β) + 0.3×max(0,θ−α)
14. FAA (Frontal Alpha Asymmetry): af8Alpha − af7Alpha, shown as approach/withdrawal bar
15. DepthGate tuning: enter=10s, exit=10s, cooldown=90s, EMA α=0.20

**UI redesign (full overhaul):**
16. ConnectView: dark brain-icon screen, device list, scanning indicator
17. MeditationView: DepthGaugeView (240px circle, score 0-100) + FAABarView + BandChart + BottomButtons
18. Heart rate chip in top bar (shows bpm when PPG locks, hides when 0)
19. SettingsSheet: all developer info moved here (chime preview, band powers, sessions)
20. SoundscapeSheet + TimerSheet as modal sheets

**Infrastructure:**
21. iCloud entitlements (CloudDocuments) in MusePlus.entitlements + project.yml
22. Resources/Soundscapes/ with 7 M4A files (bundle path dual-lookup: subdirectory then root)

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

- **AVAudioEngine format**: ChimeEngine = stereo (own engine, safe). SoundscapePlayer = stereo (`channels:2`, explicit). `format: nil` causes crash after BT route change.
- **Config change handler**: `asyncAfter(0.5s)` delay required in `AVAudioEngineConfigurationChange` notification.
- **Binaural beat**: `beatHz` captured on main thread before background dispatch (was race condition).
- **BandPowers struct field order**: `delta,theta,alpha,beta,gamma` then `deltaPeak,thetaPeak,alphaPeak,betaPeak,gammaPeak` — init call must match exactly.
- **chartForegroundStyleScale**: use `domain:/range:` overload with arrays, not `[String:Color]` dict.
- **Frontal channels**: AF7=ch1 (idx1), AF8=ch2 (idx2) for depth scoring and FAA.
- **DepthGate**: EMA α=0.20, 10s sustain (kEnterSustained=20) to enter deep, 10s to exit, 90s cooldown.
- **NotchFilteredEeg**: SDK applies 45–65 Hz bandstop before our FFT. Use `.notchFilteredEeg` not `.eeg`.
- **IsGood**: frontal AF7/AF8 quality at 10 Hz. Bad → artifact suppress (DO NOT swap channel indices).
- **PPG heart rate**: queue-serialized buffer (ppgBuffer accessed from SDK thread + queue = must serialize). ppgBuffer cleared on disconnect. AMBIENT = Green on Muse S 2019 (SDK header confirmed). Accel values in g (SDK header: "negated to align with headband orientation" — magnitude sqrt(x²+y²+z²) = 1.0 at rest regardless of sign, so `abs(magnitude-1.0)>0.25` is correct). BPM algorithm: demean → 64-tap baseline-wander HP → 8-tap LP → autocorrelation over lags 19–128 (200–30 BPM) → quality gate (AC/power > 0.20). AC approach is more robust than peak detection for noisy wearable PPG.
- **Accelerometer enum bridging**: IXNAccelerometerX → `.X` (uppercase — Swift SE-0005 treats single letter as acronym). IXNPpgAMBIENT → `.AMBIENT` (all-caps acronym rule preserved). Build 51 first attempt failed because notes claimed lowercase; corrected in fix commit.
- **iCloud entitlement**: iCloud.com.drchord.museplus configured in Apple Developer Portal + MusePlus.entitlements.

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
- Last TestFlight build: 50 ✅ — uploaded 2026-05-03
- Build 51: code complete, NOT YET COMMITTED. Run git status to confirm.
- CI uses github.run_number as build number (auto-increment on push)

WHAT BUILD 51 ADDS (over build 50):
Full overhaul — see STATUS.md "What Build 51 Contains" section.
Key files changed: App.swift, MuseClient.swift, EEGPipeline.swift, MuseTypes.swift,
DepthScore.swift, DepthGate.swift, ChimeEngine.swift, SoundscapePlayer.swift,
project.yml, MusePlus.entitlements.
New assets: MusePlus/Resources/Soundscapes/*.m4a (7 files).

COMPILE-TIME RISKS FOR BUILD 51:
- IXNAccelerometer enum bridging: .x/.y/.z (lowercase) — if compiler says member not found, try .X/.Y/.Z
- IXNPpg.AMBIENT bridging: .AMBIENT (all-caps preserved) — if error, try .ambient
- Check AVAudioUnitReverb preset: .largeHall (NOT .largeChamber — does not exist)
- BandPowers init label order MUST be: delta,theta,alpha,beta,gamma then deltaPeak...gammaPeak

AUDIO INVARIANTS (do not change or crash returns):
- ChimeEngine: stereo (own AVAudioEngine, safe)
- SoundscapePlayer: explicit stereo (channels:2) on engine.connect()
- asyncAfter(0.5s) in AVAudioEngineConfigurationChange handler
- binauralPreset.beatHz captured on main thread before background dispatch

PENDING FOR FUTURE BUILDS:
- SessionRecorder: add FAA, heartRate, soundscapeEvents, preSessionBaseline fields
- Session replay view: post-session chart scrollback
- Training program stages: findingCalm → deepening → thetaTraining → deepAbsorption
- Python analysis pipeline on Sparky (every-5-session report → Google Drive → email)
- ZIPFoundation SPM dependency for session ZIP export
- Spotify flow: needs device test (muse-monitor://callback registered in Spotify dev dashboard)
- App Store submission: see STATUS.md Phase 1-5 checklist when ready

Read STATUS.md and run `gh run list --limit 5` before doing anything.
```
