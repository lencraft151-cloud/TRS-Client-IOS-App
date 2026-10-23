// Absturzberichte als Textdatei in `Dokumente/Crash Reports` – sichtbar in der Dateien-App, auch wenn die Oberfläche
// nie lädt. Format wie `src/crash_report.rs` der App: Kopfzeilen („Art:“, „Zeit:“, „Titel:“ …), `---`, Text.
//
// `main.mm` ruft `install()` vor dem App-Start auf:
// - Objective-C-Ausnahmen (z. B. UIKit-Prüfungen) schreibt der Handler sofort.
// - Abstürze aller Art (EXC_BREAKPOINT, Speicherfehler, Watchdog „0x8badf00d“) und längere Hänger liefert iOS über
//   MetricKit beim nächsten Start nach – ganz ohne eigene Signal-Handler (die der JVM des Spiels in die Quere kämen).

import Foundation
import MetricKit
import UIKit

@objc(TrsCrashReporter)
public class TrsCrashReporter: NSObject, MXMetricManagerSubscriber {
  static let shared = TrsCrashReporter()
  static let folderName = "Crash Reports"
  /// Hänger ab dieser Dauer melden (kürzere bemerkt man kaum).
  static let minHangSeconds = 2.0
  private static var installed = false
  private static var previousHandler: (@convention(c) (NSException) -> Void)?

  @objc public static func install() {
    if installed { return }
    installed = true
    previousHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      TrsCrashReporter.writeException(exception)
      TrsCrashReporter.previousHandler?(exception)
    }
    MXMetricManager.shared.add(shared)
  }

  // MARK: MetricKit

  public func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      for crash in payload.crashDiagnostics ?? [] {
        TrsCrashReporter.writeCrash(crash, at: payload.timeStampEnd)
      }
      for hang in payload.hangDiagnostics ?? [] {
        let seconds = hang.hangDuration.converted(to: .seconds).value
        if seconds >= TrsCrashReporter.minHangSeconds {
          TrsCrashReporter.writeHang(hang, seconds: seconds, at: payload.timeStampEnd)
        }
      }
    }
  }

  static func writeCrash(_ crash: MXCrashDiagnostic, at time: Date) {
    let exception = exceptionName(crash.exceptionType?.intValue)
    let signal = signalName(crash.signal?.intValue)
    var title = [exception, signal].compactMap { $0 }.joined(separator: " / ")
    var lines: [String] = []
    if let type = crash.exceptionType { lines.append("Exception: \(exception ?? "?") (\(type))") }
    if let code = crash.exceptionCode { lines.append("Exception-Code: \(code)") }
    if let sig = crash.signal { lines.append("Signal: \(signal ?? "?") (\(sig))") }
    if let reason = crash.terminationReason {
      lines.append("Beendet von: \(reason)")
      // Watchdog (App hing beim Start/Wechsel zu lange) – der häufigste Grund für „lädt nicht, dann weg“.
      if reason.lowercased().contains("8badf00d") { title = "Watchdog (0x8badf00d)" }
    }
    if #available(iOS 17.0, *), let objc = crash.exceptionReason {
      lines.append("Objective-C: \(objc.exceptionName): \(objc.composedMessage)")
      if title.isEmpty || title.hasPrefix("EXC_CRASH") { title = objc.exceptionName }
    }
    if let region = crash.virtualMemoryRegionInfo { lines.append("Speicher: \(region)") }
    lines.append("App-Version: \(crash.applicationVersion) (\(crash.metaData.applicationBuildVersion))")
    lines.append("Gerät: \(crash.metaData.deviceType) · \(crash.metaData.osVersion)")
    lines.append("")
    lines.append("Aufrufstapel (abstürzender Thread):")
    lines.append(contentsOf: frames(crash.callStackTree))
    lines.append("")
    lines.append("--- MetricKit (JSON) ---")
    lines.append(String(decoding: crash.jsonRepresentation().prefix(48 * 1024), as: UTF8.self))
    write(kind: "ios", title: title.isEmpty ? "iOS-Absturz" : title, time: time, body: lines.joined(separator: "\n"))
  }

  static func writeHang(_ hang: MXHangDiagnostic, seconds: Double, at time: Date) {
    var lines = ["Die App reagierte \(String(format: "%.1f", seconds)) s lang nicht (Haupt-Thread blockiert)."]
    lines.append("App-Version: \(hang.applicationVersion) (\(hang.metaData.applicationBuildVersion))")
    lines.append("Gerät: \(hang.metaData.deviceType) · \(hang.metaData.osVersion)")
    lines.append("")
    lines.append("Aufrufstapel (Haupt-Thread):")
    lines.append(contentsOf: frames(hang.callStackTree))
    write(kind: "hang", title: "Hänger \(String(format: "%.1f", seconds)) s", time: time, body: lines.joined(separator: "\n"))
  }

  static func writeException(_ exception: NSException) {
    var lines = ["\(exception.name.rawValue): \(exception.reason ?? "")"]
    if let info = exception.userInfo, !info.isEmpty { lines.append("Info: \(info)") }
    lines.append("")
    lines.append("Aufrufstapel:")
    lines.append(contentsOf: exception.callStackSymbols)
    write(kind: "ios", title: exception.name.rawValue, time: Date(), body: lines.joined(separator: "\n"))
  }

  /// Oberste Rahmen des abstürzenden (bzw. ersten) Threads: „Nr  Binärdatei  Adresse + Versatz“.
  static func frames(_ tree: MXCallStackTree, limit: Int = 48) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
      let stacks = json["callStacks"] as? [[String: Any]]
    else { return [] }
    let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
    var lines: [String] = []
    var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
    while let f = frame, lines.count < limit {
      let name = f["binaryName"] as? String ?? "?"
      let address = (f["address"] as? NSNumber)?.uint64Value ?? 0
      let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
      lines.append("\(lines.count)  \(name)  0x\(String(address, radix: 16)) + \(offset)")
      frame = (f["subFrames"] as? [[String: Any]])?.first
    }
    return lines
  }

  static func exceptionName(_ type: Int?) -> String? {
    guard let type = type else { return nil }
    switch type {
    case 1: return "EXC_BAD_ACCESS"
    case 2: return "EXC_BAD_INSTRUCTION"
    case 3: return "EXC_ARITHMETIC"
    case 5: return "EXC_SOFTWARE"
    case 6: return "EXC_BREAKPOINT"
    case 10: return "EXC_CRASH"
    case 11: return "EXC_RESOURCE"
    case 12: return "EXC_GUARD"
    default: return "EXC_\(type)"
    }
  }

  static func signalName(_ signal: Int?) -> String? {
    guard let signal = signal else { return nil }
    switch signal {
    case 4: return "SIGILL"
    case 5: return "SIGTRAP"
    case 6: return "SIGABRT"
    case 8: return "SIGFPE"
    case 9: return "SIGKILL"
    case 10: return "SIGBUS"
    case 11: return "SIGSEGV"
    default: return "SIG\(signal)"
    }
  }

  // MARK: Dateien

  static var directory: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent(folderName, isDirectory: true)
  }

  /// Modellkennung (z. B. `iPhone14,4`) – auch aus einem beliebigen Thread.
  static var model: String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  static var systemVersion: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
  }

  static var appVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }

  static func isoTime(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
  }

  /// Schreibt einen Bericht; gibt die Datei zurück.
  @discardableResult
  static func write(kind: String, title: String, time: Date, body: String) -> URL? {
    guard let dir = directory else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.timeZone = TimeZone(identifier: "UTC")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    var url = dir.appendingPathComponent("\(kind)-\(stamp.string(from: time)).txt")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = dir.appendingPathComponent("\(kind)-\(stamp.string(from: time))-\(n).txt")
      n += 1
    }
    let header = [
      "TRS Launcher – Absturzbericht",
      "Art: \(kind)",
      "Zeit: \(isoTime(time))",
      "Titel: \(title.replacingOccurrences(of: "\n", with: " "))",
      "Version: \(appVersion)",
      "Gerät: \(model) · iOS \(systemVersion)",
      "---",
    ]
    let text = header.joined(separator: "\n") + "\n" + body + "\n"
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
      return url
    } catch {
      NSLog("TrsIos: Absturzbericht nicht geschrieben: \(error)")
      return nil
    }
  }
}
