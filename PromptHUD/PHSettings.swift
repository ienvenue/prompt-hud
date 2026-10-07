import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

/// App preferences stored in UserDefaults (not in prompts.json, so older versions are unaffected).
enum PHPreferences {
  static let familiarThresholdKey = "phFamiliarThreshold"
  static let defaultFamiliarThreshold = 100

  /// A prompt used at least this many times only shows its title when selected (→ shows the text).
  static var familiarThreshold: Int {
    let value = UserDefaults.standard.integer(forKey: familiarThresholdKey)
    return value >= 1 ? value : defaultFamiliarThreshold
  }
}

final class PHSettingsWindowController {
  private var window: NSWindow?

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: PHSettingsView())
      let window = NSWindow(contentViewController: hosting)
      window.title = String(localized: "Prompt HUD Settings")
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

struct PHSettingsView: View {
  private var store: PHStore { PHStore.shared }
  @AppStorage(PHPreferences.familiarThresholdKey) private var familiarThreshold = PHPreferences.defaultFamiliarThreshold

  var body: some View {
    Form {
      Section("Shortcuts") {
        KeyboardShortcuts.Recorder("Open popup", name: .phOpenHUD) { _ in PHShortcutCheck.run() }
        KeyboardShortcuts.Recorder("Capture selected text", name: .phCapture) { _ in PHShortcutCheck.run() }
      }
      Section("Popup") {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Hide the text after this many uses")
            Spacer()
            TextField("", value: $familiarThreshold, format: .number.grouping(.never))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 64)
            Text("uses")
          }
          // swiftlint:disable:next line_length
          Text("Once a prompt reaches this count, selecting it shows only the title; press → to see the text. Uses from all your Macs are added up, and the count starts over when you change the text.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: familiarThreshold) { _, newValue in
          if newValue < 1 {
            familiarThreshold = 1
          } else {
            store.saveFamiliarThreshold(newValue)
          }
        }
      }
      Section("General") {
        LaunchAtLogin.Toggle {
          Text("Launch at login")
        }
        HStack {
          Text("Accessibility permission")
          Spacer()
          if PHPermissions.isTrusted {
            Label("Granted", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Button("Open System Settings") { PHPermissions.openSystemSettings() }
          }
        }
      }
      Section("Data") {
        VStack(alignment: .leading, spacing: 4) {
          if store.location == .iCloud {
            Label("iCloud Drive › \(PHStore.cloudFolderName)", systemImage: "icloud")
            Text(store.pendingCount > 0
                 ? String(localized: "Downloading \(store.pendingCount) files from iCloud")
                 : String(localized: "Macs signed in to the same Apple ID sync prompts and settings automatically (except shortcuts)."))
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          } else {
            Label("Saved on this Mac only", systemImage: "exclamationmark.icloud")
              .foregroundStyle(.orange)
            Text("iCloud Drive is off, so nothing syncs. When you turn it on, your prompts move to iCloud Drive automatically.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.libraryURL]) }
          Button("Backups Folder") { NSWorkspace.shared.open(store.backupsURL) }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 470)
  }
}
