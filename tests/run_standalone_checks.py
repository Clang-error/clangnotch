#!/usr/bin/env python3
"""Compiles each stand-alone Swift check with the app sources it exercises and runs it.

The checks need one or two names the rest of the app normally provides (`L`, `DemoMode`,
`debugLog`); those are stood in for here. No network, Keychain or iPad is touched: the T world
check answers its own requests and the Sidecar check runs without `--live`.
"""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
L = "func L(_ korean: String, _ english: String) -> String { korean }\n"
DEMO = "enum DemoMode { static let isActive = false }\n"
LOG = "func debugLog(_ message: @autoclosure () -> String) {}\n"

checks = [
    ("TWorldChecks", ["ClangNotch/Core/Network/TWorldClient.swift"], L),
    ("SidecarChecks", ["ClangNotch/Core/Sidecar/SidecarClient.swift",
                       "ClangNotch/Core/Sidecar/SidecarManager.swift"], L + DEMO),
    # Defines `debugLog` itself.
    ("SessionAppChecks", ["ClangNotch/Core/Coordinators/SessionAppLauncher.swift",
                          "ClangNotch/Core/Coordinators/SessionAppResolver.swift",
                          "ClangNotch/Models/ClaudeCodeModels.swift",
                          "ClangNotch/Models/AgentInputModels.swift"], L),
    ("ClaudeQuestionHookChecks", ["ClangNotch/Core/ClaudeCode/ClaudeQuestionHooks.swift"], ""),
    ("ClaudeNotificationHookChecks", ["ClangNotch/Core/ClaudeCode/ClaudeNotificationHooks.swift"], ""),
    ("NextStepHookChecks", ["ClangNotch/Core/Permission/NextStepHooks.swift"], ""),
]

with tempfile.TemporaryDirectory(prefix="clangnotch-standalone-checks-") as folder:
    for name, sources, stand_ins in checks:
        stub = Path(folder) / f"{name}StandIns.swift"
        stub.write_text("import Foundation\n" + stand_ins)
        binary = Path(folder) / name
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        *[str(root / source) for source in sources],
                        str(root / "tests" / f"{name}.swift"), str(stub), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
