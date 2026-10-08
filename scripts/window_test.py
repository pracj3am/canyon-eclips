# Register a BlueZ agent that stalls RequestPasskey (link stays up, unencrypted),
# and meanwhile try GATT ops with bleak on the same connection.
# Run with this computer NOT bonded to the unit (bluetoothctl remove <address>).
# Result on FW 0.1.2: write-without-response is accepted but has no effect;
# write-with-response and notify subscription stall waiting for encryption.
import asyncio, pathlib, sys, time
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method
from dbus_fast import BusType, DBusError
from bleak import BleakClient

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from bike import find_bike  # noqa: E402

NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
t0 = time.time()
def log(*a): print(f"{time.time()-t0:6.2f}s", *a, flush=True)

class Agent(ServiceInterface):
    def __init__(self): super().__init__("org.bluez.Agent1")
    @method()
    def Release(self): pass
    @method()
    async def RequestPasskey(self, device: 'o') -> 'u':
        log("agent: RequestPasskey -> stalling"); await asyncio.sleep(28)
        raise DBusError("org.bluez.Error.Rejected", "stalled")
    @method()
    async def RequestConfirmation(self, device: 'o', passkey: 'u'):
        log("agent: RequestConfirmation", passkey); await asyncio.sleep(28)
        raise DBusError("org.bluez.Error.Rejected", "stalled")
    @method()
    def Cancel(self): log("agent: Cancel")

async def main():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    bus.export("/test/agent", Agent())
    intro = await bus.introspect("org.bluez", "/org/bluez")
    mgr = bus.get_proxy_object("org.bluez", "/org/bluez", intro).get_interface("org.bluez.AgentManager1")
    await mgr.call_register_agent("/test/agent", "KeyboardDisplay")
    await mgr.call_request_default_agent("/test/agent")
    log("agent registered")
    dev = await find_bike()
    try:
        async with BleakClient(dev, timeout=40) as c:
            log("connected, services:", len(c.services.services))
            ops = [("write-cmd rear on", lambda: c.write_gatt_char(NUS_RX, b"\x05", response=False)),
                   ("write-req rear on", lambda: c.write_gatt_char(NUS_RX, b"\x05", response=True)),
                   ("notify TX", lambda: c.start_notify(NUS_TX, lambda _, d: log("notify:", bytes(d)[:40])))]
            for name, op in ops:
                try: log(name, "->", await asyncio.wait_for(op(), 8))
                except Exception as e: log(name, "FAILED:", type(e).__name__, e)
            await asyncio.sleep(3)
    except Exception as e:
        log("connect/discovery failed:", e)

asyncio.run(main())
