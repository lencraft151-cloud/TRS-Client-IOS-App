// Live-Aktivität für Downloads und Installationen (Sperrbildschirm, Dynamic Island) – angezeigt von der
// Widget-Erweiterung (src-tauri/gen/apple/Widgets/TRSWidgets.swift). `TrsTaskAttributes` muss dort gleich aussehen:
// iOS ordnet App und Erweiterung über den Typnamen zu.

// Schwach gelinkt: Die App läuft ab iOS 15, ActivityKit gibt es erst ab iOS 16.1.
@_weakLinked import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct TrsTaskAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var detail: String
    /// 0…1, negativ = unbestimmt.
    var progress: Double
    var done: Bool
  }

  var kind: String
}

class ActivityArgs: Decodable {
  let id: String
  let kind: String
  let title: String
  let detail: String
  let progress: Double
  let done: Bool
}

@available(iOS 16.2, *)
final class LiveActivities {
  static let shared = LiveActivities()
  private var activities: [String: Activity<TrsTaskAttributes>] = [:]

  /// Startet, aktualisiert oder beendet die Aktivität einer Aufgabe. Ohne Erlaubnis (Einstellungen) passiert nichts.
  func update(_ args: ActivityArgs) {
    let state = TrsTaskAttributes.ContentState(
      title: String(args.title.prefix(80)), detail: String(args.detail.prefix(120)), progress: args.progress, done: args.done)
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
    if let activity = activities[args.id] {
      Task {
        if args.done {
          await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4)))
        } else {
          await activity.update(content)
        }
      }
      if args.done { activities[args.id] = nil }
      return
    }
    guard !args.done, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      activities[args.id] = try Activity.request(attributes: TrsTaskAttributes(kind: args.kind), content: content, pushType: nil)
    } catch {
      NSLog("TrsIos: Live-Aktivität nicht gestartet: \(error)")
    }
  }
}
