#!/usr/bin/env python3
"""Print LC_BUILD_VERSION (platform, minos, sdk) of Mach-O binaries (thin or fat).

[liquid-glass] AppKit gates the Liquid Glass design and macOS 27 behaviours on the SDK a
binary was LINKED against (LC_BUILD_VERSION.sdk); minos is the oldest macOS it runs on.
Works anywhere Python runs (no otool / vtool needed, e.g. on Linux):

    apps/zeron/scripts/macho-build-version.py zig-out/bin/zeron
    apps/zeron/scripts/macho-build-version.py --expect-sdk 27.0 --expect-minos 12.0 zeron

Exit status 1 when a binary has no LC_BUILD_VERSION or an --expect-* check fails.
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 6: "maccatalyst", 7: "iossimulator", 11: "visionos"}
CPUS = {0x01000007: "x86_64", 0x0100000C: "arm64"}


def ver(v):
    major, minor, patch = v >> 16, (v >> 8) & 0xFF, v & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def thin(data, off, label):
    magic = struct.unpack_from("<I", data, off)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        raise ValueError(f"{label}: not a Mach-O (magic {magic:#x})")
    is64 = magic == 0xFEEDFACF
    cputype, _, _, ncmds, _, _ = struct.unpack_from("<iiIIII", data, off + 4)
    p = off + (32 if is64 else 28)
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, p)
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk, _ = struct.unpack_from("<IIII", data, p + 8)
            out.append({"arch": CPUS.get(cputype, hex(cputype)), "platform": PLATFORMS.get(platform, str(platform)), "minos": ver(minos), "sdk": ver(sdk)})
        elif cmd == LC_VERSION_MIN_MACOSX:
            minos, sdk = struct.unpack_from("<II", data, p + 8)
            out.append({"arch": CPUS.get(cputype, hex(cputype)), "platform": "macos (LC_VERSION_MIN)", "minos": ver(minos), "sdk": ver(sdk)})
        p += size
    return out


def build_versions(path):
    data = open(path, "rb").read()
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat (big-endian header)
        n = struct.unpack_from(">I", data, 4)[0]
        res = []
        for i in range(n):
            if magic == 0xCAFEBABE:
                _, _, off, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            else:
                _, _, off, _, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            res += thin(data, off, path)
        return res
    return thin(data, 0, path)


def main(argv):
    expect_sdk = expect_minos = None
    paths = []
    it = iter(argv)
    for a in it:
        if a == "--expect-sdk":
            expect_sdk = next(it)
        elif a == "--expect-minos":
            expect_minos = next(it)
        else:
            paths.append(a)
    if not paths:
        print(__doc__)
        return 2
    ok = True
    for path in paths:
        bvs = build_versions(path)
        if not bvs:
            print(f"{path}: no LC_BUILD_VERSION")
            ok = False
        for bv in bvs:
            print(f"{path}: {bv['arch']} platform={bv['platform']} minos={bv['minos']} sdk={bv['sdk']}")
            if expect_sdk and bv["sdk"] != expect_sdk:
                print(f"FAIL: {path} ({bv['arch']}): sdk {bv['sdk']} != {expect_sdk}")
                ok = False
            if expect_minos and bv["minos"] != expect_minos:
                print(f"FAIL: {path} ({bv['arch']}): minos {bv['minos']} != {expect_minos}")
                ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
