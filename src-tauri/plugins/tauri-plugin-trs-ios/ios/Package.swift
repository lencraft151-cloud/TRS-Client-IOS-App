// swift-tools-version:5.5
// TRS Launcher – iOS: Absturzberichte (MetricKit), Start-Wächter, Anmeldefenster (ASWebAuthenticationSession), Teilen,
// Live-Aktivität und Widget-Aktualisierung.

import PackageDescription

let package = Package(
  name: "tauri-plugin-trs-ios",
  platforms: [
    .iOS(.v15),
  ],
  products: [
    .library(
      name: "tauri-plugin-trs-ios",
      type: .static,
      targets: ["tauri-plugin-trs-ios"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-trs-ios",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources")
  ]
)
