# Bowl Audio Resources — drop-in slot for B83

`EndGongPlayer.swift` looks up `bowl_success` and `bowl_failure` here at runtime via:

```swift
Bundle.main.url(forResource: "bowl_success", withExtension: "m4a")
Bundle.main.url(forResource: "bowl_success", withExtension: "wav")  // fallback
```

If both lookups fail, `EndGongPlayer` falls back to `ChimeEngine.shared.playGong()` (success) or `ChimeEngine.shared.playFailureChime()` (failure). B83 raised the synthesis fundamental from 84 Hz → 432 Hz so the fallback is audible on iPhone built-in speaker, but pre-recorded bowl recordings sound better.

## Source (recommended)

Pixabay tibetan-bowl pack — royalty-free, no attribution required:
https://pixabay.com/sound-effects/search/tibetan-bowl/

## Filenames the app expects

| Slot | Filename | Used for |
|---|---|---|
| Success | `bowl_success.m4a` (or `.wav`) | Manual end, timer-completed end |
| Failure | `bowl_failure.m4a` (or `.wav`) | Disconnect grace expired, BLE timeout |

## Recommended encoding

- Format: AAC `.m4a`, 256 kbps, 48 kHz stereo (small + iOS-native)
- Length: 6–12 s (gong with natural decay)
- Loudness: peak −3 dBFS, RMS −18 LUFS
- Energy in 200–2000 Hz dominant (iPhone speaker passband)

## Adding to Xcode build

This directory is already covered by `project.yml`:

```yaml
resources:
  - path: MusePlus/Resources
    optional: true
```

Drop files here. Run `xcodegen generate` (or rebuild Xcode project) — files auto-included in the bundle.

## Verification after install

After running a session and pressing Save&Stop, exported NDJSON must contain:

```json
{"_type":"gongLifecycle","time":...,"phase":"scheduled","source":"file:bowl_success.m4a"}
{"_type":"gongLifecycle","time":...,"phase":"started","source":"file:bowl_success.m4a"}
{"_type":"gongLifecycle","time":...,"phase":"completed","source":"file:bowl_success.m4a"}
```

If you see `"phase":"failed"` or `"source":"file:bowl_success_not_in_bundle"`, the file is not in the bundle.
