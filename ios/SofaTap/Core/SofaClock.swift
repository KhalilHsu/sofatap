import Foundation

/// Sleep that stays on the iOS 15 `Task.sleep(nanoseconds:)` API.
enum SofaClock {
    static func sleep(seconds: Double) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        let nanos = seconds * 1_000_000_000
        guard nanos < Double(UInt64.max) else {
            try await Task.sleep(nanoseconds: UInt64.max)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(nanos.rounded()))
    }
}
