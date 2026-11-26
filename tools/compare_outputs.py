#!/usr/bin/env python3
"""Compare Swift output vs Python reference output (and ll.tendies). Structure must match; pixels may differ slightly (different scaler/JPEG encoder)."""
import sys; sys.path.insert(0, __import__("os").path.dirname(__file__))
from verify_tendies import inspect
a, b = inspect(sys.argv[1]), inspect(sys.argv[2])
ll = inspect(sys.argv[3]) if len(sys.argv) > 3 else None
checks = {
  "frame count equal": a["jpg_assets"] == b["jpg_assets"],
  "refs equal frames": a["refs"] == a["jpg_assets"],
  "no missing refs": not a["missing"],
  "frame size equal": a["frame_sizes"] == b["frame_sizes"],
  "duration within 0.01s": abs(float(a["duration"]) - float(b["duration"])) < 0.01,
  "non-asset entries identical": a["non_asset_entries"] == b["non_asset_entries"],
}
if ll: checks["frame count == ll.tendies"] = a["jpg_assets"] == ll["jpg_assets"]
for k, v in checks.items(): print(("PASS " if v else "FAIL ") + k)
sys.exit(0 if all(checks.values()) else 1)
