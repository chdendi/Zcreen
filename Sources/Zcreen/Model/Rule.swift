import Foundation

struct AppMatcher: Codable {
    let bundleId: String?
    let nameContains: String?

    var isValid: Bool {
        let values = [bundleId, nameContains].compactMap { $0 }
        return !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func matches(bundleId bid: String?, appName: String?) -> Bool {
        guard isValid else { return false }
        if let bundleId, let bid, bundleId == bid {
            return true
        }
        if let nameContains, let appName,
           appName.localizedCaseInsensitiveContains(nameContains) {
            return true
        }
        return false
    }
}

struct Rule: Codable {
    let app: AppMatcher
    let targetScreen: String
    let profileOverrides: [String: String]?

    func resolvedTargetScreen(for profileName: String?) -> String {
        if let profileName,
           let overrides = profileOverrides,
           let override = overrides[profileName] {
            return override
        }
        return targetScreen
    }
}
