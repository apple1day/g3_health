#!/usr/bin/env python3
"""Select an installed iPhone simulator; avoid hardcoding a runner's model."""
import json
import subprocess

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
for runtime, candidates in sorted(devices.items(), reverse=True):
    if ".iOS-" not in runtime:
        continue
    for device in candidates:
        if device["name"].startswith("iPhone") and device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator on this runner")
