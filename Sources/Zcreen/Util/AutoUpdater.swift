import Cocoa

/// Checks GitHub Releases for new versions. Can download and install updates automatically.
final class AutoUpdater: ObservableObject {
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion = ""
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?

    private(set) var releaseURL: URL?
    private(set) var downloadURL: URL?

    private let currentVersion: String
    private static let repoAPI = "https://api.github.com/repos/chdendi/Zcreen/releases/latest"

    init(autoCheckOnLaunch: Bool = true) {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        // Auto-check on launch (delayed)
        if autoCheckOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.checkIfNeeded()
            }
        }
    }

    // MARK: - Public

    func checkForUpdates() {
        performCheck()
    }

    func openReleasePage() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadAndInstall() {
        // Only works when running from a .app bundle
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.general.warning("Auto-update: not running from .app bundle, opening release page instead")
            openReleasePage()
            return
        }
        guard let downloadURL, !isDownloading else { return }
        isDownloading = true
        errorMessage = nil

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcreenUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            failUpdate(error.localizedDescription)
            return
        }

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] fileURL, response, error in
            guard let self else { try? FileManager.default.removeItem(at: tempDir); return }
            guard let fileURL, error == nil, let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: tempDir)
                self.failUpdate(error?.localizedDescription ?? "Download request failed. Please retry.")
                return
            }
            self.installFromZip(fileURL, tempDir: tempDir)
        }.resume()
    }

    // MARK: - Private: check

    private func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - lastCheck > 24 * 3600 {
            performCheck()
        }
    }

    private func performCheck() {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil

        guard let url = URL(string: Self.repoAPI) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                guard let data, error == nil, let response = response as? HTTPURLResponse,
                      response.statusCode == 200,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.errorMessage = "Could not check for updates. Please retry."
                    return
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

                let remote = release.tagName.hasPrefix("v")
                    ? String(release.tagName.dropFirst())
                    : release.tagName

                if self.isNewer(remote, than: self.currentVersion) {
                    self.updateAvailable = true
                    self.latestVersion = remote
                    self.releaseURL = URL(string: release.htmlURL)
                    self.downloadURL = release.assets
                        .first { $0.name == "Zcreen-v\(remote).zip" }
                        .flatMap { URL(string: $0.browserDownloadURL) }
                    Log.general.info("Update available: \(self.currentVersion) → \(remote)")
                } else {
                    self.updateAvailable = false
                    self.latestVersion = ""
                    self.downloadURL = nil
                    self.releaseURL = nil
                    Log.general.info("Up to date: \(self.currentVersion)")
                }
            }
        }.resume()
    }

    // MARK: - Private: install

    private func installFromZip(_ zipFileURL: URL, tempDir: URL) {
        do {
            let zipPath = tempDir.appendingPathComponent("Zcreen.zip")
            try FileManager.default.moveItem(at: zipFileURL, to: zipPath)

            // Unzip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipPath.path, "-d", tempDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                throw UpdateError.unzipFailed
            }

            // Find .app in extracted contents
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.lastPathComponent == "Zcreen.app" }) else {
                throw UpdateError.noAppFound
            }

            let currentApp = Bundle.main.bundleURL
            let pid = ProcessInfo.processInfo.processIdentifier

            let prepared = try UpdateInstaller().prepare(newApp: newApp, currentApp: currentApp)
            let scriptURL = tempDir.appendingPathComponent("zcreen_update.sh")
            let ready = tempDir.appendingPathComponent("ready")
            let launcher = Process()
            do {
                try UpdateInstaller.replacementScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
                launcher.arguments = [scriptURL.path, String(pid), currentApp.path,
                    prepared.replacement.path, prepared.backup.path, tempDir.path, ready.path, "/usr/bin/open"]
                launcher.standardOutput = FileHandle.nullDevice
                launcher.standardError = FileHandle.nullDevice
                try launcher.run()
                for _ in 0..<50 {
                    if FileManager.default.fileExists(atPath: ready.path) || !launcher.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                guard launcher.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
                    throw UpdateInstaller.InstallerError.helperFailed
                }
            } catch {
                if launcher.isRunning { launcher.terminate(); launcher.waitUntilExit() }
                try? FileManager.default.removeItem(at: prepared.stagingDirectory)
                throw error
            }

            Log.general.info("Auto-update: replacement script launched, terminating app")
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            failUpdate(error.localizedDescription)
        }
    }

    private func failUpdate(_ message: String) {
        Log.general.error("Auto-update failed: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.isDownloading = false
            self?.errorMessage = message
        }
    }

    // MARK: - Helpers

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private enum UpdateError: LocalizedError {
        case unzipFailed, noAppFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Failed to unzip update"
            case .noAppFound: return "No .app found in downloaded archive"
            }
        }
    }
}

// MARK: - GitHub API Model

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Codable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
