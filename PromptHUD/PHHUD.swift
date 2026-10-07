import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
final class PHHUDModel {
  var query = ""
  var category: String?
  var selectedIndex = 0 {
    didSet { if selectedIndex != oldValue { peekID = nil } }
  }
  private(set) var results: [PHPrompt] = []
  private(set) var categories: [String] = []
  private(set) var loadError: String?
  /// Usage count from which a prompt is "familiar": selecting it shows only the title.
  private(set) var familiarThreshold = PHPreferences.defaultFamiliarThreshold
  /// A familiar prompt whose text is shown temporarily (→). Cleared when the selection changes.
  private(set) var peekID: String?

  var selected: PHPrompt? {
    results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
  }

  /// While searching, the category row is hidden and all prompts are searched.
  var isSearching: Bool { !query.phTrimmed.isEmpty }

  func isFamiliar(_ prompt: PHPrompt) -> Bool {
    prompt.usageCount >= familiarThreshold
  }

  /// The selected row shows its text when the prompt is not familiar yet, or while peeking.
  func isExpanded(_ index: Int) -> Bool {
    guard index == selectedIndex, results.indices.contains(index) else { return false }
    let prompt = results[index]
    return !isFamiliar(prompt) || peekID == prompt.id
  }

  func reset() {
    query = ""
    category = nil
    selectedIndex = 0
    peekID = nil
    familiarThreshold = PHPreferences.familiarThreshold
    refresh()
  }

  func refresh() {
    let store = PHStore.shared
    categories = store.categories
    loadError = store.loadError
    if let category, !categories.contains(category) {
      self.category = nil
    }
    var items = store.prompts
    if let category, !isSearching {
      items = items.filter { $0.categoryName == category }
    }
    results = PHSearch.search(query, in: items)
    if selectedIndex >= results.count {
      selectedIndex = max(0, results.count - 1)
    }
  }

  func setQuery(_ value: String) {
    guard value != query else { return }
    query = value
    // Searching ignores the category; clearing the search goes back to "全部".
    category = nil
    selectedIndex = 0
    peekID = nil
    refresh()
  }

  func setCategory(_ value: String?) {
    category = value
    selectedIndex = 0
    peekID = nil
    refresh()
  }

  func cycleCategory(_ step: Int) {
    guard !isSearching else { return }
    let all: [String?] = [nil] + categories.map { Optional($0) }
    let current = all.firstIndex(of: category) ?? 0
    setCategory(all[(current + step + all.count) % all.count])
  }

  func move(_ step: Int) {
    guard !results.isEmpty else { return }
    selectedIndex = (selectedIndex + step + results.count) % results.count
  }

  /// →: show the text of the selected familiar prompt. Returns false when there is nothing to show.
  func peek() -> Bool {
    guard let prompt = selected, isFamiliar(prompt), peekID != prompt.id else { return false }
    peekID = prompt.id
    return true
  }

  /// ←: hide the text again. Returns false when nothing was peeking.
  func unpeek() -> Bool {
    guard peekID != nil else { return false }
    peekID = nil
    return true
  }
}

// MARK: - Controller

final class PHHUDController {
  static let size = NSSize(width: 460, height: 472)

  private let model = PHHUDModel()
  private lazy var panel: PHPanel = {
    let panel = PHPanel(size: Self.size)
    panel.setRootView(
      PHHUDView(
        model: model,
        onCommand: { [weak self] selector in self?.handle(selector) ?? false },
        onCommit: { [weak self] index in self?.commit(index: index, via: "click") }
      ),
      size: Self.size
    )
    return panel
  }()

  private var keyMonitor: Any?
  private var mouseMonitor: Any?
  private var anchor: PHAnchor?
  private var openedAt = Date()
  private var targetBundleID: String?

  /// Opens the editor for a prompt near the given anchor. Set by the app delegate.
  var onEdit: ((PHPrompt, NSRect) -> Void)?

  var isVisible: Bool { panel.isVisible }

  func toggle() {
    isVisible ? close() : show()
  }

  func show() {
    PHStore.shared.reloadIfChanged()
    let target = NSWorkspace.shared.frontmostApplication
    targetBundleID = target?.bundleIdentifier
    model.reset()

    let anchor = PHCaretLocator.locate()
    self.anchor = anchor
    openedAt = Date()
    PHUsage.log(.hudOpen, ["anchor": Self.name(of: anchor.source), "app": targetBundleID ?? ""])
    panel.present(at: PHPlacement.origin(for: Self.size, anchor: anchor.rect), key: true)
    focusSearchField()
    // The SwiftUI hierarchy may create the field on the next run loop pass.
    DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    panel.onResignKey = { [weak self] in self?.close() }
    installMonitors()
  }

  /// `committed` is true when the HUD closes because a prompt was inserted or opened for editing.
  func close(committed: Bool = false) {
    guard panel.isVisible else { return }
    if !committed, model.results.isEmpty, !model.query.phTrimmed.isEmpty {
      PHUsage.log(.noResultClose, ["queryLength": model.query.count])
    }
    removeMonitors()
    panel.dismiss()
  }

  private static func name(of source: PHAnchor.Source) -> String {
    switch source {
    case .caret: return "caret"
    case .field: return "field"
    case .mouse: return "mouse"
    }
  }

  private func focusSearchField() {
    guard panel.isVisible, let field = panel.firstTextField() else { return }
    if panel.firstResponder !== field.currentEditor() {
      panel.makeFirstResponder(field)
    }
  }

  // MARK: Keys

  /// Commands from the search field. Not called while an input method is composing text.
  private func handle(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      model.move(-1)
    case #selector(NSResponder.moveDown(_:)):
      model.move(1)
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
      commit(index: model.selectedIndex, via: "enter")
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      // ⌥↵ does nothing (it would otherwise put a line break in the search field).
      break
    case #selector(NSResponder.moveRight(_:)):
      // → shows the text only when the text cursor has nowhere to go in the search field.
      guard caretAtEndOfSearchField(), model.peek() else { return false }
    case #selector(NSResponder.moveLeft(_:)):
      // ← hides peeked text; otherwise it moves the text cursor as usual.
      return model.unpeek()
    case #selector(NSResponder.cancelOperation(_:)):
      if model.query.isEmpty {
        close()
      } else {
        model.setQuery("")
        panel.firstTextField()?.stringValue = ""
      }
    case #selector(NSResponder.insertTab(_:)):
      model.cycleCategory(1)
    case #selector(NSResponder.insertBacktab(_:)):
      model.cycleCategory(-1)
    default:
      return false
    }
    return true
  }

  private func caretAtEndOfSearchField() -> Bool {
    guard let editor = panel.firstTextField()?.currentEditor() as? NSTextView else { return true }
    let range = editor.selectedRange()
    return range.length == 0 && range.location >= (editor.string as NSString).length
  }

  private func installMonitors() {
    removeMonitors()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.panel.isKeyWindow, !self.panel.isComposingText else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // ⌘E is the only management shortcut in the HUD.
      if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
        self.edit(index: self.model.selectedIndex)
        return nil
      }
      // Esc when the search field does not have focus (e.g. after clicking a category).
      if event.keyCode == 53, !(self.panel.firstResponder is NSTextView) {
        self.close()
        return nil
      }
      return event
    }
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.close()
    }
  }

  private func removeMonitors() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    keyMonitor = nil
    mouseMonitor = nil
  }

  // MARK: Insert

  private func commit(index: Int, via: String) {
    guard model.results.indices.contains(index) else {
      NSSound.beep()
      return
    }
    let prompt = model.results[index]
    let anchorRect = anchor?.rect
    let elapsed = Int(Date().timeIntervalSince(openedAt) * 1000)
    let fields: [String: Any] = [
      "ms": elapsed, "via": via, "app": targetBundleID ?? "",
      "anchor": anchor.map { Self.name(of: $0.source) } ?? "mouse",
      "queryLength": model.query.count, "rank": index + 1
    ]
    close(committed: true)
    PHStore.shared.recordUsage(id: prompt.id)
    PHUsage.log(.insert, fields)

    PHInjector.insert(prompt.prompt) { outcome in
      switch outcome {
      case .inserted:
        break
      case .secureInput:
        PHToast.shared.show(String(localized: "This field is in secure input mode, so nothing can be inserted"),
                            symbol: "lock.fill", tint: .orange, near: anchorRect)
      case .noPermission:
        PHToast.shared.show(String(localized: "Copied — press ⌘V to paste"), near: anchorRect)
      }
    }
  }

  /// ⌘E: edit the selected prompt.
  private func edit(index: Int) {
    guard model.results.indices.contains(index) else {
      NSSound.beep()
      return
    }
    let prompt = model.results[index]
    let anchorRect = anchor?.rect ?? PHCaretLocator.locate().rect
    close(committed: true)
    onEdit?(prompt, anchorRect)
  }
}

// MARK: - Views

struct PHHUDView: View {
  @Bindable var model: PHHUDModel
  let onCommand: (Selector) -> Bool
  let onCommit: (Int) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      if !model.isSearching {
        categoryBar
      }
      PHTheme.divider.frame(height: 1)
      list
      PHTheme.divider.frame(height: 1)
      footer
    }
    .frame(width: PHHUDController.size.width, height: PHHUDController.size.height)
    .background(PHTheme.popupBackground)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(PHTheme.textSecondary)
      PHSearchField(model: model, onCommand: onCommand)
        .frame(height: 24)
    }
    .padding(.horizontal, 18)
    .frame(height: 54)
  }

  private var categoryBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(String(localized: "All"), value: nil)
        ForEach(model.categories, id: \.self) { name in
          chip(name, value: name)
        }
      }
      .padding(.horizontal, 14)
    }
    .padding(.bottom, 12)
  }

  private func chip(_ label: String, value: String?) -> some View {
    let isSelected = model.category == value
    return Button {
      model.setCategory(value)
    } label: {
      Text(label)
        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected ? Color.white : PHTheme.chipText)
        .background(Capsule().fill(isSelected ? PHTheme.accent : PHTheme.chipBackground))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var list: some View {
    if model.results.isEmpty {
      VStack(spacing: 6) {
        if let error = model.loadError {
          Text("Couldn’t read prompts")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(PHTheme.textSecondary)
          Text(error)
            .font(.system(size: 12))
            .foregroundStyle(PHTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 30)
        } else {
          Text("No matches")
            .font(.system(size: 14))
            .foregroundStyle(PHTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 96)
      .padding(8)
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
          LazyVStack(spacing: 2) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, prompt in
              PHPromptRow(
                prompt: prompt,
                query: model.query,
                isSelected: index == model.selectedIndex,
                isExpanded: model.isExpanded(index),
                isFamiliar: model.isFamiliar(prompt),
                showsCategory: model.isSearching
              )
              .id(prompt.id)
              .onTapGesture {
                model.selectedIndex = index
                onCommit(index)
              }
            }
          }
          .padding(8)
        }
        .onChange(of: model.selectedIndex) { _, newValue in
          guard model.results.indices.contains(newValue) else { return }
          proxy.scrollTo(model.results[newValue].id)
        }
        .onChange(of: model.peekID) { _, newValue in
          guard let newValue else { return }
          proxy.scrollTo(newValue)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      hint("↵", String(localized: "Insert"))
      hint("→", String(localized: "Text"))
      Spacer()
      if model.loadError != nil {
        Label("File error", systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.orange)
      }
      hint("esc", String(localized: "Close"))
    }
    .padding(.horizontal, 18)
    .frame(height: 34)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 4) {
      Text(key)
        .fontWeight(.semibold)
        .foregroundStyle(PHTheme.textPrimary)
      Text(label)
        .foregroundStyle(PHTheme.textSecondary)
    }
    .font(.system(size: 11.5))
  }
}

/// One line per prompt: the title only. The selected row opens in place to show the text,
/// unless the prompt is familiar (then it shows "→ 正文").
private struct PHPromptRow: View {
  let prompt: PHPrompt
  let query: String
  let isSelected: Bool
  let isExpanded: Bool
  let isFamiliar: Bool
  let showsCategory: Bool
  /// The mouse only highlights a row (click inserts it); selection stays with the keyboard.
  @State private var isHovered = false

  var body: some View {
    content.onHover { isHovered = $0 }
  }

  @ViewBuilder
  private var content: some View {
    if isExpanded {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          title(size: 14.5, weight: .semibold)
          pin
          Spacer(minLength: 8)
          category
        }
        Text(prompt.prompt)
          .font(.system(size: 12.5))
          .foregroundStyle(PHTheme.bodyText)
          .lineSpacing(6)
          .lineLimit(6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PHTheme.selection))
      .contentShape(Rectangle())
    } else {
      HStack(spacing: 8) {
        title(size: 14, weight: isSelected ? .semibold : .regular)
        pin
        Spacer(minLength: 8)
        if showsCategory {
          category
        }
        if isSelected, isFamiliar {
          Text("→ Text")
            .font(.system(size: 11.5))
            .foregroundStyle(PHTheme.label)
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 40)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isSelected ? PHTheme.selection : isHovered ? PHTheme.hover : Color.clear)
      )
      .contentShape(Rectangle())
    }
  }

  private func title(size: CGFloat, weight: Font.Weight) -> some View {
    Text(PHSearch.highlighted(prompt.title, query: query))
      .font(.system(size: size, weight: weight))
      .foregroundStyle(isSelected ? PHTheme.textPrimary : PHTheme.text)
      .lineLimit(1)
  }

  @ViewBuilder
  private var pin: some View {
    if prompt.pinned {
      Image(systemName: "pin")
        .font(.system(size: 11))
        .foregroundStyle(PHTheme.pin)
        .accessibilityLabel("Pinned")
    }
  }

  private var category: some View {
    Text(prompt.categoryName)
      .font(.system(size: 11.5))
      .foregroundStyle(PHTheme.textSecondary)
      .lineLimit(1)
  }
}

/// AppKit text field so we can intercept ↑ ↓ ↵ ⇥ esc and respect input-method composition.
struct PHSearchField: NSViewRepresentable {
  let model: PHHUDModel
  let onCommand: (Selector) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model, onCommand: onCommand)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 18)
    field.placeholderString = String(localized: "Search titles or text")
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.model = model
    context.coordinator.onCommand = onCommand
    let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    if !composing, field.stringValue != model.query {
      field.stringValue = model.query
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var model: PHHUDModel
    var onCommand: (Selector) -> Bool

    init(model: PHHUDModel, onCommand: @escaping (Selector) -> Bool) {
      self.model = model
      self.onCommand = onCommand
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      // Do not filter on uncommitted pinyin.
      if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
      model.setQuery(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      onCommand(commandSelector)
    }
  }
}
