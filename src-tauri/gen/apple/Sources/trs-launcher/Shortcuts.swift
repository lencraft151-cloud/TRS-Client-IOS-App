// Kurzbefehle und Siri (iOS 17+): „Minecraft spielen“ startet die zuletzt gespielte Instanz, „Instanz starten“ eine
// gewählte. Die Liste kommt aus `shared.json` (Shared/TrsShared.swift, geschrieben von src-tauri/src/shortcuts.rs);
// gestartet wird über `trs-launcher://play/<id>?k=…` (src-tauri/src/deeplink.rs). Liegt hier im App-Target, weil
// Xcode App Intents nur aus dem Target selbst einliest (nicht aus der Rust-Bibliothek mit den Plugins).

// Schwach gelinkt: Die App läuft ab iOS 15, App Intents gibt es erst ab iOS 16.
@_weakLinked import AppIntents
import Foundation
import UIKit

@available(iOS 17.0, *)
struct InstanceEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Minecraft"
  static var defaultQuery = InstanceQuery()

  let id: String
  let name: String
  let detail: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
  }

  init(_ instance: TrsSharedData.Instance) {
    id = instance.id
    name = instance.name
    detail = "\(instance.version) · \(instance.loader)"
  }
}

@available(iOS 17.0, *)
struct InstanceQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [InstanceEntity] {
    (TrsSharedData.load()?.instances ?? []).filter { identifiers.contains($0.id) }.map(InstanceEntity.init)
  }

  func suggestedEntities() async throws -> [InstanceEntity] {
    (TrsSharedData.load()?.instances ?? []).map(InstanceEntity.init)
  }
}

@available(iOS 17.0, *)
@MainActor
private func openPlayLink(_ id: String) async {
  guard let url = TrsSharedData.playURL(id, key: TrsSharedData.load()?.key) else { return }
  _ = await UIApplication.shared.open(url)
}

@available(iOS 17.0, *)
struct PlayLastIntent: AppIntent {
  static var title: LocalizedStringResource = "Play Minecraft"
  static var description = IntentDescription("Starts the Minecraft instance you played last in TRS Launcher.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await openPlayLink("last")
    return .result()
  }
}

@available(iOS 17.0, *)
struct PlayInstanceIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Instance"
  static var description = IntentDescription("Starts a Minecraft instance in TRS Launcher.")
  static var openAppWhenRun = true

  @Parameter(title: "Instance")
  var instance: InstanceEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    await openPlayLink(instance.id)
    return .result()
  }
}

@available(iOS 17.0, *)
struct TrsShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlayLastIntent(),
      phrases: [
        "Play Minecraft with \(.applicationName)",
        "Start \(.applicationName)",
        "Spiele Minecraft mit \(.applicationName)",
        "Starte \(.applicationName)",
      ],
      shortTitle: "Play Minecraft",
      systemImageName: "play.fill")
    AppShortcut(
      intent: PlayInstanceIntent(),
      phrases: [
        "Start \(\.$instance) with \(.applicationName)",
        "Starte \(\.$instance) mit \(.applicationName)",
      ],
      shortTitle: "Start Instance",
      systemImageName: "gamecontroller.fill")
  }
}

/// Vom Plugin trs-ios (`sharedChanged`) per Name aufgerufen, wenn sich die Instanzliste geändert hat: Siri kennt dann
/// die neuen Namen für „Starte <Instanz> …“.
@objc(TrsShortcutsBridge)
final class TrsShortcutsBridge: NSObject {
  @objc static func refresh() {
    if #available(iOS 17.0, *) {
      TrsShortcuts.updateAppShortcutParameters()
    }
  }
}
