# Canyon ECLIPS ("Canyon Power Supply") BLE protocol

Source: decompiled com.canyon.connected 8.3.1 (classes vo.*, cp.a) + live tests, FW 0.1.2.

- Device: static random address (per unit, `D9:…` on the tested one), name "Canyon Power Supply", nRF / Zephyr.
  Manufacturer data in the advert is the address as ASCII.
- Security: LE pairing with **passkey entry**, PIN = last 6 digits of the ECLIPS serial number.
  Device sends a Security Request right after connect and disconnects if pairing fails.
  Up to 3 bonds (`Paired_Conn` in status).
- Services: Nordic UART `6e400001-…` (RX write `6e400002`, TX notify `6e400003`),
  McuMgr SMP `8d53dc1d-…` (DFU — do not touch).
- App requests MTU 498; reply is ~300 B ASCII, arrives over multiple notifications with smaller MTU.

## Commands (single byte, write-with-response to 6e400002)
| byte | action |
|---|---|
| 0x03 | front light on |
| 0x04 | front light off |
| 0x05 | rear light on |
| 0x06 | rear light off |
| 0x0E | get device info |

## Device info reply (ASCII, `Key: value` lines, ~300 B over several notifications)
Fields decoded on 2026-10-03 by logging at 1 Hz while spinning the front wheel,
switching the front light on, and plugging a phone into USB-C.

| Field | Example | Meaning |
|---|---|---|
| `UID` | `cps_02` | unit id |
| `Chg` | `3, 1` | charger state (0 idle, 3 charging), input power present (0/1). Looks like a TI dual-input charger |
| `iBat` | `-300 mA` | battery current, **+ charging / − draining**. Front light ≈ −300 mA (≈2.3 W), idle ≈ −6 mA, phone on USB-C ≈ −125 mA |
| `VBat` | `7640 mV` | battery voltage (2-cell pack) |
| `SOC` | `48%` | state of charge |
| `USB` | `1` | USB-C **output** on (unit powering a device) |
| `FL` / `RL` | `1` | front / rear light on |
| `BL` | `1` | **unknown**: always 1. Not a brake light (the bike has none); maybe "BLE connected" |
| `Speed` | `17 km/h` | integer km/h, from the dynamo hub frequency |
| `FW` | `0.1.2` | firmware version |
| `Power State` | `0` | unclear: 0 in all logged runs, 1 in the earliest reads |
| `Count` | `14405` | counter that rises slowly (boots or uptime ticks?) |
| `TPS_COMM_Fail` | `0` | charger-chip communication errors |
| `EEPROM_Ver` | `0006` | config version |
| `Paired_Conn` | `3` | number of bonded devices (max 3) |
| `VAC1` | `0` | second charger input, mV, probably the USB-C **charging** input. Reads 10–13 (leakage) only while the dynamo charges |
| `VAC2` | `17950` | **dynamo input voltage, mV**. Caps at ≈18 V when spinning, then decays slowly for minutes after stopping (capacitor), so it is *not* a "generating now" signal. Use `Speed` or `Chg` input instead |

Behaviour seen while hand-spinning: within about 1 s of the wheel turning,
`Chg` goes to `3, 1` and `VAC2` jumps to ~18 V. With the front light on,
`iBat` went from −300 mA to +210 → +4 mA, so the dynamo covered the light.
