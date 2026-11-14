import Foundation
import Observation
import UIKit

/// Prüft, ob es eine neue Kammer-Version gibt, und führt zu SideStore.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let sourceURL = "https://raw.githubusercontent.com/schp123/Haushalt_App/main/altsource.json"

    var latestVersion: String?
    var latestBuild: Int?
    var notes: String?
    @ObservationIgnored private var lastCheck: Date?

    var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    var updateAvailable: Bool {
        guard let b = latestBuild else { return false }
        return b > installedBuild && dismissedBuild != b
    }

    /// „Später“ gilt nur für genau diese Version.
    private var dismissedBuild: Int {
        get { UserDefaults.standard.integer(forKey: "update.dismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "update.dismissed") }
    }

    func check(force: Bool = false) async {
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < 1800 { return }
        lastCheck = Date()
        guard let url = URL(string: Self.sourceURL + "?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (obj["apps"] as? [[String: Any]])?.first,
              let v = (app["versions"] as? [[String: Any]])?.first else { return }
        latestVersion = v["version"] as? String
        latestBuild = Int(v["buildVersion"] as? String ?? "") ?? (v["buildVersion"] as? Int)
        notes = v["localizedDescription"] as? String
    }

    func dismiss() {
        if let b = latestBuild { dismissedBuild = b }
    }

    /// Öffnet SideStore (dort unter „Meine Apps“ aktualisieren).
    func openSideStore() {
        if let url = URL(string: "sidestore://") { UIApplication.shared.open(url) }
    }

    /// Fügt die Kammer-Quelle in SideStore hinzu.
    func addSourceInSideStore() {
        let encoded = Self.sourceURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Self.sourceURL
        if let url = URL(string: "sidestore://source?url=\(encoded)") {
            UIApplication.shared.open(url) { ok in
                if !ok { UIPasteboard.general.string = Self.sourceURL }
            }
        }
    }
}
