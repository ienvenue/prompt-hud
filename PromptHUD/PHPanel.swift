import AppKit
import SwiftUI

/// Borderless floating panel that takes keyboard input without activating the app,
/// so the target app keeps its focused text field.
final class PHPanel: NSPanel {
  var onResignKey: (() -> Void)?

  init(size: NSSize) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    isMovableByWindowBackground = false
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }

  func setRootView<Content: View>(_ view: Content, size: NSSize? = nil) {
    let hosting = NSHostingView(rootView: view)
    let finalSize = size ?? hosting.fittingSize
    hosting.sizingOptions = []
    hosting.frame = NSRect(origin: .zero, size: finalSize)
    hosting.autoresizingMask = [.width, .height]
    setContentSize(finalSize)
    contentView = hosting
  }

  /// Resizes the window to the SwiftUI content, keeping the top edge in place.
  func resizeToFitContent() {
    guard let content = contentView else { return }
    let size = content.fittingSize
    guard size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
    var newFrame = frame
    newFrame.origin.y += frame.height - size.height
    newFrame.size = size
    setFrame(newFrame, display: true)
    invalidateShadow()
  }

  /// Shows the panel with a short fade-in. `key` decides whether it takes keyboard input.
  func present(at origin: NSPoint, key: Bool) {
    setFrameOrigin(origin)
    alphaValue = 0
    orderFrontRegardless()
    if key { makeKey() }
    invalidateShadow()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      self.animator().alphaValue = 1
    }
  }

  /// Hides immediately (no animation) so focus returns to the target app before pasting.
  func dismiss() {
    onResignKey = nil
    orderOut(nil)
  }

  func firstTextField() -> NSTextField? {
    func search(_ view: NSView?) -> NSTextField? {
      guard let view else { return nil }
      if let field = view as? NSTextField, field.isEditable { return field }
      for subview in view.subviews {
        if let found = search(subview) { return found }
      }
      return nil
    }
    return search(contentView)
  }

  /// True while an input method (e.g. Chinese pinyin) is composing text in this panel.
  var isComposingText: Bool {
    (firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }
}

/// System blur material that stays "active" even though the app itself is never active.
struct PHMaterial: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .popover

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = material
  }
}

/// Small keyboard key label, e.g. "esc" on the cancel button.
struct PHKeycap: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(PHTheme.chipText)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
  }
}

// MARK: - Colors

/// Colors from the design canvas (light), with matching values for dark mode.
enum PHTheme {
  static let accent = dynamic(0x2F6FE0, 0x4A86F0)
  static let selection = dynamic(0xE8EFFC, 0x2C3A55)
  static let hover = dynamic(0xF3F4F6, 0x2C2D31)
  static let popupBackground = dynamic(0xFFFFFF, 0x232427)
  static let formBackground = dynamic(0xF3F3F5, 0x2A2B2E)
  static let fieldBackground = dynamic(0xFFFFFF, 0x1E1F22)
  static let fieldBorder = dynamic(0xD6D6DB, 0x46474C)
  static let menuBackground = dynamic(0xFFFFFF, 0x2F3034)
  static let divider = dynamic(0xEEF0F2, 0x34353A)
  static let formDivider = dynamic(0xE2E2E6, 0x3A3B3F)
  static let textPrimary = dynamic(0x17181B, 0xECECEE)
  static let text = dynamic(0x2B2D33, 0xDCDDE0)
  static let textSecondary = dynamic(0x6B6F78, 0x9A9EA7)
  static let label = dynamic(0x5D616B, 0xA0A4AC)
  static let bodyText = dynamic(0x4A4E57, 0xB8BBC2)
  static let pin = dynamic(0x8A8E97, 0x8A8E97)
  static let chipBackground = dynamic(0xECECF0, 0x36373C)
  static let chipText = dynamic(0x3A3D44, 0xD0D2D6)
  static let cancelBackground = dynamic(0xE1E1E5, 0x3C3D42)
  static let danger = dynamic(0xC0262D, 0xFF5A5F)
  static let warning = dynamic(0x8A4B08, 0xE0A050)
  static let replaceBorder = dynamic(0xB9CDF3, 0x3D5A8F)
  static let replaceText = dynamic(0x1F4FAE, 0x8FB3FF)
  static let oldTextBackground = dynamic(0xE7E7EA, 0x333438)
  static let toastBackground = dynamic(0x2B2D33, 0x3A3B40)

  private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
    })
  }

  private static func color(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }
}

// MARK: - Toast

final class PHToast {
  static let shared = PHToast()

  private var panel: PHPanel?
  private var hideWork: DispatchWorkItem?

  func show(_ text: String, symbol: String = "checkmark", tint: Color = .white, near anchor: NSRect? = nil) {
    let view = PHToastView(text: text, symbol: symbol, tint: tint)
    let panel = self.panel ?? PHPanel(size: NSSize(width: 200, height: 32))
    panel.ignoresMouseEvents = true
    panel.setRootView(view)
    let anchorRect = anchor ?? PHCaretLocator.locate().rect
    panel.present(at: PHPlacement.origin(for: panel.frame.size, anchor: anchorRect), key: false)
    self.panel = panel

    hideWork?.cancel()
    let work = DispatchWorkItem { [weak panel] in
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.2
        panel?.animator().alphaValue = 0
      }, completionHandler: {
        panel?.orderOut(nil)
      })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
  }
}

private struct PHToastView: View {
  let text: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(tint)
      Text(text)
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(PHTheme.toastBackground)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .fixedSize()
  }
}
