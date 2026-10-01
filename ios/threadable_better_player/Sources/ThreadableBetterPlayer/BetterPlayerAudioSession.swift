import AVFoundation
import Foundation

enum BetterPlayerAudioSession {
    private static let queue = DispatchQueue(
        label: "io.threadable.betterplayer.audio-session",
        qos: .userInitiated
    )

    static func activate() {
        perform { session in
            try? session.setActive(true)
        }
    }

    static func deactivate(notifyOthers: Bool = false) {
        perform { session in
            if notifyOthers {
                try? session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            } else {
                try? session.setActive(false, options: [])
            }
        }
    }

    private static func perform(
        _ operation: @escaping @Sendable (AVAudioSession) -> Void
    ) {
        queue.async {
            operation(AVAudioSession.sharedInstance())
        }
    }
}
