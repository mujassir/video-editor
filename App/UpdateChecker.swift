import Foundation
import Observation
import UIKit

/// Asks Apple's App Store lookup service whether a newer Cut & Weld is out.
///
/// The request sends only the app's App Store ID and a country code. No videos,
/// projects or identifiers leave the device.
@Observable
@MainActor
final class UpdateChecker {
    static let appStoreID = "6838707697"
    static let appStoreURL = URL(string: "itms-apps://apps.apple.com/app/id\(appStoreID)")!

    /// The newer version on the App Store, if there is one this device can install.
    private(set) var availableVersion: String?
    /// True when a newer version is out and the user hasn't skipped it.
    var showsPrompt = false

    let currentVersion: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let checkInterval: TimeInterval = 60 * 60 * 24

    private enum Key {
        static let lastCheck = "updateChecker.lastCheck"
        static let skippedVersion = "updateChecker.skippedVersion"
        static let latestVersion = "updateChecker.latestVersion"
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Keep offering an update found by an earlier check (the check itself runs at most daily).
        if let latest = defaults.string(forKey: Key.latestVersion),
           Self.isVersion(latest, newerThan: currentVersion) {
            availableVersion = latest
        }
    }

    /// Checks at most once a day unless `force` is true. Failures are silent.
    func check(force: Bool = false) async {
        if !force, let last = defaults.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(last) < checkInterval {
            return
        }

        guard let release = await fetchRelease() else { return }
        defaults.set(Date(), forKey: Key.lastCheck)
        defaults.set(release.version, forKey: Key.latestVersion)

        guard Self.isVersion(release.version, newerThan: currentVersion),
              Self.canInstall(minimumOS: release.minimumOsVersion) else {
            availableVersion = nil
            return
        }

        availableVersion = release.version
        if force || defaults.string(forKey: Key.skippedVersion) != release.version {
            showsPrompt = true
        }
    }

    func skipAvailableVersion() {
        if let availableVersion {
            defaults.set(availableVersion, forKey: Key.skippedVersion)
        }
        showsPrompt = false
    }

    func openAppStore() {
        showsPrompt = false
        UIApplication.shared.open(Self.appStoreURL)
    }

    // MARK: - Lookup

    private struct LookupResponse: Decodable, Sendable {
        let results: [Release]
    }

    struct Release: Decodable, Sendable {
        let version: String
        let minimumOsVersion: String?
    }

    private func fetchRelease() async -> Release? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "id", value: Self.appStoreID)]
        if let country = Locale.current.region?.identifier, country.count == 2 {
            items.append(URLQueryItem(name: "country", value: country.lowercased()))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LookupResponse.self, from: data).results.first
        } catch {
            return nil
        }
    }

    // MARK: - Version comparison

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    nonisolated static func canInstall(minimumOS: String?) -> Bool {
        guard let minimumOS else { return true }
        let parts = minimumOS.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }
}
