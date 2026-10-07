import AppKit
import KeyboardShortcuts
import SwiftUI

/// Prompt HUD entry point.
/// Based on Maccy (© Alexey Rodionov, MIT License).
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private let hud = PHHUDController()
  private let capture = PHCaptureController()
  private let settings = PHSettingsWindowController()
  private var permissionTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = PHStore.shared
    let conflicts = PHShortcutCheck.run()
    setUpStatusItem()
    hud.onEdit = { [weak self] prompt, anchor in
      self?.capture.edit(prompt, near: anchor)
    }

    KeyboardShortcuts.onKeyUp(for: .phOpenHUD) { [weak self] in
      self?.hud.toggle()
    }
    KeyboardShortcuts.onKeyUp(for: .phCapture) { [weak self] in
      self?.capture.start()
    }

    PHPermissions.promptIfNeeded()
    startPermissionPolling()
    if !conflicts.isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showShortcutConflicts(conflicts) }
    }
  }

  private func showShortcutConflicts(_ conflicts: [PHShortcutCheck.Conflict]) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    let list = conflicts.map { "\($0.shortcut)（\($0.label)）" }.joined(separator: "、")
    alert.messageText = String(localized: "Shortcut \(list) is taken")
    alert.informativeText = String(localized: "It is also a system shortcut (System Settings → Keyboard → Keyboard Shortcuts), so Prompt HUD may not respond to it. Choose another one in Settings.")
    alert.addButton(withTitle: String(localized: "Open Settings"))
    alert.addButton(withTitle: String(localized: "Not Now"))
    if alert.runModal() == .alertFirstButtonReturn {
      settings.show()
    }
  }

  /// `prompthud://add?…` from the "存入 HUD" button on Prompt Lib.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let item = urls.lazy.compactMap(PHImportLink.init(url:)).first else { return }
    // Let the browser finish handing over before the form takes focus.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture.open(item) }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    settings.show()
    return true
  }

  // MARK: Status item

  private func setUpStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Prompt HUD")
    statusItem.button?.image?.isTemplate = true
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    updateStatusIcon()
  }

  private func updateStatusIcon() {
    let store = PHStore.shared
    let needsAttention = !PHPermissions.isTrusted || store.loadError != nil || store.location == .local
      || !PHShortcutCheck.conflicts.isEmpty
    let name = needsAttention ? "exclamationmark.bubble" : "text.bubble"
    statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Prompt HUD")
    statusItem.button?.image?.isTemplate = true
  }

  private func startPermissionPolling() {
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      self?.updateStatusIcon()
    }
    RunLoop.main.add(timer, forMode: .common)
    permissionTimer = timer
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let open = item(String(localized: "Open Prompt HUD"), #selector(openHUD))
    open.setShortcut(for: .phOpenHUD)
    menu.addItem(open)

    let captureItem = item(String(localized: "Capture Selected Text"), #selector(startCapture))
    captureItem.setShortcut(for: .phCapture)
    menu.addItem(captureItem)

    let store = PHStore.shared
    let conflicts = PHShortcutCheck.conflicts
    if !PHPermissions.isTrusted || store.loadError != nil || store.location == .local || !conflicts.isEmpty {
      menu.addItem(.separator())
    }
    for conflict in conflicts {
      let keys = "\(conflict.shortcut)"
      menu.addItem(item(String(localized: "⚠️ Shortcut \(keys) is taken (click to change)"), #selector(openSettings)))
    }
    if !PHPermissions.isTrusted {
      let warning = item(String(localized: "⚠️ Accessibility Permission Needed…"), #selector(openPermissionSettings))
      menu.addItem(warning)
    }
    if let error = store.loadError {
      let warning = item(String(localized: "⚠️ Couldn’t Read Prompts (click for details)"), #selector(showLoadError))
      warning.toolTip = error
      menu.addItem(warning)
    }
    if store.location == .local {
      let warning = item(String(localized: "⚠️ iCloud Drive Is Off — Saved on This Mac Only"), #selector(openSettings))
      menu.addItem(warning)
    }

    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Usage in the Last 7 Days…"), #selector(showUsage)))
    menu.addItem(item(String(localized: "Show Prompts Folder in Finder"), #selector(revealLibrary)))
    menu.addItem(item(String(localized: "Reload"), #selector(reloadPrompts)))
    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Settings…"), #selector(openSettings), key: ","))
    menu.addItem(item(String(localized: "About Prompt HUD"), #selector(showAbout)))
    menu.addItem(item(String(localized: "Quit"), #selector(quit), key: "q"))
  }

  private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
    menuItem.target = self
    return menuItem
  }

  // MARK: Actions

  @objc private func openHUD() {
    // Let the menu close first so focus is back on the previous app.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.hud.show() }
  }

  @objc private func startCapture() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.capture.start() }
  }

  @objc private func openPermissionSettings() {
    PHPermissions.promptIfNeeded()
    PHPermissions.openSystemSettings()
  }

  @objc private func showLoadError() {
    guard let error = PHStore.shared.loadError else { return }
    PHToast.shared.show(error, symbol: "exclamationmark.triangle.fill", tint: .orange)
  }

  @objc private func revealLibrary() {
    NSWorkspace.shared.activateFileViewerSelecting([PHStore.shared.libraryURL])
  }

  @objc private func reloadPrompts() {
    PHStore.shared.reload()
    updateStatusIcon()
    if let error = PHStore.shared.loadError {
      PHToast.shared.show(error, symbol: "exclamationmark.triangle.fill", tint: .orange)
    } else {
      PHToast.shared.show(String(localized: "Loaded \(PHStore.shared.prompts.count) prompts"))
    }
  }

  @objc private func showUsage() {
    PHUsage.showSummary()
  }

  @objc private func openSettings() {
    settings.show()
  }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let credits = NSAttributedString(
      string: String(localized: "Your prompts, right next to the text cursor.\n\nBased on Maccy\nMaccy © Alexey Rodionov, MIT License"),
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    )
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Prompt HUD",
      .credits: credits
    ])
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
