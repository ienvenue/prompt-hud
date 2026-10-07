import AppKit

/// Local usage log for the weekly summary. JSON Lines, never uploaded.
/// File: ~/Library/Application Support/PromptHUD/usage.log
enum PHUsage {
  enum Event: String {
    case hudOpen = "hud_open"
    case insert
    case copy
    case noResultClose = "no_result_close"
    case captureSaved = "capture_saved"
    case captureCancel = "capture_cancel"
    case edit
    case replace
    case delete
    case pin
  }

  private static let queue = DispatchQueue(label: "PromptHUD.usage")
  private static let maxBytes = 5 * 1024 * 1024

  static var fileURL: URL { PHStore.shared.directoryURL.appendingPathComponent("usage.log") }
  private static var archiveURL: URL { PHStore.shared.directoryURL.appendingPathComponent("usage.1.log") }

  static func log(_ event: Event, _ fields: [String: Any] = [:]) {
    var record = fields
    record["event"] = event.rawValue
    record["ts"] = PHDate.format(Date())
    guard JSONSerialization.isValidJSONObject(record),
          let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
      return
    }
    let url = fileURL
    let archive = archiveURL
    queue.async {
      let fileManager = FileManager.default
      if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
        try? fileManager.removeItem(at: archive)
        try? fileManager.moveItem(at: url, to: archive)
      }
      if !fileManager.fileExists(atPath: url.path) {
        fileManager.createFile(atPath: url.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data + Data("\n".utf8))
    }
  }

  // MARK: - Weekly summary

  struct Summary {
    var opens = 0
    var inserts = 0
    var captures = 0
    var noResultCloses = 0
    var medianInsertMs: Int?
    var anchorCaret = 0
    var anchorField = 0
    var anchorMouse = 0
  }

  static func summary(days: Int = 7) -> Summary {
    var result = Summary()
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return result }
    let since = Date().addingTimeInterval(-Double(days) * 24 * 3600)
    var durations: [Int] = []

    for line in text.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
            let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let event = record["event"] as? String,
            let stamp = (record["ts"] as? String).flatMap(PHDate.parse),
            stamp >= since else {
        continue
      }
      switch Event(rawValue: event) {
      case .hudOpen:
        result.opens += 1
        switch record["anchor"] as? String {
        case "caret": result.anchorCaret += 1
        case "field": result.anchorField += 1
        default: result.anchorMouse += 1
        }
      case .insert:
        result.inserts += 1
        if let milliseconds = (record["ms"] as? NSNumber)?.intValue { durations.append(milliseconds) }
      case .captureSaved:
        result.captures += 1
      case .noResultClose:
        result.noResultCloses += 1
      default:
        break
      }
    }

    if !durations.isEmpty {
      let sorted = durations.sorted()
      result.medianInsertMs = sorted[sorted.count / 2]
    }
    return result
  }

  static func showSummary() {
    let summary = summary()
    let store = PHStore.shared
    func percent(_ part: Int, _ whole: Int) -> String {
      whole == 0 ? "—" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }
    let median = summary.medianInsertMs.map { String(format: String(localized: "%.1f s"), Double($0) / 1000) } ?? "—"
    let northStar = summary.inserts >= 20 ? String(localized: "✅ Goal met") : String(localized: "Below goal (≥ 20)")
    let captureGoal = summary.captures >= 5 ? String(localized: "✅ Goal met") : String(localized: "Below goal (≥ 5)")

    let lines = [
      String(localized: "Inserted: \(summary.inserts)　\(northStar)"),
      String(localized: "Captured: \(summary.captures)　\(captureGoal)"),
      String(localized: "Open → insert (median): \(median)　goal ≤ 3 s"),
      String(localized: "Closed after a search with no results: \(percent(summary.noResultCloses, summary.opens))　goal ≤ 10%"),
      String(localized: "Opened at the text cursor: \(percent(summary.anchorCaret, summary.opens)) (input field \(summary.anchorField), mouse \(summary.anchorMouse))"),
      "",
      String(localized: "Prompts: \(store.prompts.count)　unused for 30 days: \(Int((store.staleShare * 100).rounded()))% (goal ≤ 50%)")
    ]

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "Usage in the Last 7 Days")
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Open Log File"))
    if alert.runModal() == .alertSecondButtonReturn {
      NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
  }
}
