import Foundation
import Combine

final class CaffeinateManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isIndefinite = false
    @Published private(set) var remainingMinutes = 0

    private let caffeinateExecutableURL: URL
    private var process: Process?
    private var countdownTimer: Timer?

    static let durations: [(label: String, minutes: Int)] = [
        ("1h", 60),
        ("2h", 120),
        ("4h", 240),
    ]

    init(caffeinateExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/caffeinate")) {
        self.caffeinateExecutableURL = caffeinateExecutableURL
    }

    func activate(minutes: Int) {
        start(arguments: ["-d", "-i", "-t", "\(minutes * 60)"], minutes: minutes, indefinite: false)
    }

    func activateIndefinitely() {
        start(arguments: ["-d", "-i"], minutes: 0, indefinite: true)
    }

    private func start(arguments: [String], minutes: Int, indefinite: Bool) {
        deactivate()

        let proc = Process()
        proc.executableURL = caffeinateExecutableURL
        proc.arguments = arguments

        do {
            try proc.run()
            process = proc
            isActive = true
            isIndefinite = indefinite
            remainingMinutes = minutes

            if !indefinite {
                let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.remainingMinutes -= 1
                    if self.remainingMinutes <= 0 {
                        self.deactivate()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                countdownTimer = timer
            }

            let duration = indefinite ? "until stopped" : "for \(minutes) minutes"
            Log.general.info("Caffeinate started \(duration)")
        } catch {
            Log.general.error("Failed to start caffeinate: \(error.localizedDescription)")
        }
    }

    func deactivate() {
        process?.terminate()
        process = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        isActive = false
        isIndefinite = false
        remainingMinutes = 0
    }

    deinit {
        deactivate()
    }
}
