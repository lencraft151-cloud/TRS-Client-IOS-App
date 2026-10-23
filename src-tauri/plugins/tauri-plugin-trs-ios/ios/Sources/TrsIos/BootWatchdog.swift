// Start-Wächter: Meldet die Oberfläche nicht binnen 25 s „bereit“ (Rust `ios_ui_ready`), legt sich ein natives Fenster
// über die Web-Ansicht – „Neu laden“, „Bericht teilen“, „Weiter warten“ – statt eines schwarzen Bildschirms ohne Ausweg.
// Der Bericht enthält Ladezustand der Web-Ansicht, JavaScript-Fehler, den Startverlauf und das Ende des App-Logs.

import Foundation
import UIKit
import WebKit

final class BootWatchdog {
  static let shared = BootWatchdog()
  static let timeout: TimeInterval = 25
  /// Sammelt JavaScript-Fehler ab Dokumentbeginn (wirkt ab dem nächsten Laden, z. B. nach „Neu laden“).
  static let errorScript = """
    window.__trsBootErrors = [];
    addEventListener('error', function (e) { __trsBootErrors.push(String(e.message) + ' @ ' + e.filename + ':' + e.lineno); });
    addEventListener('unhandledrejection', function (e) { __trsBootErrors.push('Promise: ' + String(e.reason)); });
    """

  private weak var webview: WKWebView?
  private var ready = false
  private var pending: DispatchWorkItem?
  private var overlay: UIView?
  private let started = Date()

  func start(webview: WKWebView) {
    DispatchQueue.main.async {
      self.webview = webview
      webview.configuration.userContentController.addUserScript(
        WKUserScript(source: BootWatchdog.errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      self.arm()
    }
  }

  func markReady() {
    DispatchQueue.main.async {
      self.ready = true
      self.pending?.cancel()
      self.pending = nil
      self.hide()
    }
  }

  private func arm() {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.fire() }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + BootWatchdog.timeout, execute: item)
  }

  private func hide() {
    overlay?.removeFromSuperview()
    overlay = nil
  }

  private func fire() {
    guard !ready, overlay == nil, let webview = webview, let host = webview.superview ?? webview.window else { return }
    let s = TrsIosStrings.current
    let view = UIView(frame: host.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 0.97)

    let title = UILabel()
    title.text = s.bootTitle
    title.font = .boldSystemFont(ofSize: 21)
    title.textColor = UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
    title.numberOfLines = 0
    title.textAlignment = .center

    let message = UILabel()
    message.text = s.bootMessage
    message.font = .systemFont(ofSize: 15)
    message.textColor = UIColor(red: 0.49, green: 0.53, blue: 0.6, alpha: 1)
    message.numberOfLines = 0
    message.textAlignment = .center

    let reload = makeButton(s.bootReload, primary: true) { [weak self] _ in self?.reload() }
    let share = makeButton(s.bootShare, primary: false) { [weak self] sender in self?.shareReport(from: sender) }
    let wait = makeButton(s.bootWait, primary: false) { [weak self] _ in
      self?.hide()
      self?.arm()
    }

    let stack = UIStackView(arrangedSubviews: [title, message, reload, share, wait])
    stack.axis = .vertical
    stack.spacing = 14
    stack.setCustomSpacing(24, after: message)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
    ])
    host.addSubview(view)
    overlay = view
  }

  private func makeButton(_ text: String, primary: Bool, action: @escaping (UIView?) -> Void) -> UIButton {
    var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
    config.title = text
    config.cornerStyle = .medium
    config.buttonSize = .large
    if primary { config.baseBackgroundColor = UIColor(red: 0.87, green: 0.2, blue: 0.16, alpha: 1) }
    let b = UIButton(configuration: config)
    b.addAction(UIAction { act in action(act.sender as? UIView) }, for: .touchUpInside)
    return b
  }

  private func reload() {
    hide()
    guard let webview = webview else { return }
    if webview.url != nil {
      webview.reload()
    } else if let url = URL(string: "tauri://localhost") {
      webview.load(URLRequest(url: url))
    }
    arm()
  }

  private func shareReport(from sender: UIView?) {
    guard let webview = webview else { return }
    let js = "JSON.stringify({ready: document.readyState, href: location.href, body: document.body ? document.body.innerHTML.length : -1, "
      + "tauri: typeof window.__TAURI_INTERNALS__ !== 'undefined', errors: window.__trsBootErrors || null})"
    var done = false
    let finish: (String) -> Void = { [weak self] page in
      if done { return }
      done = true
      guard let self = self, let webview = self.webview else { return }
      var lines = [
        "Die Oberfläche hat sich nach \(Int(Date().timeIntervalSince(self.started))) s nicht als bereit gemeldet.",
        "Web-Ansicht: url=\(webview.url?.absoluteString ?? "-") lädt=\(webview.isLoading) fortschritt=\(webview.estimatedProgress)",
        "Seite: \(page)",
        "",
        "--- Startverlauf (.running) ---",
        BootWatchdog.readMarker(),
        "",
        "--- App-Log (Ende) ---",
      ]
      lines.append(contentsOf: BootWatchdog.logTail(lines: 200))
      let s = TrsIosStrings.current
      guard let url = TrsCrashReporter.write(kind: "boot", title: s.bootReportTitle, time: Date(), body: lines.joined(separator: "\n"))
      else { return }
      Share.present([url], from: sender)
    }
    webview.evaluateJavaScript(js) { result, error in
      finish((result as? String) ?? "JavaScript-Fehler: \(error.map { String(describing: $0) } ?? "keine Antwort")")
    }
    // Hängt das JavaScript, trotzdem teilen.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish("JavaScript antwortet nicht") }
  }

  static func readMarker() -> String {
    guard let dir = TrsCrashReporter.directory,
      let text = try? String(contentsOf: dir.appendingPathComponent(".running"), encoding: .utf8)
    else { return "(keiner)" }
    return text
  }

  /// Letzte Zeilen der neuesten Log-Datei unter `Library/Logs` (Tauri-Log-Plugin).
  static func logTail(lines count: Int) -> [String] {
    let fm = FileManager.default
    guard let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs"),
      let walker = fm.enumerator(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return ["(kein Log)"] }
    var newest: URL?
    var newestDate = Date.distantPast
    for case let url as URL in walker where url.pathExtension == "log" {
      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      if newest == nil || date > newestDate {
        newest = url
        newestDate = date
      }
    }
    guard let file = newest, let handle = try? FileHandle(forReadingFrom: file) else { return ["(kein Log)"] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
    let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    return [file.lastPathComponent] + text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).map(String.init)
  }
}

enum Share {
  /// Teilen-Menü über dem obersten Fenster; auf dem iPad als Popover an `source`.
  static func present(_ urls: [URL], from source: UIView?) {
    DispatchQueue.main.async {
      guard let root = keyWindow()?.rootViewController else { return }
      var top = root
      while let presented = top.presentedViewController { top = presented }
      let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        let anchor = source ?? top.view
        popover.sourceView = anchor
        popover.sourceRect = anchor?.bounds ?? .zero
      }
      top.present(sheet, animated: true)
    }
  }

  static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first
  }
}
