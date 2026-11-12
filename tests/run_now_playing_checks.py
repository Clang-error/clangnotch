#!/usr/bin/env python3
"""Compiles NowPlayingModels.swift with tests/NowPlayingChecks.swift and runs the card policy checks."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="clangnotch-now-playing-checks-") as folder:
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(root / "ClangNotch/Models/NowPlayingModels.swift"),
                    str(root / "tests/NowPlayingChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
