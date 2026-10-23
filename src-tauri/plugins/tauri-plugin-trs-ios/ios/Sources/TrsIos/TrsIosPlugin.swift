// Plugin `trs-ios`: Start-Wächter, Anmeldefenster, Teilen und Geräteangaben. Aufgerufen wird es nur aus Rust
// (tauri-plugin-trs-ios/src/lib.rs), nie direkt aus der Web-Ansicht.

import AuthenticationServices
import Foundation
import Tauri
import UIKit
import WebKit

class UrlArgs: Decodable {
  let url: String
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
