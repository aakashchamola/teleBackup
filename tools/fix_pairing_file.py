#!/usr/bin/env python3
"""
Splits an ambiguous pairing file exported from iloader into clean
Remote Pairing (RPPairing) and Lockdown plists for SideStore on iOS 17+.
"""

import sys
import plistlib
from pathlib import Path

def split_pairing_file(input_path: str):
    p = Path(input_path)
    if not p.exists():
        print(f"Error: file not found: {input_path}")
        sys.exit(1)

    with open(p, "rb") as f:
        data = plistlib.load(f)

    # 1. Clean Remote Pairing plist (for iOS 17+ / iPhone 14/15)
    rp_keys = ["identifier", "private_key", "public_key", "alt_irk"]
    rp_data = {k: data[k] for k in rp_keys if k in data}

    out_rp = p.parent / "PairingFile_RemoteRP.plist"
    with open(out_rp, "wb") as f:
        plistlib.dump(rp_data, f)
    print(f"Created clean Remote Pairing file: {out_rp}")

    # 2. Clean Lockdown plist (fallback for legacy iOS)
    lockdown_keys = [
        "RootCertificate", "EscrowBag", "SystemBUID", "HostCertificate",
        "WiFiMACAddress", "DeviceCertificate", "UDID", "HostID",
        "RootPrivateKey", "HostPrivateKey"
    ]
    lockdown_data = {k: data[k] for k in lockdown_keys if k in data}

    out_ld = p.parent / "PairingFile_Lockdown.plist"
    with open(out_ld, "wb") as f:
        plistlib.dump(lockdown_data, f)
    print(f"Created clean Lockdown file: {out_ld}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 tools/fix_pairing_file.py <path/to/pairingFile.plist>")
        sys.exit(1)
    split_pairing_file(sys.argv[1])

