import AppKit
import Observation

/// The prompt library lives in a folder that iCloud Drive syncs between Macs:
///
///     iCloud Drive/Prompt HUD/prompts/<id>.json   one file per prompt
///     iCloud Drive/Prompt HUD/usage/<mac>.json    usage counts; each Mac writes only its own file
///     iCloud Drive/Prompt HUD/settings.json       synced settings
///
/// Without iCloud Drive the same folder is kept in Application Support and not synced.
/// Backups, the usage log and this Mac's own copy of its usage stay local.
/// Changes are picked up by polling. A file iCloud has not downloaded yet is never treated as deleted.
@Observable
final class PHStore {
  static let shared = PHStore()

  enum AddResult {
    case added(PHPrompt)
    case duplicate(String)
    case failed(String)
  }

  enum Location {
    case iCloud
    case local
  }

  private(set) var prompts: [PHPrompt] = []
  private(set) var loadError: String?
  private(set) var location: Location = .local
  /// Files iCloud has not downloaded to this Mac yet.
  private(set) var pendingCount = 0

  /// Local data folder: ~/Library/Application Support/PromptHUD (not synced).
  let directoryURL: URL
  /// The synced library folder.
  private(set) var libraryURL: URL
  /// One snapshot of the whole library before each content change. The newest 50 are kept.
  var backupsURL: URL { directoryURL.appendingPathComponent("backups", isDirectory: true) }
  private static let backupLimit = 50
  static let cloudFolderName = "Prompt HUD"

  private var promptsURL: URL { libraryURL.appendingPathComponent("prompts", isDirectory: true) }
  private var usageURL: URL { libraryURL.appendingPathComponent("usage", isDirectory: true) }
  private var settingsURL: URL { libraryURL.appendingPathComponent("settings.json") }
  private var legacyFileURL: URL { directoryURL.appendingPathComponent("prompts.json") }
  private var localLibraryURL: URL { directoryURL.appendingPathComponent("library", isDirectory: true) }
  private var ownUsageCopyURL: URL { directoryURL.appendingPathComponent("usage-this-mac.json") }
  private var ownUsageFileName: String { "\(macID).json" }

  @ObservationIgnored private let macID: String
  @ObservationIgnored private let cloudOverride: URL?
  /// This Mac's usage, by prompt id. Only this Mac writes it, so the local copy is always the newest.
  @ObservationIgnored private var ownUsage: [String: UsageEntry] = [:]
  /// Other Macs' usage, by file name.
  @ObservationIgnored private var otherUsage: [String: [String: UsageEntry]] = [:]
  @ObservationIgnored private var categoryOrder: [String] = []
  /// Familiar threshold as last read from or written to settings.json.
  @ObservationIgnored private var syncedThreshold: Int?
  @ObservationIgnored private var settingsReadable = false
  /// Last parsed content of each prompt file, used while iCloud re-downloads it.
  @ObservationIgnored private var promptCache: [String: PromptFile] = [:]
  /// File URL of each prompt id, so edits and deletes go to the right file.
  @ObservationIgnored private var promptFileURLs: [String: URL] = [:]
  @ObservationIgnored private var folderSignature: [String: String] = [:]
  @ObservationIgnored private var contentSignature: String?
  @ObservationIgnored private var skipNextBackup = false
  @ObservationIgnored private var pollTimer: Timer?

  /// Categories in the synced order, then new ones by age; "未分类" always last.
  /// Only categories that have prompts are listed.
  var categories: [String] {
    var firstCreated: [String: Date] = [:]
    for prompt in prompts where prompt.categoryName != PHPrompt.uncategorized {
      let date = prompt.createdAt ?? .distantPast
      firstCreated[prompt.categoryName] = min(firstCreated[prompt.categoryName] ?? date, date)
    }
    let known = categoryOrder.filter { firstCreated[$0] != nil }
    let rest = firstCreated.keys.filter { !known.contains($0) }.sorted {
      firstCreated[$0]! != firstCreated[$1]! ? firstCreated[$0]! < firstCreated[$1]! : $0 < $1
    }
    var result = known + rest
    if prompts.contains(where: { $0.categoryName == PHPrompt.uncategorized }) {
      result.append(PHPrompt.uncategorized)
    }
    return result
  }

  private init() {
    let fileManager = FileManager.default
    let defaults = UserDefaults.standard
    // -phLocalRoot / -phSyncRoot launch arguments point the app at test folders.
    if let path = defaults.string(forKey: "phLocalRoot") {
      directoryURL = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      directoryURL = base.appendingPathComponent("PromptHUD", isDirectory: true)
    }
    cloudOverride = defaults.string(forKey: "phSyncRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
    try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let idURL = directoryURL.appendingPathComponent("mac-id")
    if let saved = try? String(contentsOf: idURL, encoding: .utf8), !saved.phTrimmed.isEmpty {
      macID = saved.phTrimmed
    } else {
      macID = UUID().uuidString
      try? macID.write(to: idURL, atomically: true, encoding: .utf8)
    }

    libraryURL = directoryURL.appendingPathComponent("library", isDirectory: true)
    ownUsage = Self.readUsage(at: ownUsageCopyURL) ?? [:]
    chooseLocation()
    prepareLibrary()
    startPolling()
  }

  // MARK: Location

  private var cloudLibraryURL: URL? {
    if let cloudOverride { return cloudOverride }
    let drive = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return nil
    }
    return drive.appendingPathComponent(Self.cloudFolderName, isDirectory: true)
  }

  private func chooseLocation() {
    if let cloud = cloudLibraryURL {
      libraryURL = cloud
      location = .iCloud
    } else {
      libraryURL = localLibraryURL
      location = .local
    }
  }

  /// Creates the folders, moves older data in, then loads.
  private func prepareLibrary() {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: promptsURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: usageURL, withIntermediateDirectories: true)
    } catch {
      loadError = String(localized: "Can’t create the prompts folder: \(error.localizedDescription)")
      return
    }
    loadError = nil
    migrateIfNeeded()
    folderSignature = [:]
    load()
  }

  // MARK: Migration

  private func migrateIfNeeded() {
    let fileManager = FileManager.default
    let marker = directoryURL.appendingPathComponent("library-created")

    // 1. The single prompts.json of 1.2 and earlier.
    if fileManager.fileExists(atPath: legacyFileURL.path) {
      do {
        let data = try Data(contentsOf: legacyFileURL)
        let legacy = try PHCodec.decode(data).prompts
        backUp(data: data)
        merge(legacy, order: Self.categoryOrder(of: legacy))
        moveAside(legacyFileURL, to: "prompts.migrated")
        fileManager.createFile(atPath: marker.path, contents: nil)
      } catch let error as PHFileError {
        loadError = String(localized: "Can’t read the old prompts file, so it wasn’t moved: \(error.message)")
      } catch {
        loadError = String(localized: "Can’t read the old prompts file, so it wasn’t moved: \(error.localizedDescription)")
      }
    }

    // 2. A library kept on this Mac while iCloud Drive was off.
    if location == .iCloud, libraryURL != localLibraryURL,
       let names = try? fileManager.contentsOfDirectory(atPath: localLibraryURL.appendingPathComponent("prompts").path),
       !names.isEmpty {
      let local = readPromptFolder(localLibraryURL.appendingPathComponent("prompts"), cleanUp: false)
      let items = local.live.map(withOwnUsage)
      try? backUp(data: PHCodec.encode(items))
      let localSettings = (try? Data(contentsOf: localLibraryURL.appendingPathComponent("settings.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      merge(items, order: localSettings?["categoryOrder"] as? [String] ?? [])
      moveAside(localLibraryURL, to: "library.migrated")
      fileManager.createFile(atPath: marker.path, contents: nil)
    }

    // 3. First run on this Mac with nothing to move: start with the default prompts.
    if !fileManager.fileExists(atPath: marker.path), !fileManager.fileExists(atPath: legacyFileURL.path) {
      let existing = (try? fileManager.contentsOfDirectory(atPath: promptsURL.path)) ?? []
      if existing.isEmpty {
        merge(PHDefaults.prompts, order: Self.categoryOrder(of: PHDefaults.prompts))
      }
      fileManager.createFile(atPath: marker.path, contents: nil)
    }
  }

  /// Adds prompts to the library. A prompt whose text is already there is not added twice:
  /// its title, category and pin come from whichever copy was edited last, and its usage is added.
  private func merge(_ source: [PHPrompt], order: [String]) {
    var current = readPromptFolder(promptsURL, cleanUp: false).live
    // Usage from `source` is carried in its usageCount, so drop any older entries for the same ids.
    for item in source { ownUsage.removeValue(forKey: item.id) }

    for item in source {
      let text = item.prompt.phTrimmed
      let target: PHPrompt
      if let index = current.firstIndex(where: { $0.prompt.phTrimmed == text }) {
        var match = current[index]
        if (item.updatedAt ?? .distantPast) > (match.updatedAt ?? .distantPast) {
          match.title = item.title
          match.category = item.category
          match.pinned = item.pinned
          match.updatedAt = item.updatedAt
          writePromptFile(match)
          current[index] = match
        }
        target = match
      } else {
        var new = item
        if new.id.isEmpty || current.contains(where: { $0.id == new.id }) || promptFileURLs[new.id] != nil
          || FileManager.default.fileExists(atPath: promptFileURL(for: new.id).path) {
          new.id = UUID().uuidString
        }
        new.contentVersion = UUID().uuidString
        writePromptFile(new)
        current.append(new)
        target = new
      }
      if item.usageCount > 0 || item.lastUsedAt != nil {
        addUsage(count: item.usageCount, lastUsedAt: item.lastUsedAt, to: target)
      }
    }
    saveOwnUsage()

    // Settings: keep the synced ones if another Mac already wrote them.
    if !fileExistsOrPending(settingsURL) {
      writeSettings(threshold: PHPreferences.familiarThreshold, order: order)
    }
  }

  /// The prompt with only this Mac's usage, for moving it into another library without counting other Macs twice.
  private func withOwnUsage(_ prompt: PHPrompt) -> PHPrompt {
    var result = prompt
    let entry = ownUsage[prompt.id]
    result.usageCount = entry?.contentVersion == prompt.contentVersion ? entry?.count ?? 0 : 0
    result.lastUsedAt = entry?.lastUsedAt
    return result
  }

  private func addUsage(count: Int, lastUsedAt: Date?, to prompt: PHPrompt) {
    var entry = ownUsage[prompt.id]
    if entry?.contentVersion != prompt.contentVersion {
      entry = UsageEntry(count: 0, lastUsedAt: entry?.lastUsedAt, contentVersion: prompt.contentVersion)
    }
    entry!.count += count
    entry!.lastUsedAt = [entry!.lastUsedAt, lastUsedAt].compactMap { $0 }.max()
    ownUsage[prompt.id] = entry
  }

  static func categoryOrder(of prompts: [PHPrompt]) -> [String] {
    var result: [String] = []
    for prompt in prompts where prompt.categoryName != PHPrompt.uncategorized && !result.contains(prompt.categoryName) {
      result.append(prompt.categoryName)
    }
    return result
  }

  /// Renames a migrated file or folder instead of deleting it.
  private func moveAside(_ url: URL, to baseName: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
    var target = directoryURL.appendingPathComponent(baseName + suffix)
    if FileManager.default.fileExists(atPath: target.path) {
      target = directoryURL.appendingPathComponent("\(baseName)-\(formatter.string(from: Date()))\(suffix)")
    }
    try? FileManager.default.moveItem(at: url, to: target)
  }

  // MARK: Loading

  /// Checks where the library is, moves older data in and reads everything again.
  func reload() {
    chooseLocation()
    prepareLibrary()
  }

  func load() {
    guard FileManager.default.fileExists(atPath: promptsURL.path) else { return }
    let previous = prompts
    let folder = readPromptFolder(promptsURL, cleanUp: true)
    var live = folder.live
    var merged = folder.merged
    pendingCount = folder.pending

    // The same text saved on two Macs before they synced: keep the oldest prompt, turn the others into
    // stubs that point to it. Every Mac picks the same one, and moves its own usage over.
    let groups = Dictionary(grouping: live) { $0.prompt.phTrimmed }.values.filter { $0.count > 1 }
    for group in groups {
      let sorted = group.sorted {
        ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id)
      }
      var keep = sorted[0]
      if let newest = group.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }),
         newest.id != keep.id,
         (newest.updatedAt ?? .distantPast) > (keep.updatedAt ?? .distantPast) {
        keep.title = newest.title
        keep.category = newest.category
        keep.pinned = newest.pinned
        keep.updatedAt = newest.updatedAt
        writePromptFile(keep)
      }
      for duplicate in sorted.dropFirst() {
        writeStub(for: duplicate, into: keep.id)
        merged[duplicate.id] = (keep.id, duplicate.contentVersion)
      }
      let removed = Set(sorted.dropFirst().map(\.id))
      live = live.filter { !removed.contains($0.id) }.map { $0.id == keep.id ? keep : $0 }
    }

    // Move this Mac's usage from merged prompts to the prompt they point to.
    var usageChanged = false
    for (id, stub) in merged {
      guard let entry = ownUsage[id] else { continue }
      var targetID = stub.into
      for _ in 0..<10 {
        guard let next = merged[targetID] else { break }
        targetID = next.into
      }
      guard let target = live.first(where: { $0.id == targetID }) else { continue }
      ownUsage.removeValue(forKey: id)
      let count = entry.contentVersion == stub.contentVersion ? entry.count : 0
      addUsage(count: count, lastUsedAt: entry.lastUsedAt, to: target)
      usageChanged = true
    }
    if usageChanged { saveOwnUsage() }

    readOtherUsage()
    readSettings()

    prompts = live.map(withUsage).sorted {
      let left = $0.createdAt ?? .distantPast
      let right = $1.createdAt ?? .distantPast
      if left != right { return left > right }
      return ($0.title, $0.id) < ($1.title, $1.id)
    }
    folderSignature = currentFolderSignature()

    // Back up what was there before a change that came from another Mac.
    let signature = Self.contentSignature(of: prompts)
    if let old = contentSignature, old != signature, !skipNextBackup, !previous.isEmpty {
      backUp(prompts: previous)
    }
    skipNextBackup = false
    contentSignature = signature
  }

  func reloadIfChanged() {
    if location == .local, cloudLibraryURL != nil {
      // iCloud Drive was turned on: move the local library in.
      chooseLocation()
      prepareLibrary()
      return
    }
    if location == .iCloud, cloudLibraryURL == nil {
      // iCloud Drive was turned off: keep using what was loaded, on this Mac only.
      let snapshot = prompts.map(withOwnUsage)
      let order = categoryOrder
      chooseLocation()
      prepareLibrary()
      if prompts.isEmpty, !snapshot.isEmpty {
        merge(snapshot, order: order)
        load()
      }
      return
    }
    if currentFolderSignature() != folderSignature {
      load()
    }
  }

  private func startPolling() {
    let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
      self?.reloadIfChanged()
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func withUsage(_ prompt: PHPrompt) -> PHPrompt {
    var result = prompt
    var count = 0
    var last: Date?
    for usage in [ownUsage] + Array(otherUsage.values) {
      guard let entry = usage[prompt.id] else { continue }
      if entry.contentVersion == prompt.contentVersion { count += entry.count }
      if let date = entry.lastUsedAt, date > (last ?? .distantPast) { last = date }
    }
    result.usageCount = count
    result.lastUsedAt = last
    return result
  }

  private static func contentSignature(of prompts: [PHPrompt]) -> String {
    prompts.map { "\($0.id)|\($0.title)|\($0.categoryName)|\($0.pinned)|\($0.contentVersion)|\($0.prompt)" }
      .sorted()
      .joined(separator: "\n")
  }

  // MARK: Reading files

  private enum PromptFile {
    case prompt(PHPrompt)
    case merged(id: String, into: String, contentVersion: String)
  }

  private struct FolderContent {
    var live: [PHPrompt] = []
    var merged: [String: (into: String, contentVersion: String)] = [:]
    var pending = 0
  }

  private static let resourceKeys: [URLResourceKey] = [
    .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
  ]

  /// Whether iCloud has the file's content on this Mac. Asks iCloud to download it when not.
  private static func isDownloaded(_ url: URL) -> Bool {
    if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" {
      // Placeholder of older macOS versions: ".name.json.icloud".
      let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
      try? FileManager.default.startDownloadingUbiquitousItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
      return false
    }
    let values = try? url.resourceValues(forKeys: Set(resourceKeys))
    if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      return false
    }
    return true
  }

  /// The real file name behind an iCloud placeholder.
  private static func itemName(_ url: URL) -> String {
    let name = url.lastPathComponent
    if name.hasPrefix("."), url.pathExtension == "icloud" {
      return String(url.deletingPathExtension().lastPathComponent.dropFirst())
    }
    return name
  }

  private static func jsonFiles(in folder: URL) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: resourceKeys, options: []
    )) ?? []
    return urls.filter { itemName($0).hasSuffix(".json") && !itemName($0).hasPrefix(".") }
  }

  /// `cleanUp` moves extra copies of the same prompt (iCloud conflict copies) into the backups folder.
  private func readPromptFolder(_ folder: URL, cleanUp: Bool) -> FolderContent {
    var content = FolderContent()
    var byID: [String: [(url: URL, prompt: PHPrompt)]] = [:]
    var stubURLs: [String: URL] = [:]
    var seenNames = Set<String>()

    for url in Self.jsonFiles(in: folder) {
      let name = Self.itemName(url)
      seenNames.insert(name)
      let parsed: PromptFile?
      if Self.isDownloaded(url) {
        parsed = Self.parsePromptFile(url)
        if parsed == nil { NSLog("PromptHUD: unreadable prompt file \(name)") }
        if let parsed, folder == promptsURL { promptCache[name] = parsed }
      } else {
        content.pending += 1
        parsed = folder == promptsURL ? promptCache[name] : nil
      }
      let fileURL = folder.appendingPathComponent(name)
      switch parsed {
      case .prompt(let prompt):
        byID[prompt.id, default: []].append((fileURL, prompt))
      case .merged(let id, let into, let version):
        content.merged[id] = (into, version)
        stubURLs[id] = fileURL
      case nil:
        break
      }
    }
    if folder == promptsURL {
      promptCache = promptCache.filter { seenNames.contains($0.key) }
      promptFileURLs = stubURLs
    }

    for (id, copies) in byID {
      if content.merged[id] != nil {
        if cleanUp { copies.forEach { moveToConflicts($0.url) } }
        continue
      }
      let sorted = copies.sorted {
        let left = $0.prompt.updatedAt ?? .distantPast
        let right = $1.prompt.updatedAt ?? .distantPast
        if left != right { return left > right }
        return $0.url.lastPathComponent.count < $1.url.lastPathComponent.count
      }
      content.live.append(sorted[0].prompt)
      if folder == promptsURL { promptFileURLs[id] = sorted[0].url }
      if cleanUp { sorted.dropFirst().forEach { moveToConflicts($0.url) } }
    }
    return content
  }

  private static func parsePromptFile(_ url: URL) -> PromptFile? {
    guard let data = try? Data(contentsOf: url),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    if let into = dict["mergedInto"] as? String, let id = dict["id"] as? String {
      return .merged(id: id, into: into, contentVersion: dict["contentVersion"] as? String ?? "")
    }
    guard dict["id"] as? String != nil, let prompt = PHPrompt(dictionary: dict) else { return nil }
    return .prompt(prompt)
  }

  private func readOtherUsage() {
    var result: [String: [String: UsageEntry]] = [:]
    for url in Self.jsonFiles(in: usageURL) {
      let name = Self.itemName(url)
      guard name != ownUsageFileName else { continue }
      if Self.isDownloaded(url), let usage = Self.readUsage(at: url) {
        result[name] = usage
      } else if let cached = otherUsage[name] {
        result[name] = cached
      }
    }
    otherUsage = result
  }

  private func readSettings() {
    settingsReadable = false
    guard FileManager.default.fileExists(atPath: settingsURL.path), Self.isDownloaded(settingsURL),
          let data = try? Data(contentsOf: settingsURL),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      if !fileExistsOrPending(settingsURL) { settingsReadable = true }
      return
    }
    settingsReadable = true
    categoryOrder = dict["categoryOrder"] as? [String] ?? []
    if let threshold = (dict["familiarThreshold"] as? NSNumber)?.intValue, threshold >= 1 {
      syncedThreshold = threshold
      if UserDefaults.standard.integer(forKey: PHPreferences.familiarThresholdKey) != threshold {
        UserDefaults.standard.set(threshold, forKey: PHPreferences.familiarThresholdKey)
      }
    }
  }

  /// File names, dates and download states, to notice changes cheaply.
  private func currentFolderSignature() -> [String: String] {
    var result: [String: String] = [:]
    let files = Self.jsonFiles(in: promptsURL) + Self.jsonFiles(in: usageURL) + [settingsURL]
    for url in files {
      let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
      let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
      let status = values?.ubiquitousItemDownloadingStatus?.rawValue ?? ""
      result[url.path] = "\(date)|\(status)"
    }
    return result
  }

  private func fileExistsOrPending(_ url: URL) -> Bool {
    let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
  }

  // MARK: Writing files

  private func promptFileURL(for id: String) -> URL {
    promptsURL.appendingPathComponent("\(id).json")
  }

  @discardableResult
  private func writePromptFile(_ prompt: PHPrompt) -> Bool {
    let url = promptFileURLs[prompt.id] ?? promptFileURL(for: prompt.id)
    do {
      try PHCodec.json(prompt.fileDictionary).write(to: url, options: .atomic)
      promptFileURLs[prompt.id] = url
      return true
    } catch {
      NSLog("PromptHUD: save failed: \(error)")
      return false
    }
  }

  private func writeStub(for prompt: PHPrompt, into id: String) {
    let stub: [String: Any] = [
      "id": prompt.id,
      "mergedInto": id,
      "contentVersion": prompt.contentVersion,
      "updatedAt": PHDate.format(Date()),
      "schemaVersion": PHCodec.promptFileVersion
    ]
    let url = promptFileURLs[prompt.id] ?? promptFileURL(for: prompt.id)
    try? PHCodec.json(stub).write(to: url, options: .atomic)
  }

  private func moveToConflicts(_ url: URL) {
    let folder = backupsURL.appendingPathComponent("conflicts", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let name = "\(url.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date())).json"
    try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(name))
  }

  private func saveOwnUsage() {
    var entries: [String: Any] = [:]
    for (id, entry) in ownUsage { entries[id] = entry.dictionary }
    let root: [String: Any] = [
      "schemaVersion": 1,
      "mac": macID,
      "name": Self.computerName,
      "updatedAt": PHDate.format(Date()),
      "prompts": entries
    ]
    guard let data = try? PHCodec.json(root) else { return }
    try? data.write(to: ownUsageCopyURL, options: .atomic)
    try? data.write(to: usageURL.appendingPathComponent(ownUsageFileName), options: .atomic)
  }

  private static let computerName = Host.current().localizedName ?? ""

  private static func readUsage(at url: URL) -> [String: UsageEntry]? {
    guard let data = try? Data(contentsOf: url),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let items = root["prompts"] as? [String: Any] else { return nil }
    var result: [String: UsageEntry] = [:]
    for (id, value) in items {
      if let dict = value as? [String: Any] { result[id] = UsageEntry(dictionary: dict) }
    }
    return result
  }

  private func writeSettings(threshold: Int, order: [String]) {
    let root: [String: Any] = [
      "schemaVersion": 1,
      "familiarThreshold": threshold,
      "categoryOrder": order,
      "updatedAt": PHDate.format(Date())
    ]
    guard let data = try? PHCodec.json(root) else { return }
    try? data.write(to: settingsURL, options: .atomic)
    syncedThreshold = threshold
    categoryOrder = order
    settingsReadable = true
  }

  /// Called when the threshold changes in Settings. Not written while iCloud is still downloading settings.json.
  func saveFamiliarThreshold(_ value: Int) {
    guard value >= 1, value != syncedThreshold, settingsReadable else { return }
    writeSettings(threshold: value, order: categoryOrder)
  }

  // MARK: Backups

  private func backUp(prompts snapshot: [PHPrompt]) {
    guard !snapshot.isEmpty, let data = try? PHCodec.encode(snapshot) else { return }
    backUp(data: data)
  }

  private func backUp(data: Data) {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let stamp = formatter.string(from: Date())
    var target = backupsURL.appendingPathComponent("prompts-\(stamp).json")
    var number = 2
    while fileManager.fileExists(atPath: target.path) {
      target = backupsURL.appendingPathComponent("prompts-\(stamp)-\(number).json")
      number += 1
    }
    try? data.write(to: target, options: .atomic)

    let backups = (try? fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
    let old = backups
      .filter { $0.lastPathComponent.hasPrefix("prompts-") && $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      .dropFirst(Self.backupLimit)
    for url in old {
      try? fileManager.removeItem(at: url)
    }
  }

  // MARK: Mutations

  func recordUsage(id: String) {
    guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
    addUsage(count: 1, lastUsedAt: Date(), to: prompts[index])
    saveOwnUsage()
    prompts[index] = withUsage(prompts[index])
  }

  func add(title: String, category: String, pinned: Bool, content: String, sourceApp: String?) -> AddResult {
    if let error = loadError {
      return .failed(String(localized: "The prompts folder isn’t available: \(error)"))
    }

    let text = content.phTrimmed
    guard !text.isEmpty else { return .failed(String(localized: "The text can’t be empty")) }

    if let existing = prompts.first(where: { $0.prompt.phTrimmed == text }) {
      return .duplicate(existing.title)
    }

    let cleanTitle = title.phTrimmed
    let cleanCategory = category.phTrimmed
    var prompt = PHPrompt(
      title: cleanTitle.isEmpty ? PHPrompt.defaultTitle(for: text) : cleanTitle,
      category: cleanCategory.isEmpty ? nil : cleanCategory,
      prompt: content.trimmingCharacters(in: .newlines),
      sourceApp: sourceApp
    )
    prompt.pinned = pinned
    prompt.contentVersion = UUID().uuidString
    backUp(prompts: prompts)
    guard writePromptFile(prompt) else {
      return .failed(String(localized: "Couldn’t save. Check disk permissions."))
    }
    skipNextBackup = true
    load()
    return .added(prompt)
  }

  /// Edits a prompt, or replaces it with captured text. Both keep `id`, `createdAt`, `sourceApp`
  /// and the hidden `trigger` / `description` fields. The usage count starts over only when the text changes.
  func update(id: String, title: String, category: String, pinned: Bool, content: String) -> AddResult {
    if let error = loadError {
      return .failed(String(localized: "The prompts folder isn’t available: \(error)"))
    }
    guard let index = prompts.firstIndex(where: { $0.id == id }) else {
      return .failed(String(localized: "This prompt no longer exists. It may have been deleted on another Mac."))
    }
    let text = content.phTrimmed
    guard !text.isEmpty else { return .failed(String(localized: "The text can’t be empty")) }
    if let other = prompts.first(where: { $0.id != id && $0.prompt.phTrimmed == text }) {
      return .duplicate(other.title)
    }

    var edited = prompts[index]
    let cleanTitle = title.phTrimmed
    let cleanCategory = category.phTrimmed
    edited.title = cleanTitle.isEmpty ? PHPrompt.defaultTitle(for: text) : cleanTitle
    edited.category = cleanCategory.isEmpty ? nil : cleanCategory
    edited.pinned = pinned
    if edited.prompt.phTrimmed != text {
      edited.prompt = content.trimmingCharacters(in: .newlines)
      edited.contentVersion = UUID().uuidString
    }
    edited.updatedAt = Date()
    backUp(prompts: prompts)
    guard writePromptFile(edited) else {
      return .failed(String(localized: "Couldn’t save. Check disk permissions."))
    }
    skipNextBackup = true
    load()
    return .added(prompts.first { $0.id == id } ?? edited)
  }

  @discardableResult
  func delete(id: String) -> Bool {
    guard loadError == nil, prompts.contains(where: { $0.id == id }) else { return false }
    let url = promptFileURLs[id] ?? promptFileURL(for: id)
    backUp(prompts: prompts)
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      NSLog("PromptHUD: delete failed: \(error)")
      return false
    }
    promptFileURLs.removeValue(forKey: id)
    skipNextBackup = true
    load()
    return true
  }

  /// Share of prompts not used (or created) in the last 30 days.
  var staleShare: Double {
    guard !prompts.isEmpty else { return 0 }
    let limit = Date().addingTimeInterval(-30 * 24 * 3600)
    let stale = prompts.filter { ($0.lastUsedAt ?? $0.createdAt ?? Date()) < limit }.count
    return Double(stale) / Double(prompts.count)
  }
}

// MARK: - Usage entry

/// One prompt's usage on one Mac.
struct UsageEntry {
  var count: Int
  var lastUsedAt: Date?
  /// The prompt's content version when these uses were recorded.
  var contentVersion: String

  init(count: Int, lastUsedAt: Date?, contentVersion: String) {
    self.count = count
    self.lastUsedAt = lastUsedAt
    self.contentVersion = contentVersion
  }

  init(dictionary dict: [String: Any]) {
    count = (dict["count"] as? NSNumber)?.intValue ?? 0
    lastUsedAt = (dict["lastUsedAt"] as? String).flatMap(PHDate.parse)
    contentVersion = dict["contentVersion"] as? String ?? ""
  }

  var dictionary: [String: Any] {
    [
      "count": count,
      "lastUsedAt": lastUsedAt.map(PHDate.format) ?? NSNull(),
      "contentVersion": contentVersion
    ]
  }
}

// MARK: - Default prompts

/// Prompts for a first run on a Mac with an empty library: Chinese when the app runs in Chinese, English otherwise.
enum PHDefaults {
  static var prompts: [PHPrompt] {
    Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? chinese : english
  }

  private static func item(
    _ trigger: String?, _ title: String, _ description: String, _ category: String, _ text: String
  ) -> PHPrompt {
    let now = Date()
    return PHPrompt(title: title, trigger: trigger, description: description, category: category, prompt: text,
                    createdAt: now, updatedAt: now)
  }

  // swiftlint:disable line_length
  private static var english: [PHPrompt] {
    [
      item(nil, "Fill in what I didn't think of", "Infer missing preconditions, hidden constraints and edge cases",
           "Deep thinking",
           "Don't just follow the requirements I wrote down. Start from my core goal, infer the preconditions, hidden constraints, edge cases and unstated needs I may have missed, fill them in, and only then give me a plan."),
      item(nil, "Raise it to a professional standard", "Turn a casual request into an expert's delivery standard",
           "Deep thinking",
           "Turn my casual, non-expert request into the standard workflow and deliverables a senior expert in this field would use. Point out the industry standards, acceptance criteria and common pitfalls that must be respected."),
      item(nil, "Find what I don't know I don't know", "Spot blind spots from a domain expert's view", "Deep thinking",
           "Don't only check the problems I've already thought of. As a senior expert in this field, list the factors I'm likely unaware of that would significantly affect the outcome. For each one, explain what it is, why it's easy to overlook, and what happens if it's ignored."),
      item(nil, "Scan for gaps before starting", "Check goal, constraints, dependencies and risks first", "Deep thinking",
           "Before starting, scan this task for gaps: 1. Is the goal clear and verifiable? 2. Constraints (time, budget, permissions, format). 3. Required inputs and resources. 4. Main risks and how to handle them. List anything missing and confirm it with me before you begin."),
      item(nil, "Reason from first principles", "Ignore convention and rebuild from basic facts", "Deep thinking",
           "Don't start from industry convention, competitors, or \"how people usually do it\". First break the problem down into its most basic, irreducible facts and constraints, then derive a solution from those facts and point out how it differs from the usual approach."),
      item(nil, "Find the real need behind the request", "Examine the real pain point, current workarounds and fake needs",
           "Product",
           "As a senior product expert, scrutinize my request. Don't propose a solution yet. Answer: 1. What is the user's real underlying pain point? 2. What clumsy workaround do users rely on today? 3. Could this be a fake need? If so, what is a lighter-weight solution?"),
      item(nil, "Close the loop on metrics", "Define a north star, guardrail metrics and an attribution path", "Product",
           "Build a rigorous system for monitoring and judging the success of my current plan: 1. A north-star metric (the real gain). 2. Guardrail metrics (experiences it might hurt). 3. An attribution path for drilling down."),
      item(nil, "Argue against me", "Find the weakest assumptions and rebut them one by one", "Product",
           "Act as a skeptical senior reviewer. Find the 3 weakest assumptions in my plan, give the strongest rebuttal and a counterexample for each, then tell me what evidence I need to make the plan hold."),
      item(nil, "Structured answer", "Lead with the conclusion", "Output format",
           "Answer with the conclusion first: one sentence with the conclusion, then the supporting reasons as a list, then the risks and next steps. Keep each point to two sentences or fewer.")
    ]
  }

  // swiftlint:enable line_length

  private static var chinese: [PHPrompt] {
    [
      item("/补全", "补全我没想到的要求", "推导遗漏的前置条件、隐性限制与边缘情况", "深度思考",
           "不要只按照我明确写出的要求执行。先根据我的核心目标，推导我可能遗漏的前置条件、隐性限制、边缘情况或潜在需求，帮我补全后再输出方案。"),
      item("/专业补全", "按专业人员标准补全需求", "把口语化要求转为资深专家的交付标准", "深度思考",
           "把我当前比较口语化、非专业化的要求，转化为该领域资深专家的标准工作流与交付规范。指出业内在做这件事时必须遵循的行业标准、验收指标与常见坑。"),
      item("/盲区", "找出我不知道自己不知道的", "从领域专家视角找出认知盲区", "深度思考",
           "不要只检查我已经想到的问题。请站在该领域资深专家的视角，列出我很可能没有意识到、但会显著影响结果的因素。每一项说明：它是什么、为什么容易被忽略、如果忽略会造成什么后果。"),
      item("/防遗漏", "执行前做一次遗漏扫描", "开始前按清单检查目标、约束、依赖与风险", "深度思考",
           "在正式执行之前，先对当前任务做一次遗漏扫描：1. 目标是否清晰、可验收；2. 约束条件（时间、预算、权限、格式）；3. 依赖的输入与资源；4. 主要风险与应对。列出缺失项并向我确认后，再开始执行。"),
      item("/第一性原理", "从第一性原理重新推导", "抛开惯例，从基本事实出发重建方案", "深度思考",
           "不要从行业惯例、竞品做法或“别人一般怎么做”出发。请先拆出这个问题最基本、不可再分的事实与约束，再从这些事实出发重新推导解决方案，并指出新方案与常规做法的差异。"),
      item("/伪需求", "挖掘伪需求与底层动机", "审视真实痛点、现有替代方案与伪需求嫌疑", "产品策划",
           "作为资深产品专家，请严厉审视我提出的需求。不要直接给方案，重点回答：1. 用户真正的底层痛点是什么？2. 用户现在用什么蹩脚方式解决？3. 这是否存在伪需求嫌疑？如果是，更轻量的解法是什么？"),
      item("/指标推导", "指标与归因逻辑闭环", "建立北极星指标、护栏指标与归因路径", "产品策划",
           "为我当前的方案建立一套严谨的指标监控与成败衡量体系：1. 北极星指标（真实增量）；2. 护栏指标（可能伤害的业务体验）；3. 归因下钻路径。"),
      item("/反方", "请扮演反方挑战我", "找出方案中最薄弱的假设并逐条反驳", "产品策划",
           "请扮演一位持怀疑态度的资深评审。找出我方案中最薄弱的 3 个假设，逐条给出最有力的反驳理由和反例，再说明我需要补充什么证据才能让方案成立。"),
      item("/结构化", "结构化输出", "按结论先行的结构整理回答", "输出格式",
           "请用结论先行的结构回答：先用一句话给出结论；再分点列出支撑理由；最后列出风险与下一步行动。每一点不超过两句话。")
    ]
  }
}
