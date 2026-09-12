#!/usr/bin/env python3
"""Create a UTM .utm package (config.plist) for an Inferno VM.

The package holds UTM's plumbing config only (display + built-in serial terminal so the app shows
the VM and Terminal views). The Inferno machine itself is described by Data/inferno.json, which
UTMQemuVirtualMachine.infernoMachineArguments() reads at launch.

Usage: make_utm_package.py <output.utm> [--name NAME] [--memory MB] [--cpus N] [--data DIR]
  --data DIR  copy the VM files (disks, boot files, inferno.json) from DIR into <output.utm>/Data
"""
import argparse
import os
import plistlib
import shutil
import sys
import uuid


def build_config(name: str, memory_mb: int, cpus: int) -> dict:
    # Every key below is decoded with `decode` (required) by UTM's Configuration/*.swift.
    return {
        "Backend": "QEMU",
        "ConfigurationVersion": 4,
        "Information": {
            "Name": name,
            "Icon": "iphone",
            "IconCustom": False,
            "UUID": str(uuid.uuid4()).upper(),
        },
        "System": {
            "Architecture": "aarch64",
            "Target": "virt",  # unused for Inferno VMs; must be a valid aarch64 target to decode
            "CPU": "default",
            "CPUFlagsAdd": [],
            "CPUFlagsRemove": [],
            "CPUCount": cpus,
            "ForceMulticore": False,
            "MemorySize": memory_mb,
            "JITCacheSize": 0,
        },
        "QEMU": {
            "DebugLog": False,
            "UEFIBoot": False,
            "RNGDevice": False,
            "BalloonDevice": False,
            "TPMDevice": False,
            "Hypervisor": False,
            "RTCLocalTime": False,
            "PS2Controller": False,
            "AdditionalArguments": [],
        },
        "Input": {
            "UsbBusSupport": "Disabled",
            "UsbSharing": False,
            "MaximumUsbShare": 0,
        },
        "Sharing": {
            "DirectoryShareMode": "None",
            "DirectoryShareReadOnly": False,
            "ClipboardSharing": False,
        },
        "Display": [
            {
                "Hardware": "virtio-ramfb",  # not passed to QEMU for Inferno VMs; keeps the display view
                "DynamicResolution": False,
                "UpscalingFilter": "Nearest",
                "DownscalingFilter": "Linear",
                "NativeResolution": True,
            }
        ],
        "Drive": [],
        "Network": [],
        "Serial": [
            {
                "Mode": "Terminal",  # built-in terminal -> the app's Terminal (live log) view
                "Target": "Auto",
            }
        ],
        "Sound": [],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--name", default="iPhone 11 (iOS 14)")
    ap.add_argument("--memory", type=int, default=2048)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--data")
    args = ap.parse_args()

    pkg = args.output
    if not pkg.endswith(".utm"):
        print("output must end in .utm", file=sys.stderr)
        return 1
    data_dir = os.path.join(pkg, "Data")
    os.makedirs(data_dir, exist_ok=True)

    with open(os.path.join(pkg, "config.plist"), "wb") as f:
        plistlib.dump(build_config(args.name, args.memory, args.cpus), f, fmt=plistlib.FMT_XML)

    if args.data:
        for entry in os.listdir(args.data):
            src = os.path.join(args.data, entry)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(data_dir, entry))
        if not os.path.exists(os.path.join(data_dir, "inferno.json")):
            print("warning: no inferno.json in Data; UTM will treat this as a normal VM", file=sys.stderr)

    print(f"created {pkg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
