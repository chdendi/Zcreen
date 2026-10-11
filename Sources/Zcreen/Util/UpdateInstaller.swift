import Foundation
import Security

struct UpdateInstaller {
    struct PreparedUpdate {
        let stagingDirectory: URL
        let replacement: URL
        let backup: URL
    }

    private let validate: (URL, URL) throws -> Void

    init(validate: @escaping (URL, URL) throws -> Void = UpdateInstaller.validateSignature) {
        self.validate = validate
    }

    func prepare(newApp: URL, currentApp: URL) throws -> PreparedUpdate {
        try validate(newApp, currentApp)
        let directory = currentApp.deletingLastPathComponent().appendingPathComponent(".ZcreenUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let replacement = directory.appendingPathComponent("Replacement.app")
            try FileManager.default.copyItem(at: newApp, to: replacement)
            try validate(replacement, currentApp)
            return PreparedUpdate(stagingDirectory: directory, replacement: replacement,
                                  backup: directory.appendingPathComponent("Previous.app"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func validateSignature(_ newApp: URL, _ currentApp: URL) throws {
        guard let expectedID = Bundle(url: currentApp)?.bundleIdentifier,
              Bundle(url: newApp)?.bundleIdentifier == expectedID,
              expectedID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw InstallerError.invalidIdentity
        }
        var currentCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(currentApp as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode else { throw InstallerError.invalidSignature }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(currentCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil else {
            throw InstallerError.unsignedCurrentApp
        }
        let rule = "anchor apple generic and identifier \"\(expectedID)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw InstallerError.invalidSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(currentCode, flags, requirement) == errSecSuccess else {
            throw InstallerError.invalidSignature
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode) == errSecSuccess,
              let newCode, SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw InstallerError.invalidSignature
        }
    }

    // Paths are passed as positional arguments, never interpolated into shell code.
    // Keep the previous signed app as a recovery copy after a successful update.
    static let replacementScript = """
    #!/bin/bash
    set -euo pipefail
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    pid="$1"
    current="$2"
    replacement="$3"
    backup="$4"
    downloads="$5"
    ready="$6"
    opener="$7"
    [[ "$pid" =~ ^[0-9]+$ && -d "$current" && -d "$replacement" && ! -e "$backup" ]] || exit 1
    moved_original=0
    rollback() {
      status=$?
      trap - EXIT
      if [[ "$moved_original" == 1 ]]; then
        rm -rf "$current"
        mv "$backup" "$current"
        "$opener" "$current" || true
      fi
      exit "$status"
    }
    trap rollback EXIT
    : > "$ready"
    attempts=0
    while kill -0 "$pid" 2>/dev/null; do
      attempts=$((attempts + 1))
      [[ "$attempts" -lt 300 ]] || exit 1
      sleep 0.1
    done
    mv "$current" "$backup"
    moved_original=1
    mv "$replacement" "$current"
    "$opener" "$current"
    moved_original=0
    rm -rf "$downloads"
    """

    enum InstallerError: LocalizedError {
        case invalidIdentity, invalidSignature, unsignedCurrentApp, helperFailed
        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The update does not match this application."
            case .invalidSignature: return "The update signature could not be verified. Download a signed release instead."
            case .unsignedCurrentApp: return "Automatic updates require a Developer ID signed app. Download the release manually."
            case .helperFailed: return "The update helper could not start. The existing app has been preserved; please retry."
            }
        }
    }
}
