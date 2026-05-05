# Muse S Athena (MS-03) — Canonical Spec Reference

**Source:** SDK 8.0.5 headers (`Muse SDK _ RDK-20260428T132319Z-3-001/Muse SDK 8.0.5/libmuse_ios_8.0.5/`).
**Model identifier:** `IXNMuseModelMs03` — "MuseS 2025 softband with USB-C, Bluetooth 5.3, improved EEG and Optics"
**SDK version required:** 8.0.0 minimum (Athena support added). Use 8.0.5 (latest as of 2026-04).

> **Note:** Build 54 ships Muse SDK 7.x (legacy). Migration to SDK 8.0.5 required before any Athena work.

## EEG

- **8 channels** total: 4 on-head (EEG1-4) + 4 auxiliary (AUX1-4 in `IXNEeg` enum)
- **256 Hz sample rate** (canonical preset 1041/1042; 14-bit)
- Channel mapping (`IXNEeg.h`):
  - `EEG1` = Left ear (TP9-equivalent)
  - `EEG2` = Left forehead (AF7-equivalent)
  - `EEG3` = Right forehead (AF8-equivalent)
  - `EEG4` = Right ear (TP10-equivalent)
  - `AUX1`, `AUX2`, `AUX3`, `AUX4` = Auxiliary inputs on Athena
  - `AUXLEFT`, `AUXRIGHT` = legacy aliases that map to AUX1/AUX2 on Athena
- **HSI / contact quality**: emitted only for the 4 canonical channels — auxiliary channels have no HSI/headband-fit metric
- **14-bit** (vs 12-bit on prior Muse S models)
- **Notch filter**: 45-65 Hz bandstop available via `.notchFilteredEeg` packet (only emits 4 canonical channels)

## Optics (fNIRS)

- **Up to 16 channels @ 64 Hz**, units: microamps (µA)
- Channel mapping (`IXNOptics.h`):
  - **730nm** (HbR — deoxygenated hemoglobin sensitivity): OPTICS1 (left outer), OPTICS2 (right outer), OPTICS5 (left inner), OPTICS6 (right inner)
  - **850nm** (HbO — oxygenated hemoglobin sensitivity): OPTICS3 (left outer), OPTICS4 (right outer), OPTICS7 (left inner), OPTICS8 (right inner)
  - **Red** (660nm, additional wavelength): OPTICS9 (left outer), OPTICS10 (right outer), OPTICS13 (left inner), OPTICS14 (right inner)
  - **Ambient** (background light reference): OPTICS11 (left outer), OPTICS12 (right outer), OPTICS15 (left inner), OPTICS16 (right inner)
- 4-channel mode = inner pairs only (730nm + 850nm)
- 8-channel mode = inner + outer 730nm + 850nm
- 16-channel mode = full set including Red + Ambient
- **Low-power vs high-power presets** trade SNR for battery
- HbO/HbR computed via modified Beer-Lambert from 730nm + 850nm pairs
- Same hardware also computes PPG/heart rate (legacy `IXNPpg` enum is NOT used on Athena — read PPG from Optics)

## Recommended preset for Muse++

| Preset | EEG | Optics | Use case |
|---|---|---|---|
| **1041** | 8 CH @ 256Hz/14-bit | 16 CH @ 64 Hz, low power | **Production default** — full data, all-day battery |
| **1042** | 8 CH @ 256Hz/14-bit | 16 CH @ 64 Hz, high power | Research sessions where SNR matters |
| 1043 | 8 CH @ 256Hz/14-bit | 8 CH @ 64 Hz, low power | If 16 CH optics overhead causes BLE saturation |
| 1022 | 8 CH @ 256Hz/14-bit | none | If fNIRS not needed for a given session |

All presets include 52 Hz accelerometer/gyro, 1 Hz battery, 32 Hz DRL/REF.

## Bluetooth & connectivity

- **BLE 5.3** — supports connection isochronous channels (lower jitter than BLE 5.0). Empirical jitter measurement still required on real device — assume 5-15 ms 95th-percentile until measured.
- **USB-C wired** — available on Athena. **For closed-loop / phase-locked stimulation**, the wired path eliminates BLE jitter entirely. T2-#7 (Hilbert phase-lock) reopens as GO-WITH-CAVEATS for wired sessions only.

## What's removed from Athena (vs Muse S 2019)

- **Thermistor / body temperature**: not in any Athena preset
- **`IXNPpg` packet enum**: legacy, replaced by Optics

## What's added on Athena (vs Muse S 2019)

- **fNIRS (Optics)** — entire new modality
- **Doubled EEG channels** (4 → 8)
- **14-bit ADC** (12-bit → 14-bit)
- **BLE 5.3** (5.0 → 5.3)
- **USB-C** wired alternative
- **`IsHeartGood` packet** — derived heart-rate quality metric (was `IsPpgGood` only)
- **Cloud-computed packet type** — server-side derived values

## SDK migration checklist (Build 55a — first session)

- [ ] Replace `Frameworks/Muse.framework` (currently 7.x) with SDK 8.0.5 framework from `MUSE SDK/Muse SDK 8.0.5/libmuse_ios_8.0.5.tar.gz`
- [ ] Update `MuseClient.swift`:
  - Add Athena detection: `if config.model == .Ms03` branch
  - Set preset 1041 via `muse.setPreset(.preset1041)`
  - Subscribe to `IXNMuseDataPacketTypeOptics` packet type
  - Replace PPG handling: read `getOpticsChannelValue` for IR/Red instead of `getPpgChannelValue(.AMBIENT)`
  - Handle 8-channel EEG: extend channel index loop from 0..3 to 0..7
- [ ] Update `EEGPipeline.swift`:
  - Allocate FFT processors for 8 channels (was 4)
  - Mean over canonical 4 channels for legacy depth/FAA metrics; expose 8-channel separately
- [ ] Add `Pipeline/OpticsPipeline.swift`:
  - Modified Beer-Lambert: `ΔHbO = (extinction_coefficients) × ΔOD_730 + ΔOD_850` (with proper coefficient matrix)
  - Bandpass 0.01-0.5 Hz to remove cardiac (Mayer wave at 0.1 Hz must be preserved if HRV-fNIRS coupling desired — separate filter)
- [ ] Update SessionRecorder schema (back-compat via Optional fields):
  - Add `opticsHbO[8]`, `opticsHbR[8]` (left/right × outer/inner)
  - Add `ch8EegBands[8]` for 8-channel band powers
  - Migrate heart rate source from PPG to Optics-derived
- [ ] Verify on device:
  - Pair Athena, confirm `getMuseModel()` returns `.Ms03`
  - Confirm preset 1041 set successfully
  - Log first Optics packet structure to verify 16 channels arrive
  - Measure BLE 95th-pct jitter over 5 minutes (kill-shot for T2-#7 wired-only decision)

## References

- SDK 8.0.5 headers: `IXNMuseModel.h`, `IXNMusePreset.h`, `IXNEeg.h`, `IXNOptics.h`, `IXNPpg.h`, `IXNMuseDataPacketType.h`
- Release note 8.0.0: "Add support for MuseS Athena (MS-03)"
