import CoreGraphics
import Foundation
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Simple Unzip"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for info in list {
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains(filter) else { continue }
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let number = info[kCGWindowNumber as String] as? Int ?? -1
    let width = bounds["Width"] as? Double ?? 0
    if width > 800 { print("\(number)") }
}
