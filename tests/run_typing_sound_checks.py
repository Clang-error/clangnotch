#!/usr/bin/env python3
"""Compiles TypingSoundMixer.swift and TypingSoundOutputKind.swift with tests/TypingSoundChecks.swift and runs
the key, mixing and output checks."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="clangnotch-typing-sound-checks-") as folder:
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(root / "ClangNotch/Core/TypingSounds/TypingSoundMixer.swift"),
                    str(root / "ClangNotch/Core/TypingSounds/TypingSoundOutputKind.swift"),
                    str(root / "tests/TypingSoundChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
