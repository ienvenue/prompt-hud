import AppKit
import Observation
import SwiftUI

/// One form for capturing (⌃⇧/) and editing (⌘E). Fields: 保存到, 标题, 分类, 置顶, 正文.
@Observable
final class PHCaptureModel {
  enum Mode: Equatable {
    /// Save the text as a new prompt.
    case new
    /// Replace the text of an existing prompt (chosen in "保存到").
    case replace(id: String)
    /// Edit an existing prompt (⌘E in the HUD).
    case edit(id: String)
  }

  enum Menu { case target, category }

  struct TargetRow {
    /// nil is "＋ 存为新提示词".
    let prompt: PHPrompt?
    let isSimilar: Bool
  }

  enum CategoryRow: Equatable {
    case create(String)
    case uncategorized
    case existing(String)
  }

  var mode: Mode = .new
  var title = ""
  var category = ""
  var pinned = false
  var content = ""
  var sourceApp: String?
  var hint: String?
  var error: String?
  /// Text of the prompt being replaced, shown crossed out.
  private(set) var oldContent: String?
  /// Title of the prompt being replaced or edited, as saved ("替换 · …", "编辑 · …").
  private(set) var targetTitle = ""
  private(set) var originalPinned = false
  var confirmingDelete = false

  private(set) var openMenu: Menu?
  var menuQuery = "" {
    didSet { if menuQuery != oldValue { menuIndex = 0 } }
  }
  var menuIndex = 0
  /// Up to 3 prompts with similar text, computed when the "保存到" menu opens.
  private(set) var similar: [PHPrompt] = []

  /// What was typed before choosing a prompt to replace, restored when going back to "新提示词".
  private var draft: (title: String, category: String, pinned: Bool)?

  var canSave: Bool { !content.phTrimmed.isEmpty }
  var isEditing: Bool { if case .edit = mode { return true } else { return false } }
  var isReplacing: Bool { if case .replace = mode { return true } else { return false } }

  /// Changes that alter the form height.
  var layoutKey: String { "\(isReplacing)|\(error ?? "")|\(hint ?? "")" }

  // MARK: Filling

  func fill(editing prompt: PHPrompt) {
    mode = .edit(id: prompt.id)
    title = prompt.title
    category = prompt.category ?? ""
    pinned = prompt.pinned
    content = prompt.prompt
    sourceApp = prompt.sourceApp
    targetTitle = prompt.title
    originalPinned = prompt.pinned
    oldContent = nil
    draft = nil
    hint = nil
    error = nil
    confirmingDelete = false
    openMenu = nil
  }

  func fill(text: String?, sourceApp: String?) {
    let value = text?.trimmingCharacters(in: .newlines) ?? ""
    mode = .new
    content = value
    title = value.isEmpty ? "" : PHPrompt.defaultTitle(for: value)
    category = ""
    pinned = false
    targetTitle = ""
    originalPinned = false
    oldContent = nil
    draft = nil
    confirmingDelete = false
    openMenu = nil
    self.sourceApp = sourceApp
    error = nil
    if !PHPermissions.isTrusted {
      hint = String(localized: "Accessibility permission is off, so the selected text can’t be read. Paste the text here instead.")
    } else if value.isEmpty {
      hint = String(localized: "No selected text found. Paste the text here instead.")
    } else {
      hint = nil
    }
  }

  /// Fills a new prompt from a `prompthud://add` link (the "存入 HUD" button on Prompt Lib).
  func fill(imported item: PHImportLink) {
    fill(text: item.prompt, sourceApp: PHImportLink.sourceName)
    if let title = item.title { self.title = title }
    category = item.category ?? ""
    hint = String(localized: "From a web link. Check it, then press ⌘↵ to save.")
  }

  // MARK: Menus

  var targetRows: [TargetRow] {
    let query = menuQuery.phTrimmed
    let base = PHSearch.search(query, in: PHStore.shared.prompts)
    let baseIDs = Set(base.map(\.id))
    let similarRows = similar.filter { baseIDs.contains($0.id) }
    let similarIDs = Set(similarRows.map(\.id))
    return [TargetRow(prompt: nil, isSimilar: false)]
      + similarRows.map { TargetRow(prompt: $0, isSimilar: true) }
      + base.filter { !similarIDs.contains($0.id) }.map { TargetRow(prompt: $0, isSimilar: false) }
  }

  var categoryRows: [CategoryRow] {
    let query = menuQuery.phTrimmed
    var existing = PHStore.shared.categories.filter { $0 != PHPrompt.uncategorized }
    let current = category.phTrimmed
    if !current.isEmpty, current != PHPrompt.uncategorized, !existing.contains(current) {
      existing.insert(current, at: 0)
    }
    var rows: [CategoryRow] = []
    if !query.isEmpty, query != PHPrompt.uncategorized, !existing.contains(query) {
      rows.append(.create(query))
    }
    if query.isEmpty || PHPrompt.uncategorized.localizedCaseInsensitiveContains(query) {
      rows.append(.uncategorized)
    }
    rows += existing
      .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
      .map { .existing($0) }
    return rows
  }

  func toggleMenu(_ menu: Menu) {
    if openMenu == menu {
      closeMenu()
      return
    }
    menuQuery = ""
    switch menu {
    case .target:
      guard !isEditing else { return }
      similar = PHSearch.similar(to: content, in: PHStore.shared.prompts)
      if case .replace(let id) = mode, let index = targetRows.firstIndex(where: { $0.prompt?.id == id }) {
        menuIndex = index
      } else {
        menuIndex = similar.isEmpty ? 0 : 1
      }
    case .category:
      let current = category.phTrimmed
      let wanted: CategoryRow = current.isEmpty ? .uncategorized : .existing(current)
      menuIndex = categoryRows.firstIndex(of: wanted) ?? 0
    }
    openMenu = menu
  }

  func closeMenu() {
    openMenu = nil
  }

  func moveMenu(_ step: Int) {
    let count = openMenu == .target ? targetRows.count : categoryRows.count
    guard count > 0 else { return }
    menuIndex = (menuIndex + step + count) % count
  }

  func chooseHighlighted() {
    switch openMenu {
    case .target:
      let rows = targetRows
      if rows.indices.contains(menuIndex) { chooseTarget(rows[menuIndex]) }
    case .category:
      let rows = categoryRows
      if rows.indices.contains(menuIndex) { chooseCategory(rows[menuIndex]) }
    case nil:
      break
    }
  }

  private func chooseTarget(_ row: TargetRow) {
    if let prompt = row.prompt {
      if mode == .new {
        draft = (title, category, pinned)
      }
      mode = .replace(id: prompt.id)
      title = prompt.title
      category = prompt.category ?? ""
      pinned = prompt.pinned
      targetTitle = prompt.title
      originalPinned = prompt.pinned
      oldContent = prompt.prompt
    } else {
      if isReplacing, let draft {
        title = draft.title
        category = draft.category
        pinned = draft.pinned
      }
      mode = .new
      draft = nil
      targetTitle = ""
      originalPinned = false
      oldContent = nil
    }
    error = nil
    closeMenu()
  }

  private func chooseCategory(_ row: CategoryRow) {
    switch row {
    case .create(let name), .existing(let name):
      category = name
    case .uncategorized:
      category = ""
    }
    closeMenu()
  }
}

final class PHCaptureController {
  private let model = PHCaptureModel()
  private lazy var panel = PHPanel(size: NSSize(width: 580, height: 480))
  private var keyMonitor: Any?
  private var anchor = NSRect.zero
  private var isReading = false

  func start() {
    if panel.isVisible {
      close()
      return
    }
    guard !isReading else { return }
    isReading = true

    let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
    anchor = PHCaretLocator.locate().rect
    PHSelectionReader.read { [weak self] text in
      self?.isReading = false
      self?.present(text: text, sourceApp: sourceApp)
    }
  }

  /// Opens the form to edit an existing prompt (⌘E in the HUD).
  func edit(_ prompt: PHPrompt, near anchor: NSRect) {
    if panel.isVisible { close() }
    self.anchor = anchor
    model.fill(editing: prompt)
    show(startWithContent: false)
  }

  /// Opens the form filled from a `prompthud://add` link, next to the mouse pointer.
  func open(_ item: PHImportLink) {
    if panel.isVisible { close() }
    let mouse = NSEvent.mouseLocation
    anchor = NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
    model.fill(imported: item)
    show(startWithContent: false)
  }

  private func present(text: String?, sourceApp: String?) {
    model.fill(text: text, sourceApp: sourceApp)
    show(startWithContent: text == nil)
  }

  private func show(startWithContent: Bool) {
    let view = PHCaptureView(
      model: model,
      startWithContent: startWithContent,
      onSave: { [weak self] in self?.save() },
      onCancel: { [weak self] in self?.close(cancelled: true) },
      onConfirmDelete: { [weak self] in self?.delete() },
      onResize: { [weak self] in self?.panel.resizeToFitContent() }
    )
    panel.setRootView(view)
    panel.present(at: PHPlacement.origin(for: panel.frame.size, anchor: anchor), key: true)
    panel.onResignKey = { [weak self] in self?.close(cancelled: true) }
    installMonitor()
  }

  private func save() {
    guard model.canSave else {
      NSSound.beep()
      return
    }
    let mode = model.mode
    let result: PHStore.AddResult
    switch mode {
    case .new:
      result = PHStore.shared.add(
        title: model.title,
        category: model.category,
        pinned: model.pinned,
        content: model.content,
        sourceApp: model.sourceApp
      )
    case .replace(let id), .edit(let id):
      result = PHStore.shared.update(
        id: id,
        title: model.title,
        category: model.category,
        pinned: model.pinned,
        content: model.content
      )
    }

    switch result {
    case .added(let prompt):
      let source = model.sourceApp ?? ""
      let pinChanged = prompt.pinned != model.originalPinned
      close()
      switch mode {
      case .new:
        PHUsage.log(.captureSaved, ["source": source])
        PHToast.shared.show(String(localized: "Added “\(prompt.title)”"), near: anchor)
      case .replace:
        PHUsage.log(.replace, ["source": source])
        PHToast.shared.show(String(localized: "Replaced “\(prompt.title)”"), near: anchor)
      case .edit:
        PHUsage.log(.edit, ["source": source])
        PHToast.shared.show(String(localized: "Saved “\(prompt.title)”"), near: anchor)
      }
      if pinChanged {
        PHUsage.log(.pin, ["pinned": prompt.pinned])
      }
    case .duplicate(let title):
      model.error = String(localized: "“\(title)” already has the same text, so this can’t be saved")
    case .failed(let message):
      model.error = message
    }
  }

  private func close(cancelled: Bool = false) {
    guard panel.isVisible else { return }
    if cancelled, !model.isEditing {
      PHUsage.log(.captureCancel)
    }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    panel.dismiss()
  }

  private func delete() {
    guard case .edit(let id) = model.mode else { return }
    let title = model.targetTitle
    if PHStore.shared.delete(id: id) {
      close()
      PHUsage.log(.delete)
      PHToast.shared.show(String(localized: "Deleted “\(title)”"), symbol: "trash", near: anchor)
    } else {
      model.confirmingDelete = false
      model.error = String(localized: "Couldn’t delete. The prompt file may be damaged.")
    }
  }

  private func installMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.panel.isKeyWindow, !self.panel.isComposingText else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let isReturn = event.keyCode == 36 || event.keyCode == 76
      let isEscape = event.keyCode == 53

      if self.model.confirmingDelete {
        if isEscape { self.model.confirmingDelete = false }
        return isEscape || isReturn ? nil : event
      }

      if self.model.openMenu != nil {
        switch event.keyCode {
        case 126: self.model.moveMenu(-1)
        case 125: self.model.moveMenu(1)
        case 36, 76: self.model.chooseHighlighted()
        case 53: self.model.closeMenu()
        default: return event
        }
        return nil
      }

      if isEscape {
        self.close(cancelled: true)
        return nil
      }
      if isReturn, flags.contains(.command) {
        self.save()
        return nil
      }
      return event
    }
  }
}

// MARK: - Views

struct PHCaptureView: View {
  @Bindable var model: PHCaptureModel
  let startWithContent: Bool
  let onSave: () -> Void
  let onCancel: () -> Void
  let onConfirmDelete: () -> Void
  let onResize: () -> Void

  private enum Field { case title, content, menuSearch }
  @FocusState private var focus: Field?

  // Fixed layout, so the menus can open right below their fields (design E2, E5).
  private static let width: CGFloat = 580
  private static let padding: CGFloat = 22
  private static let labelWidth: CGFloat = 64
  private static let rowHeight: CGFloat = 38
  private static let rowSpacing: CGFloat = 12
  private static let headerHeight: CGFloat = 56
  private static let fieldX = padding + labelWidth + 12
  private static let targetMenuY = headerHeight + 1 + 18 + rowHeight + 4
  private static let categoryMenuY = targetMenuY + 2 * (rowHeight + rowSpacing)

  var body: some View {
    VStack(spacing: 0) {
      header
      PHTheme.formDivider.frame(height: 1)
      VStack(alignment: .leading, spacing: Self.rowSpacing) {
        row(String(localized: "Save to")) { targetButton }
        row(String(localized: "Title")) {
          TextField("Defaults to the start of the text", text: $model.title)
            .textFieldStyle(.plain)
            .font(.system(size: 14.5))
            .focused($focus, equals: .title)
            .modifier(PHFieldBox())
        }
        row(String(localized: "Category")) { categoryButton }
        row(String(localized: "Pin")) {
          Toggle("Pin", isOn: $model.pinned)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(PHTheme.accent)
        }
        if let old = model.oldContent {
          row(String(localized: "Old text"), alignTop: true) { oldText(old) }
        }
        row(model.isReplacing ? String(localized: "New text") : String(localized: "Text"), alignTop: true) { editor }
        if let message = model.error ?? model.hint {
          Label(message, systemImage: model.error == nil ? "info.circle" : "exclamationmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(model.error == nil ? PHTheme.label : PHTheme.danger)
            .padding(.leading, Self.labelWidth + 12)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, Self.padding)
      .padding(.vertical, 18)

      if model.isReplacing {
        Text("Replacing can’t be undone.")
          .font(.system(size: 12.5))
          .foregroundStyle(PHTheme.warning)
          .padding(.leading, Self.fieldX)
          .padding(.bottom, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      PHTheme.formDivider.frame(height: 1)
      footer
    }
    .frame(width: Self.width)
    .background(PHTheme.formBackground)
    .overlay(alignment: .topLeading) { menuLayer }
    .overlay { if model.confirmingDelete { deleteDialog } }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
    )
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        focus = startWithContent ? .content : .title
      }
    }
    .onChange(of: model.layoutKey) { _, _ in
      DispatchQueue.main.async { onResize() }
    }
    .onChange(of: model.openMenu) { _, menu in
      DispatchQueue.main.async { focus = menu == nil ? .title : .menuSearch }
    }
  }

  // MARK: Parts

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: model.isEditing ? "pencil.circle.fill" : "plus.circle.fill")
        .font(.system(size: 20))
        .foregroundStyle(PHTheme.accent)
      Text(model.isEditing ? String(localized: "Edit Prompt") : String(localized: "Add Prompt"))
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(PHTheme.textPrimary)
      Spacer()
      if !model.isEditing, let source = model.sourceApp, !source.isEmpty {
        Text("From \(source)")
          .font(.system(size: 13))
          .foregroundStyle(PHTheme.textSecondary)
      }
    }
    .padding(.horizontal, Self.padding)
    .frame(height: Self.headerHeight)
  }

  private func row<Content: View>(
    _ label: String, alignTop: Bool = false, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: alignTop ? .top : .center, spacing: 12) {
      Text(label)
        .font(.system(size: 14))
        .foregroundStyle(PHTheme.label)
        .frame(width: Self.labelWidth, alignment: .leading)
        .padding(.top, alignTop ? 9 : 0)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var targetButton: some View {
    let label: String
    switch model.mode {
    case .new: label = String(localized: "＋ New prompt")
    case .replace: label = String(localized: "Replace · \(model.targetTitle)")
    case .edit: label = String(localized: "Edit · \(model.targetTitle)")
    }
    let isOpen = model.openMenu == .target
    return Button {
      model.toggleMenu(.target)
    } label: {
      HStack(spacing: 8) {
        Text(label)
          .font(.system(size: 14.5))
          .foregroundStyle(model.isReplacing ? PHTheme.replaceText : PHTheme.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if !model.isEditing {
          chevron
        }
      }
      .modifier(PHFieldBox(
        fill: model.isReplacing ? PHTheme.selection : PHTheme.fieldBackground,
        stroke: model.isReplacing ? PHTheme.replaceBorder : (isOpen ? PHTheme.accent : PHTheme.fieldBorder),
        ring: isOpen
      ))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.isEditing)
  }

  private var categoryButton: some View {
    let isOpen = model.openMenu == .category
    let value = model.category.phTrimmed
    return Button {
      model.toggleMenu(.category)
    } label: {
      HStack(spacing: 8) {
        Text(value.isEmpty ? PHPrompt.uncategorized : value)
          .font(.system(size: 14.5))
          .foregroundStyle(value.isEmpty ? PHTheme.textSecondary : PHTheme.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 4)
        chevron
      }
      .modifier(PHFieldBox(stroke: isOpen ? PHTheme.accent : PHTheme.fieldBorder, ring: isOpen))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var chevron: some View {
    Image(systemName: "chevron.down")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(PHTheme.label)
  }

  private func oldText(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Will be replaced")
        .font(.system(size: 12))
        .foregroundStyle(PHTheme.label)
      Text(text)
        .font(.system(size: 13.5))
        .foregroundStyle(PHTheme.label)
        .strikethrough(color: PHTheme.label.opacity(0.45))
        .lineSpacing(4)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PHTheme.oldTextBackground))
  }

  private var editor: some View {
    TextEditor(text: $model.content)
      .font(.system(size: 14))
      .lineSpacing(5)
      .scrollContentBackground(.hidden)
      .padding(.horizontal, 7)
      .padding(.vertical, 8)
      .frame(height: model.isReplacing ? 96 : 130)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PHTheme.fieldBackground))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(PHTheme.fieldBorder, lineWidth: 1)
      )
      .focused($focus, equals: .content)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if model.isEditing {
        Button {
          model.confirmingDelete = true
        } label: {
          Text("Delete")
            .font(.system(size: 15))
            .foregroundStyle(PHTheme.danger)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Spacer()
      Button(action: onCancel) {
        HStack(spacing: 8) {
          Text("Cancel")
          PHKeycap("esc")
        }
        .font(.system(size: 15))
        .foregroundStyle(PHTheme.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PHTheme.cancelBackground))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button(action: onSave) {
        HStack(spacing: 8) {
          Text(model.isReplacing ? String(localized: "Replace") : String(localized: "Save"))
            .font(.system(size: 15, weight: .semibold))
          Text("⌘↵")
            .font(.system(size: 12))
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PHTheme.accent))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!model.canSave)
      .opacity(model.canSave ? 1 : 0.5)
    }
    .padding(.horizontal, Self.padding)
    .frame(height: 68)
  }

  // MARK: Menus

  @ViewBuilder
  private var menuLayer: some View {
    if let menu = model.openMenu {
      ZStack(alignment: .topLeading) {
        // Clicking outside the menu closes it.
        Color.black.opacity(0.001)
          .onTapGesture { model.closeMenu() }
        menuCard(menu)
          .frame(width: Self.width - Self.fieldX - Self.padding)
          .offset(x: Self.fieldX, y: menu == .target ? Self.targetMenuY : Self.categoryMenuY)
      }
    }
  }

  private func menuCard(_ menu: PHCaptureModel.Menu) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(PHTheme.textSecondary)
        TextField(
          menu == .target ? String(localized: "Search prompts to replace") : String(localized: "Search or add a category"),
          text: $model.menuQuery
        )
          .textFieldStyle(.plain)
          .font(.system(size: 14))
          .focused($focus, equals: .menuSearch)
      }
      .padding(.horizontal, 10)
      .frame(height: 38)
      PHTheme.divider.frame(height: 1)
        .padding(.bottom, 4)
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 0) {
            if menu == .target { targetRows } else { categoryRows }
          }
        }
        .frame(height: menuListHeight(menu))
        .onChange(of: model.menuIndex) { _, index in proxy.scrollTo(index) }
      }
    }
    .padding(6)
    .background(PHTheme.menuBackground)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
    )
    .shadow(color: Color.black.opacity(0.22), radius: 22, y: 14)
  }

  private static let menuRowHeight: CGFloat = 36
  private static let menuHeaderHeight: CGFloat = 24

  private func menuListHeight(_ menu: PHCaptureModel.Menu) -> CGFloat {
    let content: CGFloat
    let limit: CGFloat
    if menu == .target {
      let rows = model.targetRows
      let similarCount = rows.filter(\.isSimilar).count
      let otherCount = rows.count - 1 - similarCount
      content = CGFloat(rows.count) * Self.menuRowHeight
        + (similarCount > 0 ? Self.menuHeaderHeight : 0)
        + (otherCount > 0 ? Self.menuHeaderHeight : 0)
      limit = 300
    } else {
      let rows = model.categoryRows
      content = CGFloat(rows.count) * Self.menuRowHeight + (rows.first.map { if case .create = $0 { 9 } else { 0 } } ?? 0)
      limit = 230
    }
    return min(max(content, Self.menuRowHeight), limit)
  }

  @ViewBuilder
  private var targetRows: some View {
    let rows = model.targetRows
    let firstSimilar = rows.firstIndex { $0.isSimilar }
    let firstOther = rows.indices.first { $0 > 0 && !rows[$0].isSimilar }
    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
      if index == firstSimilar { menuHeader(String(localized: "Similar text")) }
      if index == firstOther { menuHeader(String(localized: "Replace another")) }
      if let prompt = row.prompt {
        menuRow(
          index: index,
          title: prompt.title,
          trailing: row.isSimilar ? String(localized: "\(prompt.categoryName) · very similar") : prompt.categoryName,
          checked: model.mode == .replace(id: prompt.id)
        )
      } else {
        menuRow(index: index, title: String(localized: "＋ Save as a new prompt"), checked: model.mode == .new)
      }
    }
  }

  @ViewBuilder
  private var categoryRows: some View {
    let rows = model.categoryRows
    let current = model.category.phTrimmed
    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
      switch row {
      case .create(let name):
        menuRow(index: index, title: String(localized: "New category “\(name)”"), trailing: "↵", icon: "plus", tint: PHTheme.replaceText)
        PHTheme.divider.frame(height: 1).padding(.vertical, 4)
      case .uncategorized:
        menuRow(index: index, title: PHPrompt.uncategorized, trailing: String(localized: "Default when empty"), checked: current.isEmpty)
      case .existing(let name):
        menuRow(index: index, title: name, checked: current == name)
      }
    }
  }

  private func menuHeader(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(PHTheme.label)
      .padding(.leading, 34)
      .padding(.top, 8)
      .padding(.bottom, 2)
      .frame(height: Self.menuHeaderHeight, alignment: .bottomLeading)
  }

  private func menuRow(
    index: Int, title: String, trailing: String? = nil, checked: Bool = false,
    icon: String? = nil, tint: Color? = nil
  ) -> some View {
    HStack(spacing: 10) {
      Group {
        if checked {
          Image(systemName: "checkmark")
        } else if let icon {
          Image(systemName: icon)
        } else {
          Color.clear
        }
      }
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(PHTheme.accent)
      .frame(width: 14)
      Text(title)
        .font(.system(size: 14))
        .foregroundStyle(tint ?? PHTheme.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let trailing {
        Text(trailing)
          .font(.system(size: 12))
          .foregroundStyle(tint ?? PHTheme.label)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: Self.menuRowHeight)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(index == model.menuIndex ? PHTheme.selection : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      model.menuIndex = index
      model.chooseHighlighted()
    }
    .id(index)
  }

  // MARK: Delete confirmation (E6)

  private var deleteDialog: some View {
    ZStack {
      Color(red: 20 / 255, green: 22 / 255, blue: 28 / 255).opacity(0.28)
      VStack(alignment: .leading, spacing: 8) {
        Text("Delete this prompt?")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PHTheme.textPrimary)
        Text("“\(model.targetTitle)” will be deleted. This can’t be undone.")
          .font(.system(size: 13.5))
          .foregroundStyle(PHTheme.bodyText)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Button {
            model.confirmingDelete = false
          } label: {
            Text("Cancel")
              .font(.system(size: 14.5))
              .foregroundStyle(PHTheme.textPrimary)
              .frame(maxWidth: .infinity)
              .frame(height: 38)
              .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PHTheme.cancelBackground))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Button(action: onConfirmDelete) {
            Text("Delete")
              .font(.system(size: 14.5, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .frame(height: 38)
              .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PHTheme.danger))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 10)
      }
      .padding(20)
      .frame(width: 320)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PHTheme.popupBackground))
      .shadow(color: Color.black.opacity(0.3), radius: 25, y: 20)
    }
  }
}

/// Rounded white box used by the form's text field and pickers.
private struct PHFieldBox: ViewModifier {
  var fill: Color = PHTheme.fieldBackground
  var stroke: Color = PHTheme.fieldBorder
  var ring = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 12)
      .frame(height: 38)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(stroke, lineWidth: 1)
      )
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(ring ? PHTheme.accent.opacity(0.22) : Color.clear)
          .padding(-3)
      )
  }
}

// MARK: - Links

/// `prompthud://add?title=…&category=…&prompt=…`. Any web page can send this link,
/// so it only fills the form; the user still has to press ⌘↵ to save.
struct PHImportLink {
  static let scheme = "prompthud"
  static let sourceName = "Prompt Lib"
  private static let maxPrompt = 20_000
  private static let maxField = 200

  let title: String?
  let category: String?
  let prompt: String

  init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "add",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func value(_ name: String, limit: Int) -> String? {
      guard let text = items.first(where: { $0.name == name })?.value?.phTrimmed, !text.isEmpty else { return nil }
      return String(text.prefix(limit))
    }
    guard let prompt = value("prompt", limit: Self.maxPrompt) else { return nil }
    self.prompt = prompt
    title = value("title", limit: Self.maxField)
    category = value("category", limit: Self.maxField)
  }
}
