import AppKit
import ApplicationServices
import Carbon
import KeyboardShortcuts
import Sauce

// MARK: - Accessibility permission

enum PHPermissions {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt once when the app is not trusted yet.
  static func promptIfNeeded() {
    guard !isTrusted else { return }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}

// MARK: - Shortcut conflicts

/// Finds global shortcuts that are also system shortcuts (System Settings → Keyboard → Keyboard Shortcuts).
/// Shortcuts taken by other apps cannot be detected: macOS lets several apps register the same one.
enum PHShortcutCheck {
  struct Conflict {
    let label: String
    let shortcut: KeyboardShortcuts.Shortcut
  }

  static let names: [(KeyboardShortcuts.Name, String)] = [
    (.phOpenHUD, String(localized: "Open popup")), (.phCapture, String(localized: "Capture selected text"))
  ]

  /// Result of the last `run()`.
  private(set) static var conflicts: [Conflict] = []

  @discardableResult
  static func run() -> [Conflict] {
    let system = systemShortcuts()
    conflicts = names.compactMap { name, label in
      guard let shortcut = KeyboardShortcuts.getShortcut(for: name), system.contains(shortcut) else { return nil }
      return Conflict(label: label, shortcut: shortcut)
    }
    if !conflicts.isEmpty {
      NSLog("PromptHUD: shortcut conflicts: \(conflicts.map { "\($0.shortcut)" })")
    }
    return conflicts
  }

  /// Enabled shortcuts from System Settings → Keyboard → Keyboard Shortcuts.
  private static func systemShortcuts() -> [KeyboardShortcuts.Shortcut] {
    var unmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&unmanaged) == noErr,
          let items = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return items.compactMap { item in
      guard (item[kHISymbolicHotKeyEnabled] as? Bool) == true,
            let code = item[kHISymbolicHotKeyCode] as? Int,
            let modifiers = item[kHISymbolicHotKeyModifiers] as? Int else { return nil }
      return KeyboardShortcuts.Shortcut(carbonKeyCode: code, carbonModifiers: modifiers)
    }
  }
}

// MARK: - Caret location

/// Where the HUD should appear, in Cocoa screen coordinates (origin at bottom-left of the primary screen).
struct PHAnchor {
  enum Source { case caret, field, mouse }
  var rect: NSRect
  var source: Source
}

enum PHCaretLocator {
  private static var manualAccessibilityPIDs = Set<pid_t>()

  /// Fallback chain: text caret → focused field → mouse pointer.
  static func locate() -> PHAnchor {
    if PHPermissions.isTrusted, let element = focusedElement() {
      if let rect = caretRect(of: element).flatMap(toCocoa), isUsable(rect) {
        return PHAnchor(rect: rect, source: .caret)
      }
      if let frame = frame(of: element).flatMap(toCocoa), isUsable(frame) {
        // Tall fields (editors): anchor to the top-left corner instead of the whole field.
        let rect = frame.height > 120
          ? NSRect(x: frame.minX + 8, y: frame.maxY - 28, width: 1, height: 20)
          : frame
        return PHAnchor(rect: rect, source: .field)
      }
    }
    let mouse = NSEvent.mouseLocation
    return PHAnchor(rect: NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20), source: .mouse)
  }

  static func focusedElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      return nil
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.3)
    enableManualAccessibility(appElement, pid: app.processIdentifier)

    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let value = focused,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return (value as! AXUIElement) // swiftlint:disable:this force_cast
  }

  static func selectedText(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  /// Electron apps (VS Code, Slack, Feishu…) only build their accessibility tree after this flag is set.
  private static func enableManualAccessibility(_ appElement: AXUIElement, pid: pid_t) {
    guard !manualAccessibilityPIDs.contains(pid) else { return }
    manualAccessibilityPIDs.insert(pid)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  private static func caretRect(of element: AXUIElement) -> CGRect? {
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let value = rangeValue,
          CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil } // swiftlint:disable:this force_cast

    if let rect = bounds(of: element, range: range), rect.height > 0 {
      return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
    }
    // Some apps return an empty rect for a zero-length range: use the previous or next character.
    if range.location > 0,
       let rect = bounds(of: element, range: CFRange(location: range.location - 1, length: 1)), rect.height > 0 {
      return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
    }
    if let rect = bounds(of: element, range: CFRange(location: range.location, length: 1)), rect.height > 0 {
      return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
    }
    return nil
  }

  private static func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
    var mutableRange = range
    guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
    ) == .success,
      let value = result,
      CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    var rect = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil } // swiftlint:disable:this force_cast
    return rect
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let position = positionValue, let size = sizeValue,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
      return nil
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    // swiftlint:disable force_cast
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
      return nil
    }
    // swiftlint:enable force_cast
    return CGRect(origin: point, size: dimensions)
  }

  /// Accessibility uses a top-left origin on the primary screen. Cocoa uses bottom-left.
  /// The primary screen is `NSScreen.screens[0]`, not `NSScreen.main` (which follows keyboard focus).
  private static func toCocoa(_ rect: CGRect) -> NSRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  private static func isUsable(_ rect: NSRect) -> Bool {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
          rect.height > 0, rect.height < 4000 else {
      return false
    }
    if rect.origin == .zero { return false }
    let probe = NSPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(probe) }
  }
}

// MARK: - Placement

enum PHPlacement {
  /// Below the anchor when there is room, otherwise above. Always fully inside one screen.
  static func origin(for size: NSSize, anchor: NSRect) -> NSPoint {
    let probe = NSPoint(x: anchor.midX, y: anchor.midY)
    let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { return anchor.origin }

    let gap: CGFloat = 6
    var y = anchor.minY - gap - size.height
    if y < visible.minY {
      y = anchor.maxY + gap
    }
    y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)

    var x = anchor.minX - 14
    x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
    return NSPoint(x: x, y: y)
  }
}

// MARK: - Clipboard and key events

enum PHPasteboard {
  typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

  static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  static func snapshot(_ pasteboard: NSPasteboard = .general) -> Snapshot {
    (pasteboard.pasteboardItems ?? []).map { item in
      var entry: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) { entry[type] = data }
      }
      return entry
    }
  }

  static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    guard !snapshot.isEmpty else { return }
    let items: [NSPasteboardItem] = snapshot.map { entry in
      let item = NSPasteboardItem()
      for (type, data) in entry { item.setData(data, forType: type) }
      // Clipboard managers should not record this restore as a new copy.
      item.setData(Data(), forType: transient)
      return item
    }
    pasteboard.writeObjects(items)
  }

  /// Posts ⌘ + key using the key position of the current keyboard layout.
  static func postCommand(_ key: Key) {
    var keyCode = Sauce.shared.keyCode(for: key)
    if KeyboardLayout.current.commandSwitchesToQWERTY {
      keyCode = key.QWERTYKeyCode
    }
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    let source = CGEventSource(stateID: .combinedSessionState)
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cgSessionEventTap)
    up?.post(tap: .cgSessionEventTap)
  }

  /// Waits (max ~0.6 s) until the user releases ⌃ ⌥ ⇧ ⌘ so they do not mix with posted events.
  static func afterModifiersReleased(_ action: @escaping () -> Void, attempts: Int = 30) {
    let held = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
    if held.isEmpty || attempts <= 0 {
      action()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      afterModifiersReleased(action, attempts: attempts - 1)
    }
  }
}

enum PHInjector {
  enum Outcome {
    case inserted
    case secureInput
    case noPermission
  }

  /// How long the target app gets to read the clipboard before the user's clipboard comes back.
  /// Slow apps (heavy web pages, Electron, remote desktops) can take well over half a second.
  private static let restoreDelay: TimeInterval = 1.2

  /// The user's clipboard waiting to be restored. A second insert before the restore keeps this one,
  /// so the prompt text is never restored as if it were the user's clipboard.
  private static var pendingRestore: (snapshot: PHPasteboard.Snapshot, changeCount: Int, work: DispatchWorkItem)?

  /// Writes text into the focused field of the frontmost app: save clipboard → set text → ⌘V → restore.
  static func insert(_ text: String, completion: @escaping (Outcome) -> Void) {
    if IsSecureEventInputEnabled() {
      completion(.secureInput)
      return
    }

    let pasteboard = NSPasteboard.general

    guard PHPermissions.isTrusted else {
      // Without permission we cannot paste. Leave the text on the clipboard so the user can press ⌘V.
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      completion(.noPermission)
      return
    }

    let saved: PHPasteboard.Snapshot
    pendingRestore?.work.cancel()
    if let pending = pendingRestore, pending.changeCount == pasteboard.changeCount {
      // The clipboard still holds the previous prompt: the user's clipboard is the one saved before it.
      saved = pending.snapshot
    } else {
      saved = PHPasteboard.snapshot(pasteboard)
    }
    pendingRestore = nil
    pasteboard.clearContents()
    pasteboard.declareTypes([.string, PHPasteboard.transient, PHPasteboard.concealed], owner: nil)
    pasteboard.setString(text, forType: .string)
    pasteboard.setString("", forType: PHPasteboard.transient)
    pasteboard.setString("", forType: PHPasteboard.concealed)
    let ownChangeCount = pasteboard.changeCount

    PHPasteboard.afterModifiersReleased {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        PHPasteboard.postCommand(.v)
        completion(.inserted)
        let work = DispatchWorkItem {
          pendingRestore = nil
          // Restore only if nobody changed the clipboard in the meantime.
          if pasteboard.changeCount == ownChangeCount {
            PHPasteboard.restore(saved, to: pasteboard)
          }
        }
        pendingRestore = (saved, ownChangeCount, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
      }
    }
  }
}

enum PHSelectionReader {
  /// Reads the selected text of the frontmost app: Accessibility first, then a simulated ⌘C.
  static func read(completion: @escaping (String?) -> Void) {
    guard PHPermissions.isTrusted else {
      completion(nil)
      return
    }

    if let element = PHCaretLocator.focusedElement(),
       let text = PHCaretLocator.selectedText(of: element),
       !text.phTrimmed.isEmpty {
      completion(text)
      return
    }

    let pasteboard = NSPasteboard.general
    PHPasteboard.afterModifiersReleased {
      let saved = PHPasteboard.snapshot(pasteboard)
      let before = pasteboard.changeCount
      PHPasteboard.postCommand(.c)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard pasteboard.changeCount != before else {
          completion(nil)
          return
        }
        let text = pasteboard.string(forType: .string)
        PHPasteboard.restore(saved, to: pasteboard)
        completion(text?.phTrimmed.isEmpty == false ? text : nil)
      }
    }
  }
}
