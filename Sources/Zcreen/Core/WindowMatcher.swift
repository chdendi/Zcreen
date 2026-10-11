import Foundation
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
}

enum WindowMatcher {
    static func match(saved: [WindowSnapshot], running: [WindowMatchCandidate]) -> [WindowMatchAssignment] {
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
            if pair.isLowConfidence && (saved.count > 1 || running.count > 1) { continue }
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
        // strongly suggests "same physical monitor". Penalize a known mismatch to avoid placing a
        // window on the wrong display when the user has multiple displays of the same model.
        if let savedKey = saved.screenKey, let runningKey = running.screenKey {
            if savedKey == runningKey {
                score += 180
            } else {
                score -= 100
            }
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
