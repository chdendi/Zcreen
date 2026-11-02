import Foundation
import ApplicationServices
import CoreGraphics

struct WindowMatchCandidate {
    let title: String?
    let frame: CGRect
    let screenName: String
    let screenKey: String?
    let role: String?
    let subrole: String?

    init(title: String?, frame: CGRect, screenName: String, screenKey: String? = nil,
         role: String?, subrole: String?) {
        self.title = title
        self.frame = frame
        self.screenName = screenName
        self.screenKey = screenKey
        self.role = role
        self.subrole = subrole
    }
}

struct WindowMatchAssignment {
    let savedIndex: Int
    let runningIndex: Int
    let score: Int

    var isLowConfidence: Bool {
        score < 200
    }

    /// Paired because the running window is the same AX element the saved entry was captured from.
    var isIdentity: Bool {
        score >= WindowMatcher.identityScore
    }
}

enum WindowMatcher {
    static let identityScore = 10_000

    /// Pairs saved and running windows, trusting element identity before any heuristic.
    ///
    /// Display changes rarely restart apps, so a window still running since it was saved
    /// is the same AX element. That pairing survives title changes and macOS moving or
    /// shrinking the window, which is exactly when the heuristics below are least reliable.
    /// `savedElements` is aligned with `saved`; `runningElements` with `running`.
    static func match(saved: [WindowSnapshot], running: [WindowMatchCandidate],
                      savedElements: [AXUIElement?], runningElements: [AXUIElement]) -> [WindowMatchAssignment] {
        var assignments: [WindowMatchAssignment] = []
        var usedSaved = Set<Int>()
        var usedRunning = Set<Int>()

        for (savedIndex, element) in savedElements.enumerated() where savedIndex < saved.count {
            guard let element,
                  let runningIndex = runningElements.indices.first(where: { index in
                      index < running.count && !usedRunning.contains(index) && CFEqual(runningElements[index], element)
                  })
            else { continue }
            assignments.append(WindowMatchAssignment(savedIndex: savedIndex, runningIndex: runningIndex, score: identityScore))
            usedSaved.insert(savedIndex)
            usedRunning.insert(runningIndex)
        }

        let remainingSaved = saved.indices.filter { !usedSaved.contains($0) }
        let remainingRunning = running.indices.filter { !usedRunning.contains($0) }
        // Strictness follows the full group: identity pairing must not turn an ambiguous
        // leftover into a "only candidate" match.
        let heuristic = match(saved: remainingSaved.map { saved[$0] }, running: remainingRunning.map { running[$0] },
                              allowLowConfidence: saved.count <= 1 && running.count <= 1)
        assignments += heuristic.map {
            WindowMatchAssignment(savedIndex: remainingSaved[$0.savedIndex],
                                  runningIndex: remainingRunning[$0.runningIndex],
                                  score: $0.score)
        }
        return assignments
    }

    static func match(saved: [WindowSnapshot], running: [WindowMatchCandidate]) -> [WindowMatchAssignment] {
        match(saved: saved, running: running, allowLowConfidence: saved.count <= 1 && running.count <= 1)
    }

    private static func match(saved: [WindowSnapshot], running: [WindowMatchCandidate],
                              allowLowConfidence: Bool) -> [WindowMatchAssignment] {
        // Compute every (saved, running) pair once, then greedily pick best-score pairs while
        // skipping already-claimed indices and ambiguous weak matches.
        // O(N² log N) instead of repeatedly scanning for the maximum in O(N³).
        var pairs: [WindowMatchAssignment] = []
        pairs.reserveCapacity(saved.count * running.count)
        for savedIndex in saved.indices {
            for runningIndex in running.indices {
                let s = score(saved: saved[savedIndex], running: running[runningIndex])
                pairs.append(WindowMatchAssignment(savedIndex: savedIndex, runningIndex: runningIndex, score: s))
            }
        }
        pairs.sort { $0.score > $1.score }

        var usedSaved = Set<Int>()
        var usedRunning = Set<Int>()
        var assignments: [WindowMatchAssignment] = []
        let limit = min(saved.count, running.count)
        assignments.reserveCapacity(limit)

        for pair in pairs {
            if assignments.count == limit { break }
            // Weak unnamed-window matches remain useful, but contradictory evidence
            // must not force a new document into an unrelated saved window's slot.
            if pair.score <= 0 { break }
            if pair.isLowConfidence && !allowLowConfidence { continue }
            if usedSaved.contains(pair.savedIndex) || usedRunning.contains(pair.runningIndex) { continue }
            assignments.append(pair)
            usedSaved.insert(pair.savedIndex)
            usedRunning.insert(pair.runningIndex)
        }

        return assignments
    }

    static func score(saved: WindowSnapshot, running: WindowMatchCandidate) -> Int {
        var score = 0

        let savedTitle = normalized(saved.windowTitle)
        let runningTitle = normalized(running.title)

        if let savedTitle {
            if let runningTitle {
                if savedTitle == runningTitle {
                    score += 1000
                } else if savedTitle.contains(runningTitle) || runningTitle.contains(savedTitle) {
                    score += 400
                } else {
                    score -= 250
                }
            } else {
                score -= 100
            }
        }

        if let role = saved.windowRole, role == running.role {
            score += 120
        }

        if let subrole = saved.windowSubrole, subrole == running.subrole {
            score += 60
        }

        // screenKey is the strongest screen signal — it is the persistent display ID, so a match
        // strongly suggests "same physical monitor" and separates same-titled windows on
        // displays of the same model. A mismatch is deliberately not penalized: after a display
        // change the running window's screen is wherever macOS evicted it to, so a penalty
        // would mostly push correct pairings below the confidence threshold.
        if let savedKey = saved.screenKey, let runningKey = running.screenKey, savedKey == runningKey {
            score += 180
        }

        if saved.screenName == running.screenName {
            score += 20
        }

        let sizeDelta = abs(saved.frame.width - Double(running.frame.width)) +
            abs(saved.frame.height - Double(running.frame.height))
        score += max(0, 120 - Int(sizeDelta.rounded()))

        return score
    }

    private static func normalized(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
