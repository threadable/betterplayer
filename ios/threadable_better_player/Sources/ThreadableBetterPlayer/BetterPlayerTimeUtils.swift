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
        return millis(from: CMTimeGetSeconds(time))
    }

    static func millis(from interval: TimeInterval) -> Int64 {
        if interval.isNaN || interval.isInfinite {
            return 0
        }
        let milliseconds = interval * 1000.0
        if milliseconds >= Double(Int64.max) {
            return Int64.max
        }
        if milliseconds <= Double(Int64.min) {
            return Int64.min
        }
        return Int64(milliseconds)
    }
}
