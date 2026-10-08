"""Locate the Canyon ECLIPS unit for the laptop scripts.

Uses the ECLIPS_ADDR environment variable if set (needed when the unit is
already connected, since it stops advertising), otherwise scans for the unit's
advertised name.
"""
import os
from bleak import BleakScanner

NAME = "Canyon Power Supply"


async def find_bike(timeout: float = 15):
    """Return a BLEDevice, or the configured address string as a fallback."""
    addr = os.environ.get("ECLIPS_ADDR")
    if addr:
        return await BleakScanner.find_device_by_address(addr, timeout=timeout) or addr
    dev = await BleakScanner.find_device_by_name(NAME, timeout=timeout)
    if dev is None:
        raise SystemExit(f'"{NAME}" not found; is it awake? Or set ECLIPS_ADDR=<address>')
    return dev


def address_of(dev) -> str:
    return dev if isinstance(dev, str) else dev.address
