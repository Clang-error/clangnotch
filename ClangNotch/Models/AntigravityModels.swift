//
//  AntigravityModels.swift
//  ClangNotch
//
//  Minimal state for Antigravity (Gemini) CLI activity shown in the notch.
//

import Foundation

/// One transcript step surfaced in the expanded notch (e.g. "Running command").
struct AntigravityStep: Identifiable, Equatable {
    let id: Int          // step_index
    let label: String    // "Thinking" / "Running command" / "Reading file" / "Editing"
    let isRunning: Bool
}

/// Lightweight activity state parsed from Antigravity CLI transcripts.
struct AntigravityState: Equatable {
    /// True while a step is RUNNING or the transcript was just written.
    var isActive: Bool = false
    /// Human-readable current step, e.g. "Thinking", "Running command".
    var currentAction: String?
    /// Most-recent-first list of recent steps for the expanded view.
    var recentSteps: [AntigravityStep] = []
    /// True if the transcript was touched recently (used to keep the Recent Tools
    /// section visible for a while after a turn ends, not just while live-active).
    var recentlyUsed: Bool = false
}
