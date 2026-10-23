// Widget-Erweiterung des TRS Launchers (iOS 17+):
// - „Zuletzt gespielt“: Name, Version und Loader der zuletzt gespielten Instanz; ein Tipp startet sie
//   (`trs-launcher://play/<id>?k=…`, siehe src-tauri/src/deeplink.rs). Die Liste kommt aus der App-Gruppe
//   (Shared/TrsShared.swift) – ohne App-Gruppe (kostenloses Konto) öffnet das Widget nur den Launcher.
// - Live-Aktivität für Downloads und Installationen (Sperrbildschirm, Dynamic Island). Gestartet und aktualisiert
//   wird sie von der App (Plugin trs-ios, LiveActivity.swift) – `TrsTaskAttributes` muss dort gleich aussehen.

import ActivityKit
import SwiftUI
import WidgetKit

private let background = Color(red: 0.043, green: 0.047, blue: 0.059)
private let accent = Color(red: 0.87, green: 0.2, blue: 0.16)

// MARK: Zuletzt gespielt

struct LastPlayedEntry: TimelineEntry {
  let date: Date
  let instance: TrsSharedData.Instance?
  let url: URL?
}

struct LastPlayedProvider: TimelineProvider {
  func placeholder(in context: Context) -> LastPlayedEntry {
    LastPlayedEntry(
      date: Date(), instance: .init(id: "demo", name: "Survival", version: "1.21.1", loader: "fabric", lastPlayed: nil), url: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (LastPlayedEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LastPlayedEntry>) -> Void) {
    // Die App lädt das Widget neu, wenn sich die Liste ändert; sonst stündlich.
    completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(3600))))
  }

  private func entry() -> LastPlayedEntry {
    let data = TrsSharedData.load()
    let instance = data?.instances.first
    let url = instance.flatMap { TrsSharedData.playURL($0.id, key: data?.key) } ?? URL(string: "trs-launcher://open")
    return LastPlayedEntry(date: Date(), instance: instance, url: url)
  }
}

struct LastPlayedView: View {
  let entry: LastPlayedEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "cube.fill").foregroundStyle(accent)
        Text("TRS Launcher").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let instance = entry.instance {
        Text(instance.name).font(.headline).foregroundStyle(.white).lineLimit(2)
        Text("\(instance.version) · \(instance.loader)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        if family != .systemSmall, let played = instance.lastPlayed {
          Text(played, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Label(TrsText.pick("Spielen", "Play"), systemImage: "play.fill")
          .font(.caption.weight(.bold))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(accent, in: Capsule())
          .foregroundStyle(.white)
      } else {
        Text(TrsText.pick("Öffne den Launcher, um loszulegen.", "Open the launcher to get started."))
          .font(.footnote).foregroundStyle(.white)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .containerBackground(for: .widget) { background }
    .widgetURL(entry.url)
  }
}

struct LastPlayedWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TRSLastPlayed", provider: LastPlayedProvider()) { entry in
      LastPlayedView(entry: entry)
    }
    .configurationDisplayName(TrsText.pick("Zuletzt gespielt", "Last played"))
    .description(TrsText.pick("Startet deine zuletzt gespielte Minecraft-Instanz.", "Starts the Minecraft instance you played last."))
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: Live-Aktivität

/// Gleiche Form wie in tauri-plugin-trs-ios (LiveActivity.swift) – iOS ordnet sie über den Typnamen zu.
struct TrsTaskAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var detail: String
    /// 0…1, negativ = unbestimmt.
    var progress: Double
    var done: Bool
  }

  /// Art der Aufgabe (`download`, `install`, `modpack` …) – für das Symbol.
  var kind: String
}

private func symbol(_ kind: String, done: Bool) -> String {
  if done { return "checkmark.circle.fill" }
  switch kind {
  case "modpack", "modpack-file": return "shippingbox.fill"
  case "install", "java": return "square.and.arrow.down.fill"
  default: return "arrow.down.circle.fill"
  }
}

struct TaskProgressView: View {
  let state: TrsTaskAttributes.ContentState

  var body: some View {
    if state.done {
      ProgressView(value: 1.0).tint(.green)
    } else if state.progress >= 0 {
      ProgressView(value: min(max(state.progress, 0), 1)).tint(accent)
    } else {
      ProgressView().tint(accent)
    }
  }
}

struct TaskLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TrsTaskAttributes.self) { context in
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: symbol(context.attributes.kind, done: context.state.done)).foregroundStyle(accent)
          Text(context.state.title).font(.headline).lineLimit(1)
          Spacer()
          if context.state.progress >= 0 && !context.state.done {
            Text("\(Int(context.state.progress * 100)) %").font(.subheadline.monospacedDigit())
          }
        }
        TaskProgressView(state: context.state)
        if !context.state.detail.isEmpty {
          Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(16)
      .activityBackgroundTint(background)
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: symbol(context.attributes.kind, done: context.state.done)).foregroundStyle(accent)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.progress >= 0 && !context.state.done {
            Text("\(Int(context.state.progress * 100)) %").monospacedDigit()
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.state.title).font(.headline).lineLimit(1)
            TaskProgressView(state: context.state)
          }
        }
      } compactLeading: {
        Image(systemName: symbol(context.attributes.kind, done: context.state.done)).foregroundStyle(accent)
      } compactTrailing: {
        if context.state.done {
          Image(systemName: "checkmark").foregroundStyle(.green)
        } else if context.state.progress >= 0 {
          Text("\(Int(context.state.progress * 100))%").monospacedDigit()
        }
      } minimal: {
        Image(systemName: symbol(context.attributes.kind, done: context.state.done)).foregroundStyle(accent)
      }
      .widgetURL(URL(string: "trs-launcher://open"))
    }
  }
}

@main
struct TRSWidgetsBundle: WidgetBundle {
  var body: some Widget {
    LastPlayedWidget()
    TaskLiveActivity()
  }
}
