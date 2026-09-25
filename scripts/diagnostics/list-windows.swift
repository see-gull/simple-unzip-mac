import CoreGraphics
import Foundation

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Simple Unzip"
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var found = false
for info in list {
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains(filter) else { continue }
    found = true
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
    let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    let name = info[kCGWindowName as String] as? String ?? "<no-title>"
    print("owner=\(owner) name=\(name) layer=\(layer) alpha=\(alpha) onscreen=\(onScreen) bounds=\(bounds)")
}
if !found { print("没有找到该应用的任何窗口") }
