import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - Global shortcuts

extension KeyboardShortcuts.Name {
  static let phOpenHUD = Self("phOpenHUD", default: .init(.slash, modifiers: [.control]))
  static let phCapture = Self("phCapture", default: .init(.slash, modifiers: [.control, .shift]))
}

// MARK: - Prompt model

struct PHPrompt: Identifiable {
  static let uncategorized = String(localized: "Uncategorized")

  var id: String
  var title: String
  var trigger: String?
  var description: String?
  var category: String?
  var prompt: String
  var sourceApp: String?
  var createdAt: Date?
  var updatedAt: Date?
  var usageCount: Int
  var lastUsedAt: Date?
  var pinned: Bool = false
  /// Changes whenever the text changes. Usage counts recorded for an older text do not count.
  var contentVersion: String = ""
  /// Unknown keys from the JSON file. They are written back unchanged.
  var extra: [String: Any] = [:]

  var categoryName: String {
    let value = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? PHPrompt.uncategorized : value
  }

  private static let knownKeys: Set<String> = [
    "id", "title", "trigger", "description", "category", "prompt",
    "sourceApp", "createdAt", "updatedAt", "usageCount", "lastUsedAt", "pinned", "contentVersion",
    "schemaVersion"
  ]

  init(
    id: String = UUID().uuidString,
    title: String,
    trigger: String? = nil,
    description: String? = nil,
    category: String? = nil,
    prompt: String,
    sourceApp: String? = nil,
    createdAt: Date? = Date(),
    updatedAt: Date? = Date(),
    usageCount: Int = 0,
    lastUsedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.trigger = trigger
    self.description = description
    self.category = category
    self.prompt = prompt
    self.sourceApp = sourceApp
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.usageCount = usageCount
    self.lastUsedAt = lastUsedAt
  }

  /// Returns nil when the dictionary has no usable `prompt` text.
  init?(dictionary dict: [String: Any]) {
    func string(_ key: String) -> String? {
      if let value = dict[key] as? String { return value }
      if let value = dict[key] as? NSNumber { return value.stringValue }
      return nil
    }

    guard let promptText = string("prompt"),
          !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    let titleText = string("title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.id = string("id").flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
    self.title = titleText.isEmpty ? PHPrompt.defaultTitle(for: promptText) : titleText
    self.trigger = string("trigger")
    self.description = string("description")
    self.category = string("category")
    self.prompt = promptText
    self.sourceApp = string("sourceApp")
    self.createdAt = string("createdAt").flatMap(PHDate.parse)
    self.updatedAt = string("updatedAt").flatMap(PHDate.parse)
    self.usageCount = (dict["usageCount"] as? NSNumber)?.intValue ?? 0
    self.lastUsedAt = string("lastUsedAt").flatMap(PHDate.parse)
    self.pinned = (dict["pinned"] as? NSNumber)?.boolValue ?? false
    self.contentVersion = string("contentVersion") ?? ""
    self.extra = dict.filter { !PHPrompt.knownKeys.contains($0.key) }
  }

  var dictionary: [String: Any] {
    var dict = extra
    dict["id"] = id
    dict["title"] = title
    dict["prompt"] = prompt
    dict["usageCount"] = usageCount
    dict["trigger"] = trigger ?? NSNull()
    dict["description"] = description ?? NSNull()
    dict["category"] = category ?? NSNull()
    dict["sourceApp"] = sourceApp ?? NSNull()
    dict["createdAt"] = createdAt.map(PHDate.format) ?? NSNull()
    dict["updatedAt"] = updatedAt.map(PHDate.format) ?? NSNull()
    dict["lastUsedAt"] = lastUsedAt.map(PHDate.format) ?? NSNull()
    dict["pinned"] = pinned
    dict["contentVersion"] = contentVersion
    return dict
  }

  /// One prompt file in the synced library. Usage counts live in the per-Mac usage files instead.
  var fileDictionary: [String: Any] {
    var dict = dictionary
    dict.removeValue(forKey: "usageCount")
    dict.removeValue(forKey: "lastUsedAt")
    dict["schemaVersion"] = PHCodec.promptFileVersion
    return dict
  }

  static func defaultTitle(for text: String) -> String {
    let firstLine = text
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return String(firstLine.prefix(16))
  }
}

enum PHDate {
  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func parse(_ value: String) -> Date? {
    formatter.date(from: value) ?? fractionalFormatter.date(from: value)
  }

  static func format(_ date: Date) -> String {
    formatter.string(from: date)
  }
}

// MARK: - File format

struct PHFileError: Error {
  let message: String
}

enum PHCodec {
  static let schemaVersion = 1
  static let promptFileVersion = 2

  /// Reads both the v0.2 object format and the v0.1 plain array format.
  /// Returns the prompts and whether the file must be rewritten (old format or generated ids).
  static func decode(_ data: Data) throws -> (prompts: [PHPrompt], needsRewrite: Bool) {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      let nsError = error as NSError
      let detail = (nsError.userInfo["NSDebugDescription"] as? String) ?? nsError.localizedDescription
      throw PHFileError(message: String(localized: "Invalid JSON: \(detail)"))
    }

    var needsRewrite = false
    let items: [Any]
    if let array = object as? [Any] {
      items = array
      needsRewrite = true
    } else if let root = object as? [String: Any], let array = root["prompts"] as? [Any] {
      items = array
    } else {
      throw PHFileError(message: String(localized: "Invalid file: the \"prompts\" array is missing"))
    }

    var prompts: [PHPrompt] = []
    for (index, item) in items.enumerated() {
      guard let dict = item as? [String: Any], let prompt = PHPrompt(dictionary: dict) else {
        throw PHFileError(message: String(localized: "Prompt \(index + 1) has no \"prompt\" text"))
      }
      if (dict["id"] as? String)?.isEmpty ?? true { needsRewrite = true }
      prompts.append(prompt)
    }
    return (prompts, needsRewrite)
  }

  /// Single-file format of 1.2 and earlier. Still used for backups.
  static func encode(_ prompts: [PHPrompt]) throws -> Data {
    let root: [String: Any] = [
      "schemaVersion": schemaVersion,
      "prompts": prompts.map(\.dictionary)
    ]
    return try json(root)
  }

  static func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}

// MARK: - Helpers

extension String {
  var phSingleLine: String {
    split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  var phTrimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
