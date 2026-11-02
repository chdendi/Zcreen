import AppKit
import Combine

struct DiskSpaceSnapshot: Equatable, Sendable {
    let availableBytes: Int64
    let totalBytes: Int64

    init?(availableBytes: Int64, totalBytes: Int64) {
        guard totalBytes > 0, availableBytes >= 0, availableBytes <= totalBytes else { return nil }
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    var isLow: Bool {
        // Equivalent to availableBytes * 10 < totalBytes, without overflow.
        availableBytes <= (totalBytes - 1) / 10
    }

    static func read() -> Self? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsLocalKey
        ]), values.volumeIsLocal == true,
              let available = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity else { return nil }
        return Self(availableBytes: Int64(available), totalBytes: Int64(total))
    }
}

@MainActor
final class DiskSpaceMonitor: ObservableObject {
    @Published private(set) var snapshot: DiskSpaceSnapshot?
    private let load: @Sendable () -> DiskSpaceSnapshot?
    private var generation: UInt64 = 0
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(startMonitoring: Bool = true,
         load: @escaping @Sendable () -> DiskSpaceSnapshot? = { DiskSpaceSnapshot.read() }) {
        self.load = load
        if startMonitoring {
            refresh()
            let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func refresh() {
        generation &+= 1
        let request = generation
        let loader = load
        Task { [weak self] in
            let value = await Task.detached(priority: .utility) { loader() }.value
            guard let self, self.generation == request else { return }
            self.snapshot = value
        }
    }
}
