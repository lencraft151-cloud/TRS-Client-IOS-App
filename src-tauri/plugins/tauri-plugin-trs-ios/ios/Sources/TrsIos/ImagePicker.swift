// Bilder wählen – aus „Fotos“ (Mediathek, PHPicker) oder aus „Dateien“ (Dokumentauswahl). Der Dialog des Tauri-Plugins
// kennt bei reinen Bildfiltern nur die Mediathek; Skins aus Safari-Downloads liegen aber in „Dateien“. Fotos der Kamera
// sind meist HEIC – das wandelt der Picker in PNG (mit Transparenz) bzw. JPEG um, damit der Launcher sie lesen kann.

import PhotosUI
import Tauri
import UIKit
import UniformTypeIdentifiers

struct PickImagesArgs: Decodable {
  /// `photos` oder `files`.
  let source: String
  let multiple: Bool
  /// Erlaubte Endungen (`png`, `jpg` …); anderes wird umgewandelt (Fotos) bzw. ist nicht wählbar (Dateien).
  let extensions: [String]
}

final class ImagePicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
  static let shared = ImagePicker()

  private var invoke: Invoke?
  private var extensions: [String] = []

  func pick(_ invoke: Invoke, args: PickImagesArgs) {
    DispatchQueue.main.async {
      // Ein offener Picker ist noch nicht beantwortet: als abgebrochen melden, dann den neuen zeigen.
      self.finish(nil)
      guard let top = Self.topViewController() else {
        invoke.reject("no_window", code: "no_window")
        return
      }
      self.invoke = invoke
      self.extensions = args.extensions.map { $0.lowercased() }
      let picker: UIViewController
      if args.source == "photos" {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = args.multiple ? 0 : 1
        config.preferredAssetRepresentationMode = .current
        let photos = PHPickerViewController(configuration: config)
        photos.delegate = self
        picker = photos
      } else {
        var types = self.extensions.compactMap { UTType(filenameExtension: $0) }
        // Fotos, die jemand in „Dateien“ gesichert hat, sind oft HEIC – wählbar, sie werden umgewandelt.
        if types.contains(where: { $0.conforms(to: .image) }) { types.append(contentsOf: [.heic, .heif]) }
        let files = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.image] : types, asCopy: true)
        files.allowsMultipleSelection = args.multiple
        files.delegate = self
        picker = files
      }
      top.present(picker, animated: true)
    }
  }

  // MARK: Fotos

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    if results.isEmpty {
      finish(nil)
      return
    }
    let group = DispatchGroup()
    let lock = NSLock()
    var picked = [(Int, URL)]()
    for (index, result) in results.enumerated() {
      let provider = result.itemProvider
      // Am liebsten eine Darstellung, die der Launcher direkt liest (PNG-Skins aus Safari bleiben so verlustfrei).
      let direct = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first { type in
        type.preferredFilenameExtension.map { self.extensions.contains($0.lowercased()) } ?? false
      }
      let type = direct ?? .image
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        defer { group.leave() }
        guard let url = url, let copy = self.normalized(url) else { return }
        lock.lock()
        picked.append((index, copy))
        lock.unlock()
      }
    }
    group.notify(queue: .main) {
      let urls = picked.sorted { $0.0 < $1.0 }.map { $0.1 }
      if urls.isEmpty {
        self.invoke?.reject("unreadable", code: "unreadable")
        self.invoke = nil
      } else {
        self.finish(urls)
      }
    }
  }

  // MARK: Dateien

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    DispatchQueue.global(qos: .userInitiated).async {
      let copies = urls.compactMap { self.normalized($0) }
      DispatchQueue.main.async {
        if copies.isEmpty {
          self.invoke?.reject("unreadable", code: "unreadable")
          self.invoke = nil
        } else {
          self.finish(copies)
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  // MARK: Hilfen

  /// `nil` = abgebrochen.
  private func finish(_ urls: [URL]?) {
    guard let invoke = invoke else { return }
    self.invoke = nil
    if let urls = urls {
      invoke.resolve(["paths": urls.map { $0.path }])
    } else {
      invoke.resolve(["paths": nil])
    }
  }

  /// Kopie im temporären Ordner der App (die Datei des Pickers verschwindet nach dem Rückruf). Endungen, die der
  /// Launcher nicht liest (HEIC …), werden PNG (mit Transparenz) bzw. JPEG.
  private func normalized(_ url: URL) -> URL? {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = url.pathExtension.lowercased()
    let name = url.deletingPathExtension().lastPathComponent
    if extensions.contains(ext) {
      let dest = dir.appendingPathComponent(url.lastPathComponent)
      return (try? fm.copyItem(at: url, to: dest)).map { dest }
    }
    guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else { return nil }
    let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
    let jpeg = !alpha && (extensions.contains("jpg") || extensions.contains("jpeg"))
    let png = extensions.contains("png")
    guard jpeg || png else { return nil }
    let dest = dir.appendingPathComponent(name).appendingPathExtension(jpeg ? "jpg" : "png")
    // Ausrichtung der Kamera ins Bild übernehmen (sonst lägen Hochformat-Fotos quer).
    let upright = UIGraphicsImageRenderer(size: image.size, format: rendererFormat(image, opaque: jpeg)).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
    guard let data = jpeg ? upright.jpegData(compressionQuality: 0.9) : upright.pngData() else { return nil }
    return (try? data.write(to: dest)).map { dest }
  }

  private func rendererFormat(_ image: UIImage, opaque: Bool) -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    format.opaque = opaque
    return format
  }

  private static func topViewController() -> UIViewController? {
    guard var top = Share.keyWindow()?.rootViewController else { return nil }
    while let presented = top.presentedViewController { top = presented }
    return top
  }
}
