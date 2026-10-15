"""Inspect the actual Release IPA; no Xcode, external packages or extracted files needed."""
import argparse
import hashlib
import json
import plistlib
import struct
from pathlib import Path, PurePosixPath
from zipfile import ZipFile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def macho_details(binary):
    require(len(binary) > 4096, "Executable missing or implausibly small")
    magic, cpu, subtype, filetype, count, size, flags, reserved = struct.unpack_from("<8I", binary)
    require(magic == 0xFEEDFACF, "Expected thin 64-bit Mach-O")
    require(cpu == 0x0100000C, "Executable must be ARM64")
    require(filetype == 2, "Mach-O must be an executable")
    require(size < len(binary) - 32 and count < 4096, "Malformed Mach-O load commands")
    offset = 32
    platforms, dylibs = [], []
    code_signature = False
    for _ in range(count):
        command, length = struct.unpack_from("<II", binary, offset)
        require(length >= 8 and offset + length <= 32 + size, "Truncated load command")
        if command == 0x32:  # LC_BUILD_VERSION; platform 2=iOS, 7=iOS Simulator.
            require(length >= 24, "Truncated build version")
            platforms.append(struct.unpack_from("<I", binary, offset + 8)[0])
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            name_offset = struct.unpack_from("<I", binary, offset + 8)[0]
            require(name_offset < length, "Invalid dylib name offset")
            raw = binary[offset + name_offset:offset + length].split(b"\0", 1)[0]
            dylibs.append(raw.decode("utf-8", errors="strict"))
        if command == 0x1D:
            code_signature = True
        offset += length
    require(offset == 32 + size, "Load command size mismatch")
    require(platforms and set(platforms) == {2}, "Mach-O must target iOS device, not simulator")
    for library in dylibs:
        require(library.startswith(("/System/Library/", "/usr/lib/", "@rpath/libswift")),
                "Unexpected non-Apple dynamic dependency: " + library)
    require(b"--ui-testing" not in binary, "Debug test launch switch found in Release binary")
    require(b"prepareDemo" not in binary, "Debug demo fixture function found in Release binary")
    return {"architecture": "arm64", "macho_platform": "iOS device", "dynamic_dependencies": dylibs,
            "has_code_signature_command": code_signature, "debug_fixture_markers_absent": True}


def verify(path):
    with ZipFile(path) as archive:
        require(archive.testzip() is None, "Corrupt ZIP member")
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP paths")
        require(all(not n.startswith("/") and ".." not in PurePosixPath(n).parts for n in names), "Unsafe ZIP paths")
        infos = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        require(len(infos) == 1, "Expected one application inside Payload")
        prefix = infos[0][:-len("Info.plist")]
        info = plistlib.loads(archive.read(infos[0]))
        require(info.get("CFBundleIdentifier") == "br.com.provisoriojon.noponto", "Wrong bundle identifier")
        require(info.get("CFBundleDisplayName") == "No Ponto", "Wrong display name")
        require(info.get("CFBundlePackageType") == "APPL", "Wrong bundle type")
        require(info.get("DTPlatformName") == "iphoneos" and "iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "Not an iPhoneOS build")
        require(info.get("UIDeviceFamily") == [1], "Expected iPhone application")
        require(info.get("MinimumOSVersion") == "17.0", "Unexpected minimum iOS version")
        require(bool(info.get("CFBundleShortVersionString")) and bool(info.get("CFBundleVersion")), "Missing version")
        require(bool(info.get("NSLocationWhenInUseUsageDescription")), "Missing location explanation")
        binary = archive.read(prefix + info["CFBundleExecutable"])
        executable = macho_details(binary)
        asset_path = prefix + "Assets.car"
        require(asset_path in names and len(archive.read(asset_path)) > 1024, "Compiled asset catalog missing")
        icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
        require(icon.get("CFBundleIconName") == "AppIcon", "AppIcon not declared in compiled Info.plist")
        declarations = icon.get("CFBundleIconFiles", [])
        pngs = [n for n in names if n.startswith(prefix) and n.count("/") == 2 and n.lower().endswith(".png")]
        require(declarations and pngs, "Declared app icon PNGs missing")
        for declaration in declarations:
            require(any(PurePosixPath(n).name.startswith(declaration) for n in pngs), "No icon PNG for " + declaration)
        for png in pngs:
            require(archive.read(png).startswith(b"\x89PNG\r\n\x1a\n"), "Invalid PNG asset " + png)
        catalog = json.loads(archive.read(prefix + "catalog.json"))
        require(catalog.get("schemaVersion") == 1, "Wrong catalog schema")
        routes, stops, patterns = catalog["routes"], catalog["stops"], catalog["patterns"]
        require(len(routes) >= 494 and len(stops) >= 7000 and patterns, "Incomplete bundled municipal catalog")
        require(len({r["id"] for r in routes}) == len(routes), "Duplicate route IDs")
        require({"369", "397", "SR397"}.issubset({r["shortName"] for r in routes}), "Reference routes missing")
        require(any(r["mode"] == "brt" for r in routes), "BRT catalog missing")
        require("https://dados.mobilidade.rio/" in catalog["sourceURL"], "Catalog must retain official source")
        privacy = plistlib.loads(archive.read(prefix + "PrivacyInfo.xcprivacy"))
        require(privacy.get("NSPrivacyTracking") is False, "Tracking must be disabled")
        require(any(p.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults" and "CA92.1" in p.get("NSPrivacyAccessedAPITypeReasons", []) for p in privacy.get("NSPrivacyAccessedAPITypes", [])), "UserDefaults privacy reason missing")
        frameworks = [n for n in names if ".framework/" in n]
        require(not frameworks, "Unexpected embedded third-party framework(s)")
        require(not any(n.endswith((".xctest", ".swift")) or ".xctest/" in n for n in names), "Test/source files inside Release bundle")
        return {
            "verified": True, "file": path.name, "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bundle_identifier": info["CFBundleIdentifier"], "display_name": info["CFBundleDisplayName"],
            "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "minimum_ios": info["MinimumOSVersion"], "sdk": info.get("DTSDKName"),
            "icons": [PurePosixPath(n).name for n in pngs], "assets_car_bytes": len(archive.read(asset_path)),
            "catalog_routes": len(routes), "catalog_stops": len(stops), "catalog_patterns": len(patterns),
            "embedded_frameworks": [], "privacy_manifest_verified": True, **executable,
            "apple_distribution_signature_verified": False, "physical_installation_verified": False,
            "note": "Device build inspected. Signing, physical installation and field GPS/ETA accuracy require separate validation."
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(verify(args.ipa), ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(report + "\n", encoding="utf-8")
    print(report)
