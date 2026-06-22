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
    if #available(iOS 13.0, *) {
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
    }
    return UIApplication.shared.keyWindow?.rootViewController
}

final class BetterPlayer: NSObject, FlutterPlatformView, FlutterStreamHandler, AVPictureInPictureControllerDelegate {
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
        observersAdded = true
    }

    func clear() {
        isInitialized = false
        isPlaying = false
        disposed = false
        failedCount = 0
        key = nil
        guard let item = player.currentItem else {
            return
        }
        removeObservers()
        item.asset.cancelLoading()
    }

    private func removeObservers() {
        guard observersAdded, let item = player.currentItem else {
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
        observersAdded = false
    }

    @objc private func itemDidPlayToEndTime(_ notification: Notification) {
        if isLooping {
            (notification.object as? AVPlayerItem)?.seek(to: .zero, completionHandler: nil)
            return
        }
        if let eventSink {
            eventSink(["event": "completed", "key": key as Any])
            removeObservers()
        }
    }

    private func getVideoComposition(
        transform: CGAffineTransform,
        asset: AVAsset,
        videoTrack: AVAssetTrack
    ) -> AVMutableVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        var width = videoTrack.naturalSize.width
        var height = videoTrack.naturalSize.height
        let rotationDegrees = Int(round(radiansToDegrees(atan2(preferredTransform.b, preferredTransform.a))))
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
        overriddenDuration: Int
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
            videoExtension: nil
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
        videoExtension: String?
    ) {
        self.overriddenDuration = 0

        let item: AVPlayerItem
        if useCache,
           let cacheItem = cacheManager.getCachingPlayerItemForNormalPlayback(
            url,
            cacheKey: cacheKey,
            videoExtension: videoExtension,
            headers: headers
           ) {
            item = cacheItem
        } else {
            let asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
            if let certificateUrl,
               !certificateUrl.isEmpty,
               let certificateURL = URL(string: certificateUrl) {
                loaderDelegate = BetterPlayerEzDrmAssetsLoaderDelegate(
                    certificateURL: certificateURL,
                    licenseURL: licenseUrl.flatMap(URL.init(string:))
                )
                let queue = DispatchQueue(label: "streamQueue", qos: .default)
                asset.resourceLoader.setDelegate(loaderDelegate, queue: queue)
            }
            item = AVPlayerItem(asset: asset)
        }

        if #available(iOS 10.0, *), overriddenDuration > 0 {
            self.overriddenDuration = overriddenDuration
        }
        setDataSourcePlayerItem(item, key: key)
    }

    private func setDataSourcePlayerItem(_ item: AVPlayerItem, key: String?) {
        self.key = key
        stalledCount = 0
        isStalledCheckStarted = false
        playerRate = 1
        player.replaceCurrentItem(with: item)

        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item] in
            guard let self, let item, !self.disposed else {
                return
            }
            guard asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                  let videoTrack = asset.tracks(withMediaType: .video).first else {
                return
            }
            videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"]) { [weak self, weak item] in
                guard let self, let item, !self.disposed else {
                    return
                }
                guard videoTrack.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded else {
                    return
                }
                self.preferredTransform = self.fixTransform(videoTrack)
                item.videoComposition = self.getVideoComposition(
                    transform: self.preferredTransform,
                    asset: asset,
                    videoTrack: videoTrack
                )
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
        guard let currentItem = player.currentItem else {
            return
        }
        if currentItem.isPlaybackLikelyToKeepUp
            || availableDuration() - CMTimeGetSeconds(currentItem.currentTime()) > 10.0 {
            play()
            return
        }

        stalledCount += 1
        if stalledCount > 60 {
            eventSink?(
                FlutterError(
                    code: "VideoError",
                    message: "Failed to load video: playback stalled",
                    details: nil
                )
            )
            return
        }

        perform(#selector(startStalledCheck), with: nil, afterDelay: 1)
    }

    private func availableDuration() -> TimeInterval {
        guard let range = player.currentItem?.loadedTimeRanges.first?.timeRangeValue else {
            return 0
        }
        return CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if path == "rate" {
            observeRate()
        }

        if context == &timeRangeContext {
            observeLoadedTimeRanges(object)
        } else if context == &presentationSizeContext {
            onReadyToPlay()
        } else if context == &statusContext {
            observeStatus(object)
        } else if context == &playbackLikelyToKeepUpContext {
            if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                updatePlayingState()
                eventSink?(["event": "bufferingEnd", "key": key as Any])
            }
        } else if context == &playbackBufferEmptyContext {
            eventSink?(["event": "bufferingStart", "key": key as Any])
        } else if context == &playbackBufferFullContext {
            eventSink?(["event": "bufferingEnd", "key": key as Any])
        }
    }

    private func observeRate() {
        if #available(iOS 10.0, *), pipController?.isPictureInPictureActive == true {
            if lastAvPlayerTimeControlStatus == player.timeControlStatus {
                return
            }
            if player.timeControlStatus == .paused {
                lastAvPlayerTimeControlStatus = player.timeControlStatus
                eventSink?(["event": "pause"])
                return
            }
            if player.timeControlStatus == .playing {
                lastAvPlayerTimeControlStatus = player.timeControlStatus
                eventSink?(["event": "play"])
            }
        }

        guard let currentItem = player.currentItem else {
            return
        }
        if player.rate == 0,
           currentItem.currentTime() > .zero,
           currentItem.currentTime() < currentItem.duration,
           isPlaying {
            handleStalled()
        }
    }

    private func observeLoadedTimeRanges(_ object: Any?) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        var values: [[NSNumber]] = []
        for rangeValue in item.loadedTimeRanges {
            let range = rangeValue.timeRangeValue
            let start = BetterPlayerTimeUtils.millis(from: range.start)
            var end = start + BetterPlayerTimeUtils.millis(from: range.duration)
            if let currentItem = player.currentItem,
               BetterPlayerTimeUtils.isFinite(currentItem.forwardPlaybackEndTime) {
                let endTime = BetterPlayerTimeUtils.millis(from: currentItem.forwardPlaybackEndTime)
                if end > endTime {
                    end = endTime
                }
            }
            values.append([NSNumber(value: start), NSNumber(value: end)])
        }
        eventSink?(["event": "bufferingUpdate", "values": values, "key": key as Any])
    }

    private func observeStatus(_ object: Any?) {
        guard let item = object as? AVPlayerItem else {
            return
        }
        switch item.status {
        case .failed:
            NSLog("Failed to load video:")
            NSLog(item.error.debugDescription)
            eventSink?(
                FlutterError(
                    code: "VideoError",
                    message: "Failed to load video: \(item.error?.localizedDescription ?? "")",
                    details: nil
                )
            )
        case .unknown:
            break
        case .readyToPlay:
            onReadyToPlay()
        @unknown default:
            break
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
        guard let eventSink, !isInitialized, key != nil, let currentItem = player.currentItem else {
            return
        }
        guard player.status == .readyToPlay else {
            return
        }

        let size = currentItem.presentationSize
        let width = size.width
        let height = size.height
        let onlyAudio = currentItem.asset.tracks(withMediaType: .video).isEmpty

        if !onlyAudio && height == 0 && width == 0 {
            return
        }
        let isLive = currentItem.duration.isIndefinite
        if !isLive && duration() == 0 {
            return
        }

        var realSize = size
        if let track = currentItem.tracks.first?.assetTrack {
            realSize = track.naturalSize.applying(track.preferredTransform)
        }

        let assetDuration = BetterPlayerTimeUtils.millis(from: currentItem.asset.duration)
        if overriddenDuration > 0 && assetDuration > overriddenDuration {
            currentItem.forwardPlaybackEndTime = CMTime(
                value: CMTimeValue(overriddenDuration / 1000),
                timescale: 1
            )
        }

        isInitialized = true
        updatePlayingState()
        eventSink([
            "event": "initialized",
            "duration": duration(),
            "width": abs(realSize.width) != 0 ? abs(realSize.width) : width,
            "height": abs(realSize.height) != 0 ? abs(realSize.height) : height,
            "key": key as Any
        ])
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

    func duration() -> Int64 {
        guard let currentItem = player.currentItem else {
            return 0
        }
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
        } else if speed < 0 || speed > 2.0 {
            result(FlutterError(
                code: "unsupported_speed",
                message: "Speed must be >= 0.0 and <= 2.0",
                details: nil
            ))
        } else if let currentItem = player.currentItem,
                  (speed > 1.0 && currentItem.canPlayFastForward)
                    || (speed < 1.0 && currentItem.canPlaySlowForward) {
            playerRate = Float(speed)
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

        if isPlaying {
            player.rate = playerRate
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
        self.pictureInPicture = pictureInPicture
        guard #available(iOS 9.0, *), let pipController else {
            return
        }
        if pictureInPicture && !pipController.isPictureInPictureActive {
            DispatchQueue.main.async {
                pipController.startPictureInPicture()
            }
        } else if !pictureInPicture && pipController.isPictureInPictureActive {
            DispatchQueue.main.async {
                pipController.stopPictureInPicture()
            }
        }
    }

    func setupPipController() {
        guard #available(iOS 9.0, *) else {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setPictureInPicture(true)
        }
    }

    func disablePictureInPicture() {
        setPictureInPicture(true)
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

    func setAudioTrack(name: String?, index: Int) {
        guard let audioSelectionGroup = player.currentItem?.asset
            .mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            return
        }

        for (audioTrackIndex, option) in audioSelectionGroup.options.enumerated() {
            let metadata = AVMetadataItem.metadataItems(
                from: option.commonMetadata,
                withKey: "title" as NSString,
                keySpace: .common
            )
            guard let title = metadata.first?.stringValue else {
                continue
            }
            if title == name && audioTrackIndex == index {
                player.currentItem?.select(option, in: audioSelectionGroup)
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
        setPictureInPicture(false)
        disposed = true
    }

    deinit {
        if observersAdded {
            removeObservers()
        }
    }
}
