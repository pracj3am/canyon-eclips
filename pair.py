"""Bond this computer with the ECLIPS unit.  Usage: pair.py <PIN>
PIN = last 6 digits of the ECLIPS system serial number (Quick Start Guide / frame).
The unit is found by name, or set ECLIPS_ADDR=<address>."""
import asyncio, pexpect, sys, time

from bike import address_of, find_bike

ADDR = address_of(asyncio.run(find_bike()))
print(f"pairing with {ADDR}")
pin = sys.argv[1]
p = pexpect.spawn("bluetoothctl", encoding="utf-8", timeout=30)
p.logfile_read = sys.stdout
p.sendline("agent KeyboardDisplay"); p.sendline("default-agent")
p.sendline("scan le"); time.sleep(6); p.sendline("scan off"); time.sleep(1)
p.sendline(f"pair {ADDR}")
while True:
    i = p.expect([r"Enter passkey", r"\(yes/no\)", "Pairing successful", "Failed to pair.*", pexpect.TIMEOUT])
    if i == 0: p.sendline(pin)
    elif i == 1: p.sendline("yes")
    else: break
time.sleep(1); p.sendline(f"trust {ADDR}"); time.sleep(1); p.sendline("quit")
