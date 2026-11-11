#!/usr/bin/env python3
"""
Zebra ZD421 – read-only and nonpersistent sound probe over the network.
Requires only Python 3. No USB, packages, printer driver, firmware, or admin rights.
Usage:
  py -3 zebra-lydprobe.py 172.30.99.18 info
  py -3 zebra-lydprobe.py 172.30.99.18 beep
  py -3 zebra-lydprobe.py 172.30.99.18 beep_alt
  py -3 zebra-lydprobe.py 172.30.99.18 bel
  py -3 zebra-lydprobe.py 172.30.99.18 rhythm
  py -3 zebra-lydprobe.py 172.30.99.18 info --port 6101
"""
import argparse
import ipaddress
import socket
import sys
import time

TIMEOUT = 2.0
MAX_REPLY = 2048

def connection(ip: str, port: int):
    return socket.create_connection((ip, port), timeout=TIMEOUT)

def send(ip: str, port: int, payload: bytes, expect_reply: bool = False) -> str:
    # One short connection per probe; never leaves a socket open indefinitely.
    with connection(ip, port) as sock:
        sock.settimeout(TIMEOUT)
        sock.sendall(payload)
        if not expect_reply:
            return ""
        chunks = []
        remaining = MAX_REPLY
        while remaining:
            try:
                data = sock.recv(min(remaining, 512))
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)
            remaining -= len(data)
            if b"\n" in data or b"\r" in data:
                break
        return b"".join(chunks).decode("ascii", errors="replace").strip()

def inspect(ip: str, port: int):
    keys = ("device.product_name", "appl.name", "device.languages", "device.alarm.command", "zbi.key", "ip.port", "ip.port_alternate")
    print("Leser skriverinnstillinger (ingen endringer):")
    for key in keys:
        cmd = f'! U1 getvar "{key}"\r\n'.encode("ascii")
        try:
            response = send(ip, port, cmd, expect_reply=True)
            print(f"  {key}: {response or '(intet svar)'}")
        except (TimeoutError, OSError) as ex:
            print(f"  {key}: (nettverksfeil: {ex})")
    print("\nOBS: '?' betyr at innstillingen ikke gjenkjennes,")
    print("ikke nødvendigvis at skriveren mangler fysisk summer.")

def run(ip: str, port: int, mode: str):
    if mode == "info":
        inspect(ip, port)
        return
    # Commands documented for CPCL/Link-OS printers; not proven supported on ZD421.
    commands = {
        "beep": b"! U1 BEEP 8\r\n",     # 1.0 second
        "beep_alt": b"! UTILITIES\r\nBEEP 8\r\nEND\r\n",  # 1.0 second
        "bel": b"\x07",               # ASCII BEL
    }
    if mode == "rhythm":
        print("Sender tre korte pip-forsok (ingen tonehoyde-kontroll):")
        for idx, ticks in enumerate((2, 1, 2), start=1):
            payload = f"! U1 BEEP {ticks}\r\n".encode("ascii")
            send(ip, port, payload)
            print(f"  Forsok {idx}: {ticks * 0.125:g} s")
            time.sleep(ticks * 0.125 + 0.20)
        print("Sendt. Lytt ved skriveren; dette bekrefter ikke at den lagde lyd.")
    else:
        send(ip, port, commands[mode])
        print(f"{mode}: Kommando sendt over TCP {ip}:{port}.")
        print("Observer skriveren. En vellykket TCP-sending betyr IKKE at kommandoen ble utfort.")

def main():
    p = argparse.ArgumentParser(description="ZD421: sikker, avgrenset lydtest over nettverk")
    p.add_argument("ip", help="IP til DIN testskriver")
    p.add_argument("mode", choices=("info", "beep", "beep_alt", "bel", "rhythm"),
                   help="info er skrivebeskyttet; de andre ber om korte pip")
    p.add_argument("--port", type=int, choices=(9100, 6101), default=9100,
                   help="rå TCP-port. 6101 er valgfritt alternativ der den er aktivert")
    args = p.parse_args()
    try:
        ip = ipaddress.ip_address(args.ip)
        if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast:
            p.error("Bruk en privat IPv4-adresse til skriveren.")
    except ValueError:
        p.error("Ugyldig IPv4-adresse.")
    print(f"Skriver: {ip}:{args.port} · Modus: {args.mode}")
    print("Dette programmet laster ikke opp firmware og endrer ikke varige innstillinger.")
    try:
        run(str(ip), args.port, args.mode)
    except (TimeoutError, OSError) as ex:
        print(f"Nettverksfeil: {ex}", file=sys.stderr)
        print("Kontroller tilgang til porten, og forsok eventuelt --port 6101.", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
