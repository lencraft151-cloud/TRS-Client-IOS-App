// Gemeinsam für App (Kurzbefehle, Sources/trs-launcher/Shortcuts.swift) und Widget (Widgets/TRSWidgets.swift):
// die Instanzliste, die der Launcher als `shared.json` ablegt (src-tauri/src/shortcuts.rs), und der Link, der eine
// Instanz startet. Mit App-Gruppe (bezahltes Konto, volle Entitlements) sieht auch das Widget die Liste; sonst nur
// die App selbst.

import Foundation

struct TrsSharedData: Codable {
  struct Instance: Codable, Hashable {
    let id: String
    let name: String
    let version: String
    let loader: String
    let lastPlayed: Date?
  }

  /// Schlüssel für `trs-launcher://play/…?k=` – damit startet der Launcher ohne Rückfrage.
  let key: String
  /// Zuletzt gespielte zuerst.
  let instances: [Instance]

  static let fileName = "shared.json"

  /// App-Gruppe aus der Info.plist (`TRSAppGroup`, aus Signing.xcconfig).
  static var groupIdentifier: String? {
    (Bundle.main.object(forInfoDictionaryKey: "TRSAppGroup") as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
  }

  /// Wo die Datei liegen kann: App-Gruppe zuerst, dann Application Support der App.
  static func directories() -> [URL] {
    var dirs: [URL] = []
    if let group = groupIdentifier, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
      dirs.append(url.appendingPathComponent("TRS", isDirectory: true))
    }
    if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      dirs.append(support.appendingPathComponent("TRS-Shared", isDirectory: true))
    }
    return dirs
  }

  static func load() -> TrsSharedData? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for dir in directories() {
      if let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
        let value = try? decoder.decode(TrsSharedData.self, from: data)
      {
        return value
      }
    }
    return nil
  }

  /// `trs-launcher://play/<id>?k=<schlüssel>` (`id` = `last`: die zuletzt gespielte).
  static func playURL(_ id: String, key: String?) -> URL? {
    var components = URLComponents()
    components.scheme = "trs-launcher"
    components.host = "play"
    components.path = "/" + id
    if let key = key, !key.isEmpty { components.queryItems = [URLQueryItem(name: "k", value: key)] }
    return components.url
  }
}

/// Deutsch oder Englisch nach der Gerätesprache (Kurzbefehle und Widget haben keine eigenen Sprachdateien).
enum TrsText {
  static var german: Bool { Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false }
  static func pick(_ de: String, _ en: String) -> String { german ? de : en }
}
