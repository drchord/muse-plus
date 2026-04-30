# Muse SDK 8.0.5 — Integration Notes

## Connection Pattern (from MuseStatsIosSwift example)

```swift
manager.startListening()         // starts BLE scan → calls museListChanged()
muse.register(connectionListener)
muse.register(dataListener, type: .eeg)
muse.setPreset(IXNMusePreset.presetXX)
muse.runAsynchronously()         // preferred over custom execute() loop
```

## Preset for Muse S Athena

The example uses `preset21` (Muse 2016 only). For Muse S Athena, try in order:
- `.preset50` — first try
- `.preset53`
- `.preset55`

Setting wrong preset: SDK logs a warning, headband disconnects then may reconnect.
Check `IXNMuseConfiguration` after connecting (without preset) to confirm model,
then set preset accordingly.

## Data Listener EEG Packet

Packet type: `IXNMuseDataPacketTypeEeg`
Values array indices: TP9=0, AF7=1, AF8=2, TP10=3 (4-channel)

## Framework Headers Location

`Frameworks/Muse.framework/Headers/api/` — all ObjC headers (use bridging header in Swift)

## Bridging Header

```objc
#import <Muse/Muse.h>
```

## Key Classes

| Class | Purpose |
|-------|---------|
| `IXNMuseManagerIos` | Singleton. BLE scan, muse list |
| `IXNMuse` | Individual headband. Connect, register, execute |
| `IXNMuseDataPacket` | EEG/Accel/Battery data packet |
| `IXNMuseConnectionPacket` | Connection state changes |
| `IXNMusePreset` | Preset enum — model-specific |
