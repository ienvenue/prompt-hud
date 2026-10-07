// Data-rule checks for PHStore. Run with scripts/test.sh, which points the store at a temporary folder.
// swiftlint:disable force_cast force_try identifier_name line_length
import Foundation

enum PHPreferences {
  static let familiarThresholdKey = "phFamiliarThreshold"
  static var familiarThreshold: Int { 100 }
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print(condition ? "PASS" : "FAIL", message)
  if !condition { failures += 1 }
}

let s = PHStore.shared
let n = s.prompts.count
guard case .added(let a) = s.add(title: "测试", category: "新分类", pinned: false, content: "测试正文 abc", sourceApp: nil) else { fatalError() }
check(s.prompts.count == n + 1, "add")
check(s.categories.last == "新分类" || s.categories.dropLast().last == "新分类", "new category after known ones: \(s.categories)")
if case .duplicate = s.add(title: "x", category: "", pinned: false, content: "测试正文 abc", sourceApp: nil) { check(true, "duplicate text is blocked") } else { check(false, "duplicate text is blocked") }
s.recordUsage(id: a.id); s.recordUsage(id: a.id)
check(s.prompts.first { $0.id == a.id }?.usageCount == 2, "two inserts count as 2")
_ = s.update(id: a.id, title: "改标题", category: "新分类", pinned: true, content: "测试正文 abc")
check(s.prompts.first { $0.id == a.id }?.usageCount == 2, "title edit keeps usage")
check(s.prompts.first { $0.id == a.id }?.pinned == true, "pin is saved")
_ = s.update(id: a.id, title: "改标题", category: "新分类", pinned: true, content: "新正文")
check(s.prompts.first { $0.id == a.id }?.usageCount == 0, "text edit resets usage")
check(s.delete(id: a.id) && s.prompts.count == n, "delete")
s.load(); check(s.prompts.count == n, "reload keeps the count")
let settings = s.libraryURL.appendingPathComponent("settings.json")
var d = try! JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
d["familiarThreshold"] = 7
try! JSONSerialization.data(withJSONObject: d).write(to: settings)
s.load(); check(UserDefaults.standard.integer(forKey: "phFamiliarThreshold") == 7, "threshold from another Mac is applied")
s.saveFamiliarThreshold(9)
d = try! JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
check((d["familiarThreshold"] as? Int) == 9 && (d["categoryOrder"] as? [String])?.isEmpty == false, "local threshold is saved, category order kept")

print(failures == 0 ? "All tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
