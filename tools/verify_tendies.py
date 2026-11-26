#!/usr/bin/env python3
"""MJ Wallpaper - .tendies structural verifier (read-only).
Usage: verify_tendies.py file.tendies [reference.tendies]"""
import sys, re, zipfile, struct

def jpeg_size(data):
    i = 2
    while i < len(data):
        if data[i] != 0xFF: i += 1; continue
        m = data[i+1]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i+5:i+9]); return w, h
        i += 2 + struct.unpack(">H", data[i+2:i+4])[0]
    return None

def inspect(path):
    z = zipfile.ZipFile(path)
    r = {"path": path, "testzip": z.testzip(), "entries": len(z.namelist())}
    bp = next(n for n in z.namelist() if "Background" in n and n.endswith("main.caml"))
    ad = bp.rsplit("/", 1)[0] + "/assets/"
    caml = z.read(bp).decode()
    refs = re.findall(r'<CGImage src="([^"]+)"', caml)
    names = set(z.namelist())
    r["refs"] = len(refs)
    r["missing"] = [x for x in refs if ad + x.replace("assets/", "") not in names]
    jpgs = [n for n in z.namelist() if n.startswith(ad) and n.lower().endswith(".jpg")]
    r["jpg_assets"] = len(jpgs)
    r["frame_sizes"] = sorted({jpeg_size(z.read(n)) for n in jpgs})
    m = re.search(r'<animation\b[^>]*\bduration="([^"]+)"', caml)
    r["duration"] = m.group(1) if m else None
    r["non_asset_entries"] = sorted(n for n in z.namelist() if not (n.startswith(ad) and n.lower().endswith(".jpg")))
    return r

if __name__ == "__main__":
    a = inspect(sys.argv[1])
    for k, v in a.items():
        if k != "non_asset_entries": print(f"{k}: {v}")
    ok = a["testzip"] is None and not a["missing"] and a["refs"] == a["jpg_assets"]
    if len(sys.argv) > 2:
        b = inspect(sys.argv[2])
        same = a["non_asset_entries"] == b["non_asset_entries"]
        print("non-asset entry names identical to reference:", same)
        ok = ok and same
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
