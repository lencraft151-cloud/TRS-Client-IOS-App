// Plugin `trs-ios`: Start-Wächter, Anmeldefenster, Teilen, Geräteangaben, Sicherungsordner (iCloud). Aufgerufen wird es nur aus Rust
// (tauri-plugin-trs-ios/src/lib.rs), nie direkt aus der Web-Ansicht.

import AuthenticationServices
import Foundation
import Tauri
import UIKit
import WebKit
import WidgetKit

class UrlArgs: Decodable {
  let url: String
}

class PathArgs: Decodable {
  let path: String
}

class ShareArgs: Decodable {
  let paths: [String]
}

/// Fenster für das Anmeldefenster: das Hauptfenster der App.
class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  weak var webview: WKWebView?

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    if let window = webview?.window ?? Share.keyWindow() { return window }
    // Ohne Fenster öffnet iOS das Anmeldefenster nicht (start() liefert false).
    return ASPresentationAnchor(frame: .zero)
  }
}

@objc(TrsIosPlugin)
class TrsIosPlugin: Plugin {
  private weak var webview: WKWebView?
  private var session: ASWebAuthenticationSession?
  private let anchor = AuthAnchor()

  override func load(webview: WKWebView) {
    self.webview = webview
    anchor.webview = webview
    TrsCrashReporter.install()
    BootWatchdog.shared.start(webview: webview)
  }

  @objc public func uiReady(_ invoke: Invoke) {
    BootWatchdog.shared.markReady()
    invoke.resolve()
  }

  /// Microsoft-Anmeldung in einem Fenster über der App. Die Weiterleitung auf `http://localhost` nimmt der
  /// Loopback-Server in Rust an und schließt das Fenster danach mit `authClose`. Antwort erst, wenn es zu ist.
  @objc public func authStart(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(UrlArgs.self), let url = URL(string: args.url), url.scheme == "https" else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    DispatchQueue.main.async {
      self.session?.cancel()
      // Das Schema wird nie aufgerufen – zu geht das Fenster über authClose oder den Nutzer.
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "trs-launcher-auth") { [weak self] _, error in
        DispatchQueue.main.async { self?.session = nil }
        if let error = error as? ASWebAuthenticationSessionError, error.code != .canceledLogin {
          NSLog("TrsIos: Anmeldefenster: \(error)")
          invoke.resolve(["status": "failed"])
        } else {
          invoke.resolve(["status": "cancelled"])
        }
      }
      session.presentationContextProvider = self.anchor
      // Keine Rückfrage „… möchte microsoftonline.com zum Anmelden verwenden“, keine alten Safari-Sitzungen.
      session.prefersEphemeralWebBrowserSession = true
      self.session = session
      if !session.start() {
        self.session = nil
        invoke.resolve(["status": "failed"])
      }
    }
  }

  @objc public func authClose(_ invoke: Invoke) {
    DispatchQueue.main.async {
      self.session?.cancel()
      self.session = nil
      invoke.resolve()
    }
  }

  @objc public func share(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(ShareArgs.self) else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    let urls = args.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    if urls.isEmpty {
      invoke.reject("not_found", code: "not_found")
      return
    }
    Share.present(urls, from: webview)
    invoke.resolve()
  }

  /// „Öffnen in TRS Launcher“: Die Datei liegt an ihrem Ort (LSSupportsOpeningDocumentsInPlace, evtl. iCloud Drive) –
  /// mit Sicherheitsbereich und Datei-Koordination (lädt sie ggf. erst herunter) in `tmp/Opened` kopieren.
  @objc public func importFile(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(UrlArgs.self), let url = URL(string: args.url), url.isFileURL else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let fm = FileManager.default
      let dir = fm.temporaryDirectory.appendingPathComponent("Opened", isDirectory: true)
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(url.lastPathComponent)
      try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      var coordinated: NSError?
      var copied: Error?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinated) { readable in
        do {
          try fm.copyItem(at: readable, to: dest)
        } catch {
          copied = error
        }
      }
      if let error = (coordinated as Error?) ?? copied {
        NSLog("TrsIos: Datei nicht übernommen: \(error)")
        invoke.reject("copy_failed", code: "copy_failed")
        return
      }
      invoke.resolve(["path": dest.path])
    }
  }

  /// Ordner für Sicherungen: „Auf meinem iPhone › TRS Launcher › Backups“ (Dateien-App, im iCloud-Geräte-Backup) und –
  /// mit iCloud-Entitlement und angemeldetem iCloud – „iCloud Drive › TRS Launcher › Backups“.
  @objc public func backupDirs(_ invoke: Invoke) {
    // `url(forUbiquityContainerIdentifier:)` kann dauern und darf nicht auf den Hauptthread.
    DispatchQueue.global(qos: .userInitiated).async {
      let fm = FileManager.default
      var result: JsonObject = [:]
      if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
        result["local"] = documents.appendingPathComponent("Backups", isDirectory: true).path
      }
      if fm.ubiquityIdentityToken != nil, let container = fm.url(forUbiquityContainerIdentifier: nil) {
        result["icloud"] = container.appendingPathComponent("Documents/Backups", isDirectory: true).path
      }
      invoke.resolve(result)
    }
  }

  /// Sicherung aus iCloud aufs Gerät holen (kehrt sofort zurück; fertig ist sie, wenn die Datei lesbar ist).
  @objc public func icloudDownload(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(PathArgs.self) else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: args.path))
        invoke.resolve()
      } catch {
        NSLog("TrsIos: iCloud-Download: \(error)")
        invoke.reject("download_failed", code: "download_failed")
      }
    }
  }

  /// Ordner für `shared.json` (Kurzbefehle, Widget): App-Gruppe, falls die Entitlements sie erlauben, und immer
  /// Application Support der App.
  @objc public func sharedDirs(_ invoke: Invoke) {
    var dirs: [String] = []
    if let group = Bundle.main.object(forInfoDictionaryKey: "TRSAppGroup") as? String, !group.isEmpty, !group.contains("$("),
      let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    {
      dirs.append(url.appendingPathComponent("TRS", isDirectory: true).path)
    }
    if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      dirs.append(support.appendingPathComponent("TRS-Shared", isDirectory: true).path)
    }
    invoke.resolve(["dirs": dirs])
  }

  /// `shared.json` ist neu: Widget neu laden, Siri die neuen Instanznamen geben (TrsShortcutsBridge im App-Target).
  @objc public func sharedChanged(_ invoke: Invoke) {
    WidgetCenter.shared.reloadAllTimelines()
    DispatchQueue.main.async {
      // Klassenmethode `+refresh` über die Objective-C-Laufzeit (die Klasse liegt nicht in diesem Paket).
      if let bridge = NSClassFromString("TrsShortcutsBridge") {
        let selector = NSSelectorFromString("refresh")
        let object = bridge as AnyObject
        if object.responds(to: selector) {
          _ = object.perform(selector)
        }
      }
    }
    invoke.resolve()
  }

  /// Live-Aktivität einer Aufgabe (Download, Installation) – ab iOS 16.2, sonst nichts.
  @objc public func liveActivity(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(ActivityArgs.self) else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    if #available(iOS 16.2, *) {
      DispatchQueue.main.async { LiveActivities.shared.update(args) }
    }
    invoke.resolve()
  }

  /// Update über SideStore (sonst AltStore) installieren: Die App öffnet `<store>://install?url=<IPA>`, der Store lädt,
  /// signiert mit der Apple-ID des Nutzers und installiert nach Rückfrage. Antwort `{ store: "sidestore" | "altstore" }`,
  /// `store: null` = keiner installiert (Schemata stehen in LSApplicationQueriesSchemes).
  @objc public func openStoreInstall(_ invoke: Invoke) {
    guard let args = try? invoke.parseArgs(UrlArgs.self), let ipa = URL(string: args.url), ipa.scheme == "https" else {
      invoke.reject("invalid_args", code: "invalid_args")
      return
    }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = args.url.addingPercentEncoding(withAllowedCharacters: allowed) ?? args.url
    DispatchQueue.main.async {
      for store in ["sidestore", "altstore"] {
        guard let url = URL(string: "\(store)://install?url=\(encoded)"), UIApplication.shared.canOpenURL(url) else { continue }
        UIApplication.shared.open(url)
        invoke.resolve(["store": store])
        return
      }
      invoke.resolve(["store": nil])
    }
  }

  @objc public func deviceInfo(_ invoke: Invoke) {
    let info = ProcessInfo.processInfo
    invoke.resolve([
      "model": TrsCrashReporter.model,
      "systemVersion": TrsCrashReporter.systemVersion,
      "memoryBytes": info.physicalMemory,
      "processorCount": info.activeProcessorCount,
      "lowPower": info.isLowPowerModeEnabled,
    ])
  }
}

/// Texte der nativen Fenster (Deutsch, sonst Englisch – die Oberfläche selbst ist da noch nicht geladen).
struct TrsIosStrings {
  let bootTitle: String
  let bootMessage: String
  let bootReload: String
  let bootShare: String
  let bootWait: String
  let bootReportTitle: String

  static var current: TrsIosStrings {
    let german = Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false
    return german ? de : en
  }

  static let de = TrsIosStrings(
    bootTitle: "Die Oberfläche lädt nicht",
    bootMessage: "TRS Launcher läuft, aber die Oberfläche erscheint nicht. Lade neu – und teile den Bericht, damit wir das beheben können.",
    bootReload: "Neu laden",
    bootShare: "Bericht teilen",
    bootWait: "Weiter warten",
    bootReportTitle: "Oberfläche lädt nicht")

  static let en = TrsIosStrings(
    bootTitle: "The launcher isn't loading",
    bootMessage: "TRS Launcher is running, but its screen doesn't appear. Reload – and share the report so we can fix it.",
    bootReload: "Reload",
    bootShare: "Share report",
    bootWait: "Keep waiting",
    bootReportTitle: "Screen doesn't load")
}

@_cdecl("init_plugin_trs_ios")
func initPlugin() -> Plugin {
  // Hält den Absturzbericht im Binary (main.mm findet ihn nur per Name).
  _ = TrsCrashReporter.self
  return TrsIosPlugin()
}
