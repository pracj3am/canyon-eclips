"""Control Canyon ECLIPS lights over BLE (Nordic UART Service).
Usage: eclips.py status | front on|off | rear on|off | all on|off
Requires the computer to be bonded first (pair.py)."""
import asyncio, sys
from bleak import BleakClient

from bike import find_bike

NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # write
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # notify

CMD = {("front", "on"): 0x03, ("front", "off"): 0x04,
       ("rear", "on"): 0x05, ("rear", "off"): 0x06}
GET_DEVICE_INFO = 0x0E

async def main(args):
    dev = await find_bike()
    async with BleakClient(dev, timeout=30) as c:
        got = asyncio.Event()
        def on_notify(_, data: bytearray):
            print(data.decode(errors="replace"))
            got.set()
        await c.start_notify(NUS_TX, on_notify)
        cmds = []
        if args[0] == "status":
            pass
        elif args[0] == "all":
            cmds = [CMD["front", args[1]], CMD["rear", args[1]]]
        else:
            cmds = [CMD[args[0], args[1]]]
        for b in cmds:
            await c.write_gatt_char(NUS_RX, bytes([b]), response=True)
        await c.write_gatt_char(NUS_RX, bytes([GET_DEVICE_INFO]), response=True)
        try:
            await asyncio.wait_for(got.wait(), 5)
        except asyncio.TimeoutError:
            print("(no device info reply)")
        await asyncio.sleep(2)  # reply may span several notifications

if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or ["status"]))
