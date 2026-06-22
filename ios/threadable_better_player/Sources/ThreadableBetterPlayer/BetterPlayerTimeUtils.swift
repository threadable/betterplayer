import AVFoundation
import Foundation

enum BetterPlayerTimeUtils {
    static func isFinite(_ time: CMTime) -> Bool {
        time.timescale != 0 &&
            time.flags.contains(.valid) &&
            !time.flags.contains(.indefinite)
    }

    static func millis(from time: CMTime) -> Int64 {
        if !isFinite(time) {
            return 0
        }
        return time.value * 1000 / Int64(time.timescale)
    }

    static func millis(from interval: TimeInterval) -> Int64 {
        if interval.isNaN || interval.isInfinite {
            return 0
        }
        return Int64(interval * 1000.0)
    }
}
