"""Talk to the ESP32 "ECLIPS Bridge" over BLE (no PIN), like the Edge app does.

Usage: bridge_test.py [watch|front on|front off|rear on|rear off]
  watch (default): print bridge status updates for 30 s
"""
import asyncio, struct, sys
from bleak import BleakClient, BleakScanner

CTRL   = "e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d71"  # write 1 byte
STATUS = "e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d72"  # notify, 14 bytes live status
DIAG   = "e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d73"  # read, 12 bytes diagnostics
CMD = {("front", "on"): 0x03, ("front", "off"): 0x04,
       ("rear", "on"): 0x05, ("rear", "off"): 0x06}

def show(d: bytes):
    link, flags, soc = d[0], d[1], d[2]
    line = (f"link={'UP' if link else 'down'} front={'ON' if flags & 1 else 'off'} "
            f"rear={'ON' if flags & 2 else 'off'} batt={'?' if soc == 0xFF else f'{soc}%'}")
    if len(d) >= 14:
        vbat, ibat, spd, vac1, vac2 = struct.unpack_from("<HhHHH", d, 3)
        w = vbat * ibat / 1e6
        line += (f" {vbat/1000:.2f}V {ibat:+d}mA ({w:+.1f}W) "
                 f"speed={'?' if spd == 0xFFFF else f'{spd/10:.1f}'}km/h "
                 f"USB={'on' if flags & 8 else 'off'} BL={flags >> 2 & 1} "
                 f"charger={flags >> 4 & 7} input={flags >> 7 & 1} "
                 f"dynamo={vac2/1000:.1f}V usbin={vac1}mV pwr={d[13]}")
    print(line, flush=True)

def show_diag(d: bytes):
    eeprom, count, tps, paired = struct.unpack_from("<HIHB", d, 3)
    print(f"diag: FW {d[0]}.{d[1]}.{d[2]}  EEPROM {eeprom}  Count {count}  "
          f"TPS_fail {tps}  bonds {paired}", flush=True)

async def main(args):
    dev = await BleakScanner.find_device_by_name("ECLIPS Bridge", timeout=15)
    if not dev:
        sys.exit("ECLIPS Bridge not found")
    async with BleakClient(dev) as c:
        show(await c.read_gatt_char(STATUS))
        show_diag(await c.read_gatt_char(DIAG))
        await c.start_notify(STATUS, lambda _, d: show(bytes(d)))
        if len(args) == 2 and args[0] in ("front", "rear"):
            await c.write_gatt_char(CTRL, bytes([CMD[args[0], args[1]]]), response=True)
            await asyncio.sleep(3)
        else:
            await asyncio.sleep(int(args[1]) if len(args) == 2 else 10)

asyncio.run(main(sys.argv[1:]))
