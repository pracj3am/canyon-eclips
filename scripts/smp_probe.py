"""Read-only McuMgr/SMP probe of the ECLIPS unit. Sends only op=READ requests."""
import asyncio, pathlib, struct, sys, cbor2
from bleak import BleakClient

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from bike import find_bike  # noqa: E402

SMP_CHAR = "da2e7828-fbce-4e01-ae9e-261174997c48"
OP_READ = 0

# (label, group, command id, payload) -- all READ operations
PROBES = [
    ("enum: group count",   10, 0, {}),
    ("enum: group list",    10, 1, {}),
    ("os: mcumgr params",    0, 6, {}),
    ("os: app info",         0, 7, {"format": "a"}),
    ("os: bootloader info",  0, 8, {}),
    ("os: datetime",         0, 4, {}),
    ("os: task stats",       0, 2, {}),
    ("os: mem pools",        0, 3, {}),
    ("img: state",           1, 0, {}),
    ("stat: list",           2, 1, {}),
]

class Smp:
    def __init__(self, c):
        self.c, self.buf, self.seq, self.q = c, b"", 0, asyncio.Queue()
    def on_notify(self, _, data):
        self.buf += bytes(data)
        while len(self.buf) >= 8:
            ln = struct.unpack(">H", self.buf[2:4])[0]
            if len(self.buf) < 8 + ln: break
            pkt, self.buf = self.buf[:8 + ln], self.buf[8 + ln:]
            self.q.put_nowait(pkt)
    async def read(self, group, cid, payload):
        body = cbor2.dumps(payload)
        self.seq = (self.seq + 1) & 0xFF
        hdr = struct.pack(">BBHHBB", OP_READ, 0, len(body), group, self.seq, cid)
        await self.c.write_gatt_char(SMP_CHAR, hdr + body, response=False)
        pkt = await asyncio.wait_for(self.q.get(), 5)
        op, fl, ln, grp, seq, rid = struct.unpack(">BBHHBB", pkt[:8])
        return cbor2.loads(pkt[8:]) if ln else {}

async def main():
    dev = await find_bike()
    async with BleakClient(dev, timeout=30) as c:
        smp = Smp(c)
        await c.start_notify(SMP_CHAR, smp.on_notify)
        for label, g, cid, p in PROBES:
            try:
                r = await smp.read(g, cid, p)
            except asyncio.TimeoutError:
                r = "(no reply)"
            print(f"{label:22s} {r}", flush=True)

asyncio.run(main())
