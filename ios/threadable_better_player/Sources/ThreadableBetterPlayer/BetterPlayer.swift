import AVFoundation
import AVKit
import Flutter
import UIKit

private var timeRangeContext = 0
private var statusContext = 0
private var playbackLikelyToKeepUpContext = 0
private var playbackBufferEmptyContext = 0
private var playbackBufferFullContext = 0
private var presentationSizeContext = 0

private func radiansToDegrees(_ radians: CGFloat) -> CGFloat {
    let degrees = radians * 180.0 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

private func betterPlayerRootViewController() -> UIViewController? {
    for scene in UIApplication.shared.connectedScenes {
        guard scene.activationState == .foregroundActive,
              let windowScene = scene as? UIWindowScene else {
            continue
        }
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return keyWindow.rootViewController
        }
        return windowScene.windows.first?.rootViewController
    }
    return nil
}

final class BetterPlayer: NSObject, FlutterPlatformView, FlutterStreamHandler, AVPictureInPictureControllerDelegate {
    private struct PlaybackSnapshot {
        let position: Int64
        let absolutePosition: Int64
        let duration: Int64
        let durationIsFinite: Bool
    }

    let player = AVPlayer()

    private var loaderDelegate: BetterPlayerEzDrmAssetsLoaderDelegate?
    var eventChannel: FlutterEventChannel?
    var eventSink: FlutterEventSink?
    private var preferredTransform = CGAffineTransform.identity
    private(set) var disposed = false
    private(set) var isPlaying = false
    var isLooping = false
    private var isInitialized = false
    private var key: String?
    private var failedCount = 0
    private var playerLayer: AVPlayerLayer?
    private var pictureInPicture = false
    private var observersAdded = false
    private var stalledCount = 0
    private var isStalledCheckStarted = false
    private var playerRate: Float = 1
    private var overriddenDuration = 0
    private var lastAvPlayerTimeControlStatus: AVPlayer.TimeControlStatus?
    private var pipController: AVPictureInPictureController?
    private weak var observedItem: AVPlayerItem?
    private var sourceGeneration: UInt64 = 0
    private var pipGeneration: UInt64 = 0
    private var readyMetadataGeneration: UInt64?
    private var snapshotRequestInFlight = false
    private var snapshotCompletions: [(PlaybackSnapshot) -> Void] = []
    // MediaToolbox property reads can synchronously wait, so isolate them from main.
    private let mediaPropertyQueue = DispatchQueue(
        label: "io.threadable.betterplayer.media-property",
        qos: .userInitiated
    )

    override init() {
        super.init()
        player.actionAtItemEnd = .none
        if #available(iOS 10.0, *) {
            player.automaticallyWaitsToMinimizeStalling = false
        }
    }

    func view() -> UIView {
        let playerView = BetterPlayerView(frame: .zero)
        playerView.player = player
        return playerView
    }

    func addObservers(_ item: AVPlayerItem) {
        guard !observersAdded else {
            return
        }
        player.addObserver(self, forKeyPath: "rate", options: [], context: nil)
        item.addObserver(self, forKeyPath: "loadedTimeRanges", options: [], context: &timeRangeContext)
        item.addObserver(self, forKeyPath: "status", options: [], context: &statusContext)
        item.addObserver(self, forKeyPath: "presentationSize", options: [], context: &presentationSizeContext)
        item.addObserver(
            self,
            forKeyPath: "playbackLikelyToKeepUp",
            options: [],
            context: &playbackLikelyToKeepUpContext
        )
        item.addObserver(
            self,
            forKeyPath: "playbackBufferEmpty",
            options: [],
            context: &playbackBufferEmptyContext
        )
        item.addObserver(
            self,
            forKeyPath: "playbackBufferFull",
            options: [],
            context: &playbackBufferFullContext
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEndTime(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        observedItem = item
        observersAdded = true
    }

    func clear() {
        sourceGeneration &+= 1
        pipGeneration &+= 1
        readyMetadataGeneration = nil
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(startStalledCheck),
            object: nil
        )
        isInitialized = false
        isPlaying = false
        disposed = false
        failedCount = 0
        key = nil
        loaderDelegate = nil
        removeObservers()
        player.currentItem?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
    }

    private func removeObservers() {
        guard observersAdded, let item = observedItem else {
            return
        }
        player.removeObserver(self, forKeyPath: "rate", context: nil)
        item.removeObserver(self, forKeyPath: "status", context: &statusContext)
        item.removeObserver(self, forKeyPath: "presentationSize", context: &presentationSizeContext)
        item.removeObserver(self, forKeyPath: "loadedTimeRanges", context: &timeRangeContext)
        item.removeObserver(
            self,
            forKeyPath: "playbackLikelyToKeepUp",
            context: &playbackLikelyToKeepUpContext
        )
        item.removeObserver(
            self,
            forKeyPath: "playbackBufferEmpty",
            context: &playbackBufferEmptyContext
        )
        item.removeObserver(
            self,
            forKeyPath: "playbackBufferFull",
            context: &playbackBufferFullContext
        )
        NotificationCenter.default.removeObserver(self)
        observedItem = nil
        observersAdded = false
    }

    private func isCurrent(item: AVPlayerItem, generation: UInt64) -> Bool {
        Thread.isMainThread
            && sourceGeneration == generation
            && observedItem === item
            && !disposed
    }

    @objc private func itemDidPlayToEndTime(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.itemDidPlayToEndTime(notification)
            }
            return
        }
        guard let item = notification.object as? AVPlayerItem, item === player.currentItem else {
            return
        }
        if isLooping {
            item.seek(to: .zero, completionHandler: nil)
            return
        }
        if let eventSink {
            eventSink(["event": "completed", "key": key as Any])
            removeObservers()
        }
    }

    private func getVideoComposition(
        transform: CGAffineTransform,
        videoTrack: AVAssetTrack,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        var width = videoTrack.naturalSize.width
        var height = videoTrack.naturalSize.height
        let rotationDegrees = Int(round(radiansToDegrees(atan2(transform.b, transform.a))))
        if rotationDegrees == 90 || rotationDegrees == 270 {
            width = videoTrack.naturalSize.height
            height = videoTrack.naturalSize.width
        }
        videoComposition.renderSize = CGSize(width: width, height: height)

        let fps = videoTrack.nominalFrameRate > 0
            ? Int(ceil(videoTrack.nominalFrameRate))
            : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return videoComposition
    }

    private func fixTransform(_ videoTrack: AVAssetTrack) -> CGAffineTransform {
        var transform = videoTrack.preferredTransform
        let rotationDegrees = Int(round(radiansToDegrees(atan2(transform.b, transform.a))))
        if rotationDegrees == 90 {
            transform.tx = videoTrack.naturalSize.height
            transform.ty = 0
        } else if rotationDegrees == 180 {
            transform.tx = videoTrack.naturalSize.width
            transform.ty = videoTrack.naturalSize.height
        } else if rotationDegrees == 270 {
            transform.tx = 0
            transform.ty = videoTrack.naturalSize.width
        }
        return transform
    }

    func setDataSourceAsset(
        _ asset: String,
        key: String?,
        certificateUrl: String?,
        licenseUrl: String?,
        cacheKey: String?,
        cacheManager: CacheManager,
        overriddenDuration: Int,
        completion: @escaping () -> Void
    ) {
        let path = Bundle.main.path(forResource: asset, ofType: nil) ?? asset
        setDataSourceURL(
            URL(fileURLWithPath: path),
            key: key,
            certificateUrl: certificateUrl,
            licenseUrl: licenseUrl,
            headers: [:],
            useCache: false,
            cacheKey: cacheKey,
            cacheManager: cacheManager,
            overriddenDuration: overriddenDuration,
            videoExtension: nil,
            completion: completion
        )
    }

    func setDataSourceURL(
        _ url: URL,
        key: String?,
        certificateUrl: String?,
        licenseUrl: String?,
        headers: [AnyHashable: Any],
        useCache: Bool,
        cacheKey: String?,
        cacheManager: CacheManager,
        overriddenDuration: Int,
        videoExtension: String?,
        completion: @escaping () -> Void
    ) {
        self.overriddenDuration = 0
        let requestGeneration = sourceGeneration

        func setItem(_ item: AVPlayerItem) {
            guard sourceGeneration == requestGeneration, !disposed else {
                completion()
                return
            }
            if #available(iOS 10.0, *), overriddenDuration > 0 {
                self.overriddenDuration = overriddenDuration
            }
            setDataSourcePlayerItem(item, key: key)
            completion()
        }

        guard useCache else {
            let asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
            if let certificateUrl,
               !certificateUrl.isEmpty,
               let certificateURL = URL(string: certificateUrl) {
                let queue = DispatchQueue(label: "streamQueue", qos: .default)
                loaderDelegate = BetterPlayerEzDrmAssetsLoaderDelegate(
                    certificateURL: certificateURL,
                    licenseURL: licenseUrl.flatMap(URL.init(string:)),
                    callbackQueue: queue
                )
                asset.resourceLoader.setDelegate(loaderDelegate, queue: queue)
            }
            setItem(AVPlayerItem(asset: asset))
            return
        }

        cacheManager.getCachingPlayerItemForNormalPlayback(
            url,
            cacheKey: cacheKey,
            videoExtension: videoExtension,
            headers: headers
        ) { item in
            if let item {
                setItem(item)
            } else {
                let asset = AVURLAsset(
                    url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
                )
                setItem(AVPlayerItem(asset: asset))
            }
        }
    }

    private func setDataSourcePlayerItem(_ item: AVPlayerItem, key: String?) {
        sourceGeneration &+= 1
        let generation = sourceGeneration
        readyMetadataGeneration = nil
        self.key = key
        stalledCount = 0
        isStalledCheckStarted = false
        playerRate = 1
        player.replaceCurrentItem(with: item)

        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item] in
            guard let item,
                  asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                  let videoTrack = asset.tracks(withMediaType: .video).first else {
                return
            }
            videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"]) { [weak self, weak item] in
                guard let item,
                      videoTrack.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded else {
                    return
                }
                let transform = self?.fixTransform(videoTrack) ?? .identity
                let composition = self?.getVideoComposition(
                    transform: transform,
                    videoTrack: videoTrack,
                    duration: asset.duration
                )
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.isCurrent(item: item, generation: generation),
                          let composition else {
                        return
                    }
                    self.preferredTransform = transform
                    item.videoComposition = composition
                }
            }
        }
        addObservers(item)
    }

    private func handleStalled() {
        guard !isStalledCheckStarted else {
            return
        }
        isStalledCheckStarted = true
        startStalledCheck()
    }

    @objc private func startStalledCheck() {
        guard player.currentItem != nil else {
            return
        }
        let generation = sourceGeneration
        mediaPropertyQueue.async { [weak self] in
            guard let self, let item = self.player.currentItem else {
                return
            }
            let currentTime = item.currentTime()
            let isLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
            let availableDuration = item.loadedTimeRanges.first.map {
                let range = $0.timeRangeValue
                return CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
            } ?? 0
            let hasBuffer = availableDuration - CMTimeGetSeconds(currentTime) > 10.0
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self,
                      let item,
                      self.isCurrent(item: item, generation: generation) else {
                    return
                }
                if isLikelyToKeepUp || hasBuffer {
                    self.play()
                    return
                }

                self.stalledCount += 1
                if self.stalledCount > 60 {
                    self.eventSink?(
                        FlutterError(
                            code: "VideoError",
                            message: "Failed to load video: playback stalled",
                            details: nil
                        )
                    )
                    return
                }

                self.perform(#selector(self.startStalledCheck), with: nil, afterDelay: 1)
            }
        }
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.observeValue(
                    forKeyPath: path,
                    of: object,
                    change: change,
                    context: context
                )
            }
            return
        }

        if path == "rate" {
            observeRate()
            return
        }

        if let item = object as? AVPlayerItem, item !== observedItem {
            return
        }

        if context == &timeRangeContext {
            observeLoadedTimeRanges(object)
        } else if context == &presentationSizeContext {
            onReadyToPlay()
        } else if context == &statusContext {
            observeStatus(object)
        } else if context == &playbackLikelyToKeepUpContext {
            guard let item = observedItem else {
                return
            }
            let generation = sourceGeneration
            mediaPropertyQueue.async { [weak self, weak item] in
                guard let self, item?.isPlaybackLikelyToKeepUp == true else {
                    return
                }
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.isCurrent(item: item, generation: generation) else {
                        return
                    }
                    self.updatePlayingState()
                    self.eventSink?(["event": "bufferingEnd", "key": self.key as Any])
                }
            }
        } else if context == &playbackBufferEmptyContext {
            eventSink?(["event": "bufferingStart", "key": key as Any])
        } else if context == &playbackBufferFullContext {
            eventSink?(["event": "bufferingEnd", "key": key as Any])
        }
    }

    private func observeRate() {
        guard let item = observedItem else {
            return
        }
        let generation = sourceGeneration
        let isPictureInPictureActive: Bool
        if #available(iOS 10.0, *) {
            isPictureInPictureActive = pipController?.isPictureInPictureActive == true
        } else {
            isPictureInPictureActive = false
        }

        mediaPropertyQueue.async { [weak self, weak item] in
            guard let self, let item else {
                return
            }
            let rate = self.player.rate
            let timeControlStatus = self.player.timeControlStatus
            let snapshot = PlaybackSnapshot(
                position: BetterPlayerTimeUtils.millis(from: item.currentTime()),
                absolutePosition: BetterPlayerTimeUtils.millis(
                    from: item.currentDate()?.timeIntervalSince1970 ?? 0
                ),
                duration: self.duration(for: item),
                durationIsFinite: BetterPlayerTimeUtils.isFinite(item.duration)
            )
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self,
                      let item,
                      self.sourceGeneration == generation,
                      self.observedItem === item,
                      !self.disposed else {
                    return
                }
                self.handleRateObservation(
                    rate: rate,
                    timeControlStatus: timeControlStatus,
                    isPictureInPictureActive: isPictureInPictureActive,
                    snapshot: snapshot
                )
            }
        }
    }

    private func handleRateObservation(
        rate: Float,
        timeControlStatus: AVPlayer.TimeControlStatus,
        isPictureInPictureActive: Bool,
        snapshot: PlaybackSnapshot
    ) {
        if isPictureInPictureActive {
            if lastAvPlayerTimeControlStatus == timeControlStatus {
                return
            }
            if timeControlStatus == .paused {
                lastAvPlayerTimeControlStatus = timeControlStatus
                eventSink?(["event": "pause"])
                return
            }
            if timeControlStatus == .playing {
                lastAvPlayerTimeControlStatus = timeControlStatus
                eventSink?(["event": "play"])
            }
        }

        guard rate == 0, isPlaying, snapshot.position > 0 else {
            return
        }
        guard !snapshot.durationIsFinite || snapshot.position < snapshot.duration else {
            return
        }
        handleStalled()
    }

    private func observeLoadedTimeRanges(_ object: Any?) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        let generation = sourceGeneration
        mediaPropertyQueue.async { [weak self, weak item] in
            guard let self, let item else {
                return
            }
            var values: [[NSNumber]] = []
            for rangeValue in item.loadedTimeRanges {
                let range = rangeValue.timeRangeValue
                let start = BetterPlayerTimeUtils.millis(from: range.start)
                var end = start + BetterPlayerTimeUtils.millis(from: range.duration)
                if BetterPlayerTimeUtils.isFinite(item.forwardPlaybackEndTime) {
                    let endTime = BetterPlayerTimeUtils.millis(from: item.forwardPlaybackEndTime)
                    if end > endTime {
                        end = endTime
                    }
                }
                values.append([NSNumber(value: start), NSNumber(value: end)])
            }
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self,
                      let item,
                      self.isCurrent(item: item, generation: generation) else {
                    return
                }
                self.eventSink?(["event": "bufferingUpdate", "values": values, "key": self.key as Any])
            }
        }
    }

    private func observeStatus(_ object: Any?) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        let generation = sourceGeneration
        mediaPropertyQueue.async { [weak self, weak item] in
            guard let self, let item else {
                return
            }
            let status = item.status
            let errorDescription = item.error?.localizedDescription ?? ""
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self,
                      let item,
                      self.isCurrent(item: item, generation: generation) else {
                    return
                }
                switch status {
                case .failed:
                    NSLog("Failed to load video:")
                    NSLog(errorDescription)
                    self.eventSink?(
                        FlutterError(
                            code: "VideoError",
                            message: "Failed to load video: \(errorDescription)",
                            details: nil
                        )
                    )
                case .unknown:
                    break
                case .readyToPlay:
                    self.onReadyToPlay()
                @unknown default:
                    break
                }
            }
        }
    }

    func updatePlayingState() {
        guard isInitialized, key != nil else {
            return
        }
        if !observersAdded, let currentItem = player.currentItem {
            addObservers(currentItem)
        }

        if isPlaying {
            if #available(iOS 10.0, *) {
                player.playImmediately(atRate: 1.0)
                player.rate = playerRate
            } else {
                player.play()
                player.rate = playerRate
            }
        } else {
            player.pause()
        }
    }

    private func onReadyToPlay() {
        guard !isInitialized,
              key != nil,
              let currentItem = observedItem else {
            return
        }
        let generation = sourceGeneration
        guard readyMetadataGeneration != generation else {
            return
        }
        readyMetadataGeneration = generation
        let asset = currentItem.asset
        mediaPropertyQueue.async { [weak self, weak currentItem] in
            guard let self,
                  let currentItem,
                  self.player.status == .readyToPlay else {
                DispatchQueue.main.async { [weak self, weak currentItem] in
                    guard let self,
                          let currentItem,
                          self.isCurrent(item: currentItem, generation: generation) else {
                        return
                    }
                    self.readyMetadataGeneration = nil
                }
                return
            }
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self, weak currentItem] in
                guard let currentItem,
                      asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                      asset.statusOfValue(forKey: "duration", error: nil) == .loaded else {
                    DispatchQueue.main.async { [weak self, weak currentItem] in
                        guard let self,
                              let currentItem,
                              self.isCurrent(item: currentItem, generation: generation) else {
                            return
                        }
                        self.readyMetadataGeneration = nil
                    }
                    return
                }

                let size = currentItem.presentationSize
                let width = size.width
                let height = size.height
                let videoTrack = asset.tracks(withMediaType: .video).first
                let isLive = currentItem.duration.isIndefinite
                let assetDuration = BetterPlayerTimeUtils.millis(from: asset.duration)
                let duration = BetterPlayerTimeUtils.millis(
                    from: BetterPlayerTimeUtils.isFinite(currentItem.forwardPlaybackEndTime)
                        ? currentItem.forwardPlaybackEndTime
                        : currentItem.duration
                )
                let realSize = videoTrack.map {
                    $0.naturalSize.applying($0.preferredTransform)
                } ?? size

                DispatchQueue.main.async { [weak self, weak currentItem] in
                    guard let self,
                          let currentItem,
                          self.isCurrent(item: currentItem, generation: generation),
                          !self.isInitialized else {
                        return
                    }
                    if videoTrack != nil, height == 0, width == 0 {
                        self.readyMetadataGeneration = nil
                        return
                    }
                    if !isLive && duration == 0 {
                        self.readyMetadataGeneration = nil
                        return
                    }
                    guard let eventSink = self.eventSink else {
                        self.readyMetadataGeneration = nil
                        return
                    }
                    let initializedDuration: Int64
                    if self.overriddenDuration > 0 && assetDuration > self.overriddenDuration {
                        currentItem.forwardPlaybackEndTime = CMTime(
                            value: CMTimeValue(self.overriddenDuration / 1000),
                            timescale: 1
                        )
                        initializedDuration = Int64(self.overriddenDuration)
                    } else {
                        initializedDuration = duration
                    }

                    self.isInitialized = true
                    self.updatePlayingState()
                    eventSink([
                        "event": "initialized",
                        "duration": initializedDuration,
                        "width": abs(realSize.width) != 0 ? abs(realSize.width) : width,
                        "height": abs(realSize.height) != 0 ? abs(realSize.height) : height,
                        "key": self.key as Any
                    ])
                }
            }
        }
    }

    func play() {
        stalledCount = 0
        isStalledCheckStarted = false
        isPlaying = true
        updatePlayingState()
    }

    func pause() {
        isPlaying = false
        updatePlayingState()
    }

    func position() -> Int64 {
        BetterPlayerTimeUtils.millis(from: player.currentTime())
    }

    func absolutePosition() -> Int64 {
        let interval = player.currentItem?.currentDate()?.timeIntervalSince1970 ?? 0
        return BetterPlayerTimeUtils.millis(from: interval)
    }

    func positionAsync(completion: @escaping (Int64) -> Void) {
        requestPlaybackSnapshot { snapshot in
            completion(snapshot.position)
        }
    }

    func absolutePositionAsync(completion: @escaping (Int64) -> Void) {
        requestPlaybackSnapshot { snapshot in
            completion(snapshot.absolutePosition)
        }
    }

    func playbackSnapshot(completion: @escaping (Int64, Int64) -> Void) {
        requestPlaybackSnapshot { snapshot in
            completion(snapshot.position, snapshot.duration)
        }
    }

    private func requestPlaybackSnapshot(completion: @escaping (PlaybackSnapshot) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.requestPlaybackSnapshot(completion: completion)
            }
            return
        }

        snapshotCompletions.append(completion)
        startPlaybackSnapshotIfNeeded()
    }

    private func startPlaybackSnapshotIfNeeded() {
        guard !snapshotRequestInFlight, !snapshotCompletions.isEmpty else {
            return
        }
        snapshotRequestInFlight = true
        let generation = sourceGeneration

        mediaPropertyQueue.async { [weak self] in
            guard let self else {
                return
            }
            let item = self.player.currentItem
            let snapshot = PlaybackSnapshot(
                position: item.map { BetterPlayerTimeUtils.millis(from: $0.currentTime()) } ?? 0,
                absolutePosition: BetterPlayerTimeUtils.millis(
                    from: item?.currentDate()?.timeIntervalSince1970 ?? 0
                ),
                duration: item.map { self.duration(for: $0) } ?? 0,
                durationIsFinite: item.map {
                    BetterPlayerTimeUtils.isFinite($0.duration)
                } ?? false
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.snapshotRequestInFlight = false
                guard self.sourceGeneration == generation else {
                    self.startPlaybackSnapshotIfNeeded()
                    return
                }
                let completions = self.snapshotCompletions
                self.snapshotCompletions.removeAll()
                completions.forEach { $0(snapshot) }
            }
        }
    }

    func duration() -> Int64 {
        guard let currentItem = player.currentItem else {
            return 0
        }
        return duration(for: currentItem)
    }

    private func duration(for currentItem: AVPlayerItem) -> Int64 {
        var time: CMTime
        if #available(iOS 13.0, *) {
            time = currentItem.duration
        } else {
            time = currentItem.asset.duration
        }
        if BetterPlayerTimeUtils.isFinite(currentItem.forwardPlaybackEndTime) {
            time = currentItem.forwardPlaybackEndTime
        }
        return BetterPlayerTimeUtils.millis(from: time)
    }

    func seekTo(_ location: Int) {
        let wasPlaying = isPlaying
        if wasPlaying {
            player.pause()
        }
        player.seek(
            to: CMTime(value: CMTimeValue(location), timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            if wasPlaying {
                self?.player.rate = self?.playerRate ?? 1
            }
        }
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(max(volume, 0.0), 1.0))
    }

    func setSpeed(_ speed: Double, result: FlutterResult) {
        if speed == 1.0 || speed == 0.0 {
            playerRate = 1
            result(nil)
            if isPlaying {
                player.rate = playerRate
            }
            return
        }
        if speed < 0 || speed > 2.0 {
            result(FlutterError(
                code: "unsupported_speed",
                message: "Speed must be >= 0.0 and <= 2.0",
                details: nil
            ))
            return
        }

        guard let currentItem = player.currentItem else {
            result(FlutterError(
                code: "VideoError",
                message: "Cannot change speed before a video is loaded",
                details: nil
            ))
            return
        }
        let generation = sourceGeneration
        mediaPropertyQueue.async { [weak self, weak currentItem] in
            let supported = speed > 1.0
                ? currentItem?.canPlayFastForward == true
                : currentItem?.canPlaySlowForward == true
            DispatchQueue.main.async { [weak self, weak currentItem] in
                guard let self,
                      let currentItem,
                      self.isCurrent(item: currentItem, generation: generation) else {
                    result(FlutterError(
                        code: "VideoError",
                        message: "Video source changed before speed was applied",
                        details: nil
                    ))
                    return
                }
                if supported {
                    self.playerRate = Float(speed)
                    if self.isPlaying {
                        self.player.rate = self.playerRate
                    }
                    result(nil)
                } else if speed > 1.0 {
                    result(FlutterError(
                        code: "unsupported_fast_forward",
                        message: "This video cannot be played fast forward",
                        details: nil
                    ))
                } else {
                    result(FlutterError(
                        code: "unsupported_slow_forward",
                        message: "This video cannot be played slow forward",
                        details: nil
                    ))
                }
            }
        }
    }

    func setTrackParameters(width: Int, height: Int, bitrate: Int) {
        player.currentItem?.preferredPeakBitRate = Double(bitrate)
        if #available(iOS 11.0, *) {
            player.currentItem?.preferredMaximumResolution = width == 0 && height == 0
                ? .zero
                : CGSize(width: width, height: height)
        }
    }

    func setPictureInPicture(_ pictureInPicture: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setPictureInPicture(pictureInPicture)
            }
            return
        }
        self.pictureInPicture = pictureInPicture
        pipGeneration &+= 1
        let generation = pipGeneration
        guard #available(iOS 9.0, *), let pipController else {
            return
        }
        if pictureInPicture && !pipController.isPictureInPictureActive {
            DispatchQueue.main.async { [weak self, weak pipController] in
                guard let self,
                      self.pipGeneration == generation,
                      self.pictureInPicture,
                      let pipController else {
                    return
                }
                pipController.startPictureInPicture()
            }
        } else if !pictureInPicture && pipController.isPictureInPictureActive {
            DispatchQueue.main.async { [weak self, weak pipController] in
                guard let self,
                      self.pipGeneration == generation,
                      !self.pictureInPicture,
                      let pipController else {
                    return
                }
                pipController.stopPictureInPicture()
            }
        }
    }

    func setupPipController() {
        guard #available(iOS 9.0, *) else {
            return
        }
        BetterPlayerAudioSession.activate()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        if pipController == nil,
           let playerLayer,
           AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
        }
    }

    func enablePictureInPicture(_ frame: CGRect) {
        disablePictureInPicture()
        usePlayerLayer(frame)
    }

    private func usePlayerLayer(_ frame: CGRect) {
        let layer = AVPlayerLayer(player: player)
        playerLayer = layer
        layer.frame = frame
        layer.needsDisplayOnBoundsChange = true
        if let view = betterPlayerRootViewController()?.view {
            view.layer.addSublayer(layer)
            view.layer.needsDisplayOnBoundsChange = true
        }
        pipController = nil
        setupPipController()
        pipGeneration &+= 1
        let generation = pipGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.pipGeneration == generation, self.playerLayer != nil else {
                return
            }
            self.setPictureInPicture(true)
        }
    }

    func disablePictureInPicture() {
        pipGeneration &+= 1
        pictureInPicture = false
        if #available(iOS 9.0, *), let pipController, pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        }
        if let playerLayer {
            playerLayer.removeFromSuperlayer()
            self.playerLayer = nil
            eventSink?(["event": "pipStop"])
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        disablePictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        eventSink?(["event": "pipStart"])
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func setAudioTrack(name: String?, index: Int, completion: @escaping () -> Void) {
        guard let currentItem = player.currentItem else {
            completion()
            return
        }
        let generation = sourceGeneration
        mediaPropertyQueue.async { [weak self, weak currentItem] in
            guard let currentItem,
                  let audioSelectionGroup = currentItem.asset
                      .mediaSelectionGroup(forMediaCharacteristic: .audible) else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }
            let option = audioSelectionGroup.options.enumerated().first { audioTrackIndex, option in
                guard audioTrackIndex == index else {
                    return false
                }
                let metadata = AVMetadataItem.metadataItems(
                    from: option.commonMetadata,
                    withKey: "title" as NSString,
                    keySpace: .common
                )
                return metadata.first?.stringValue == name
            }?.element
            DispatchQueue.main.async { [weak self, weak currentItem] in
                guard let self,
                      let currentItem,
                      self.isCurrent(item: currentItem, generation: generation),
                      let option else {
                    completion()
                    return
                }
                currentItem.select(option, in: audioSelectionGroup)
                completion()
            }
        }
    }

    func setMixWithOthers(_ mixWithOthers: Bool) {
        if mixWithOthers {
            try? AVAudioSession.sharedInstance().setCategory(
                .playback,
                options: .mixWithOthers
            )
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
        }
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        onReadyToPlay()
        return nil
    }

    func disposeSansEventChannel() {
        clear()
    }

    func dispose() {
        pause()
        disposeSansEventChannel()
        eventChannel?.setStreamHandler(nil)
        disablePictureInPicture()
        disposed = true
    }

    deinit {
        if observersAdded {
            removeObservers()
        }
    }
}
