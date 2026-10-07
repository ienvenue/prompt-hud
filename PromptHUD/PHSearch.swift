import Foundation
import SwiftUI

/// Search over title, category, description and text. Plain text matching, no pinyin.
enum PHSearch {
  static func search(_ rawQuery: String, in prompts: [PHPrompt]) -> [PHPrompt] {
    let query = rawQuery.phTrimmed.lowercased()

    let indexed = Array(prompts.enumerated())
    guard !query.isEmpty else {
      // Recently used first, then the order in the file.
      return indexed.sorted { lhs, rhs in
        if lhs.element.pinned != rhs.element.pinned { return lhs.element.pinned }
        switch (lhs.element.lastUsedAt, rhs.element.lastUsedAt) {
        case let (left?, right?) where left != right:
          return left > right
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        default:
          return lhs.offset < rhs.offset
        }
      }.map(\.element)
    }

    var scored: [(prompt: PHPrompt, score: Double, offset: Int)] = []
    for (offset, prompt) in indexed {
      let value = relevance(prompt, query: query)
      if value > 0 {
        scored.append((prompt, value, offset))
      }
    }

    return scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.prompt.pinned != rhs.prompt.pinned { return lhs.prompt.pinned }
      let leftDate = lhs.prompt.lastUsedAt ?? .distantPast
      let rightDate = rhs.prompt.lastUsedAt ?? .distantPast
      if leftDate != rightDate { return leftDate > rightDate }
      return lhs.offset < rhs.offset
    }.map(\.prompt)
  }

  private static func relevance(_ prompt: PHPrompt, query: String) -> Double {
    var best = 0.0
    best = max(best, 4.0 * match(query, in: prompt.title, allowSubsequence: true))

    best = max(best, 2.0 * match(query, in: prompt.categoryName, allowSubsequence: false))
    best = max(best, 1.5 * match(query, in: prompt.description ?? "", allowSubsequence: false))
    best = max(best, 1.0 * match(query, in: prompt.prompt, allowSubsequence: false))
    return best
  }

  /// 1.0 prefix, 0.8 substring, 0.1–0.5 ordered subsequence, 0 no match.
  private static func match(_ query: String, in text: String, allowSubsequence: Bool) -> Double {
    guard !query.isEmpty, !text.isEmpty else { return 0 }
    let target = text.lowercased()
    if target.hasPrefix(query) { return 1.0 }
    if target.contains(query) { return 0.8 }
    guard allowSubsequence else { return 0 }

    var searchStart = target.startIndex
    var previous: String.Index?
    var gaps = 0
    for character in query {
      guard let found = target[searchStart...].firstIndex(of: character) else { return 0 }
      if let previous, target.index(after: previous) != found { gaps += 1 }
      previous = found
      searchStart = target.index(after: found)
    }
    return max(0.1, 0.5 - Double(gaps) * 0.05)
  }

  // MARK: Similar content

  /// Prompts whose text is most similar to `text` (character-bigram Jaccard ≥ threshold), best first.
  static func similar(to text: String, in prompts: [PHPrompt], limit: Int = 3, threshold: Double = 0.3) -> [PHPrompt] {
    let source = bigrams(text)
    guard !source.isEmpty else { return [] }
    let scored = prompts.compactMap { prompt -> (PHPrompt, Double)? in
      let other = bigrams(prompt.prompt)
      guard !other.isEmpty else { return nil }
      let score = Double(source.intersection(other).count) / Double(source.union(other).count)
      return score >= threshold ? (prompt, score) : nil
    }
    return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
  }

  private static func bigrams(_ text: String) -> Set<String> {
    let characters = Array(text.lowercased().filter { !$0.isWhitespace })
    guard characters.count >= 2 else { return [] }
    var result = Set<String>()
    for index in 0..<(characters.count - 1) {
      result.insert(String(characters[index...index + 1]))
    }
    return result
  }

  /// Title with the query range in bold, for list display.
  static func highlighted(_ title: String, query: String) -> AttributedString {
    var attributed = AttributedString(title)
    let trimmed = query.phTrimmed
    guard !trimmed.isEmpty,
          let range = title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]),
          let lower = AttributedString.Index(range.lowerBound, within: attributed),
          let upper = AttributedString.Index(range.upperBound, within: attributed) else {
      return attributed
    }
    attributed[lower..<upper].foregroundColor = PHTheme.accent
    return attributed
  }
}
