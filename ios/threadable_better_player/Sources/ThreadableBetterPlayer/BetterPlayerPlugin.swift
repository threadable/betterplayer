import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

@objc(BetterPlayerPlugin)
public final class BetterPlayerPlugin: NSObject, FlutterPlugin, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger
    private let registrar: FlutterPluginRegistrar
    private var players: [Int64: BetterPlayer] = [:]
    private var dataSourceDict: [Int64: [String: Any]] = [:]
    private var timeObserverIdDict: [Int64: Any] = [:]
    private var artworkImageDict: [Int64: MPMediaItemArtwork] = [:]
    private let cacheManager = CacheManager()
    private var texturesCount: Int64 = -1
    private weak var notificationPlayer: BetterPlayer?
    private var remoteCommandsInitialized = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "better_player_channel",
            binaryMessenger: registrar.messenger()
        )
        let instance = BetterPlayerPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.register(instance, withId: "io.threadable/betterplayer")
    }

    private init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        self.messenger = registrar.messenger()
        super.init()
        cacheManager.setup()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        for player in players.values {
            player.disposeSansEventChannel()
        }
        players.removeAll()
    }

    public func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        guard let args = args as? [String: Any],
              let textureId = (args["textureId"] as? NSNumber)?.int64Value,
              let player = players[textureId] else {
            return MissingBetterPlayerView()
        }
        return player
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "init" {
            for player in players.values {
                disposeNotificationData(player)
                player.dispose()
            }
            players.removeAll()
            result(nil)
            return
        }

        if call.method == "create" {
            let player = BetterPlayer()
            onPlayerSetup(player, result: result)
            return
        }

        guard let argsMap = call.arguments as? [String: Any],
              let textureId = (argsMap["textureId"] as? NSNumber)?.int64Value,
              let player = players[textureId] else {
            result(FlutterMethodNotImplemented)
            return
        }

        switch call.method {
        case "setDataSource":
            setDataSource(argsMap: argsMap, player: player, result: result)
        case "dispose":
            dispose(player: player, textureId: textureId, result: result)
        case "setLooping":
            player.isLooping = (argsMap["looping"] as? NSNumber)?.boolValue ?? false
            result(nil)
        case "setVolume":
            player.setVolume((argsMap["volume"] as? NSNumber)?.doubleValue ?? 0)
            result(nil)
        case "play":
            setupRemoteNotification(player)
            player.play()
            result(nil)
        case "position":
            result(NSNumber(value: player.position()))
        case "absolutePosition":
            result(NSNumber(value: player.absolutePosition()))
        case "seekTo":
            player.seekTo((argsMap["location"] as? NSNumber)?.intValue ?? 0)
            result(nil)
        case "pause":
            player.pause()
            result(nil)
        case "setSpeed":
            player.setSpeed((argsMap["speed"] as? NSNumber)?.doubleValue ?? 1, result: result)
        case "setTrackParameters":
            player.setTrackParameters(
                width: (argsMap["width"] as? NSNumber)?.intValue ?? 0,
                height: (argsMap["height"] as? NSNumber)?.intValue ?? 0,
                bitrate: (argsMap["bitrate"] as? NSNumber)?.intValue ?? 0
            )
            result(nil)
        case "enablePictureInPicture":
            player.enablePictureInPicture(CGRect(
                x: (argsMap["left"] as? NSNumber)?.doubleValue ?? 0,
                y: (argsMap["top"] as? NSNumber)?.doubleValue ?? 0,
                width: (argsMap["width"] as? NSNumber)?.doubleValue ?? 0,
                height: (argsMap["height"] as? NSNumber)?.doubleValue ?? 0
            ))
            result(nil)
        case "isPictureInPictureSupported":
            result(NSNumber(value: AVPictureInPictureController.isPictureInPictureSupported()))
        case "disablePictureInPicture":
            player.disablePictureInPicture()
            player.setPictureInPicture(false)
            result(nil)
        case "setAudioTrack":
            player.setAudioTrack(
                name: argsMap["name"] as? String,
                index: (argsMap["index"] as? NSNumber)?.intValue ?? 0
            )
            result(nil)
        case "setMixWithOthers":
            player.setMixWithOthers((argsMap["mixWithOthers"] as? NSNumber)?.boolValue ?? false)
            result(nil)
        case "preCache":
            preCache(argsMap: argsMap)
            result(nil)
        case "clearCache":
            cacheManager.clearCache()
            result(nil)
        case "stopPreCache":
            stopPreCache(argsMap: argsMap)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func newTextureId() -> Int64 {
        texturesCount += 1
        return texturesCount
    }

    private func onPlayerSetup(_ player: BetterPlayer, result: FlutterResult) {
        let textureId = newTextureId()
        let eventChannel = FlutterEventChannel(
            name: "better_player_channel/videoEvents\(textureId)",
            binaryMessenger: messenger
        )
        player.setMixWithOthers(false)
        eventChannel.setStreamHandler(player)
        player.eventChannel = eventChannel
        players[textureId] = player
        result(["textureId": NSNumber(value: textureId)])
    }

    private func setDataSource(
        argsMap: [String: Any],
        player: BetterPlayer,
        result: FlutterResult
    ) {
        player.clear()

        guard let dataSource = argsMap["dataSource"] as? [String: Any] else {
            result(FlutterMethodNotImplemented)
            return
        }

        if let textureId = getTextureId(player) {
            dataSourceDict[textureId] = dataSource
        }

        let key = dataSource["key"] as? String
        let certificateUrl = dataSource["certificateUrl"] as? String
        let licenseUrl = dataSource["licenseUrl"] as? String
        let cacheKey = dataSource["cacheKey"] as? String
        let maxCacheSize = dataSource["maxCacheSize"] as? NSNumber
        let videoExtension = dataSource["videoExtension"] as? String
        let headers = dataSource["headers"] as? [AnyHashable: Any] ?? [:]
        let overriddenDuration = (dataSource["overriddenDuration"] as? NSNumber)?.intValue ?? 0
        let useCache = (dataSource["useCache"] as? NSNumber)?.boolValue ?? false

        if useCache {
            cacheManager.setMaxCacheSize(maxCacheSize)
        }

        if let assetArg = dataSource["asset"] as? String {
            let assetPath: String
            if let package = dataSource["package"] as? String {
                assetPath = registrar.lookupKey(forAsset: assetArg, fromPackage: package)
            } else {
                assetPath = registrar.lookupKey(forAsset: assetArg)
            }
            player.setDataSourceAsset(
                assetPath,
                key: key,
                certificateUrl: certificateUrl,
                licenseUrl: licenseUrl,
                cacheKey: cacheKey,
                cacheManager: cacheManager,
                overriddenDuration: overriddenDuration
            )
            result(nil)
            return
        }

        if let uriArg = dataSource["uri"] as? String,
           let url = URL(string: uriArg) {
            player.setDataSourceURL(
                url,
                key: key,
                certificateUrl: certificateUrl,
                licenseUrl: licenseUrl,
                headers: headers,
                useCache: useCache,
                cacheKey: cacheKey,
                cacheManager: cacheManager,
                overriddenDuration: overriddenDuration,
                videoExtension: videoExtension
            )
            result(nil)
            return
        }

        result(FlutterMethodNotImplemented)
    }

    private func dispose(player: BetterPlayer, textureId: Int64, result: FlutterResult) {
        player.clear()
        disposeNotificationData(player)
        setRemoteCommandsNotificationNotActive()
        players.removeValue(forKey: textureId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !player.disposed {
                player.dispose()
            }
        }

        if players.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        result(nil)
    }

    private func preCache(argsMap: [String: Any]) {
        guard let dataSource = argsMap["dataSource"] as? [String: Any],
              let urlArg = dataSource["uri"] as? String,
              let url = URL(string: urlArg) else {
            return
        }

        let cacheKey = dataSource["cacheKey"] as? String
        let headers = dataSource["headers"] as? [AnyHashable: Any] ?? [:]
        let maxCacheSize = dataSource["maxCacheSize"] as? NSNumber
        let videoExtension = dataSource["videoExtension"] as? String

        if cacheManager.isPreCacheSupported(url: url, videoExtension: videoExtension) {
            cacheManager.setMaxCacheSize(maxCacheSize)
            cacheManager.preCacheURL(
                url,
                cacheKey: cacheKey,
                videoExtension: videoExtension,
                withHeaders: headers,
                completionHandler: { _ in }
            )
        } else {
            NSLog("Pre cache is not supported for given data source.")
        }
    }

    private func stopPreCache(argsMap: [String: Any]) {
        guard let urlArg = argsMap["url"] as? String,
              let url = URL(string: urlArg) else {
            return
        }

        let cacheKey = argsMap["cacheKey"] as? String
        let videoExtension = argsMap["videoExtension"] as? String

        if cacheManager.isPreCacheSupported(url: url, videoExtension: videoExtension) {
            cacheManager.stopPreCache(url, cacheKey: cacheKey, completionHandler: { _ in })
        } else {
            NSLog("Stop pre cache is not supported for given data source.")
        }
    }

    private func setupRemoteNotification(_ player: BetterPlayer) {
        notificationPlayer = player
        stopOtherUpdateListener(player)
        guard let textureId = getTextureId(player),
              let dataSource = dataSourceDict[textureId] else {
            return
        }

        let showNotification = (dataSource["showNotification"] as? NSNumber)?.boolValue ?? false
        let title = safeString(dataSource["title"], fallback: "")
        let author = safeString(dataSource["author"], fallback: "")
        let imageUrl = safeString(dataSource["imageUrl"], fallback: "")

        if showNotification {
            setRemoteCommandsNotificationActive()
            setupRemoteCommands()
            setupRemoteCommandNotification(player, title: title, author: author, imageUrl: imageUrl)
            setupUpdateListener(player, title: title, author: author, imageUrl: imageUrl)
        }
    }

    private func setRemoteCommandsNotificationActive() {
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func setRemoteCommandsNotificationNotActive() {
        if players.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func safeString(_ value: Any?, fallback: String) -> String {
        if let value = value as? String {
            return value
        }
        if let value {
            return String(describing: value)
        }
        return fallback
    }

    private func canSendRemoteCommandEvent() -> Bool {
        guard let notificationPlayer,
              !notificationPlayer.disposed,
              notificationPlayer.eventSink != nil else {
            return false
        }
        return true
    }

    private func sendRemoteCommandEvent(_ event: String) -> MPRemoteCommandHandlerStatus {
        guard canSendRemoteCommandEvent() else {
            return .noSuchContent
        }
        notificationPlayer?.eventSink?(["event": event])
        return .success
    }

    private func sendRemoteSeekEvent(_ millis: Int64) -> MPRemoteCommandHandlerStatus {
        guard canSendRemoteCommandEvent() else {
            return .noSuchContent
        }
        notificationPlayer?.seekTo(Int(millis))
        notificationPlayer?.eventSink?(["event": "seek", "position": NSNumber(value: millis)])
        return .success
    }

    private func setNowPlayingInfoSafely(_ nowPlayingInfo: [String: Any]) {
        let immutableInfo = nowPlayingInfo
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = immutableInfo
        }
    }

    private func removeRemoteCommandTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        remoteCommandsInitialized = false
    }

    private func setupRemoteCommands() {
        guard !remoteCommandsInitialized else {
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.canSendRemoteCommandEvent() else {
                return .noSuchContent
            }
            return self.sendRemoteCommandEvent(self.notificationPlayer?.isPlaying == true ? "pause" : "play")
        }

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommandEvent("play") ?? .noSuchContent
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommandEvent("pause") ?? .noSuchContent
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let playbackEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let time = CMTime(seconds: playbackEvent.positionTime, preferredTimescale: 1)
            let millis = BetterPlayerTimeUtils.millis(from: time)
            return self?.sendRemoteSeekEvent(millis) ?? .noSuchContent
        }

        remoteCommandsInitialized = true
    }

    private func setupRemoteCommandNotification(
        _ player: BetterPlayer,
        title: String,
        author: String,
        imageUrl: String
    ) {
        guard !player.disposed else {
            return
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyArtist: author,
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0.0, Double(player.position()) / 1000.0),
            MPMediaItemPropertyPlaybackDuration: max(0.0, Double(player.duration()) / 1000.0),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1 : 0
        ]

        guard !imageUrl.isEmpty, let key = getTextureId(player) else {
            setNowPlayingInfoSafely(nowPlayingInfo)
            return
        }

        if let artworkImage = artworkImageDict[key] {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artworkImage
            setNowPlayingInfoSafely(nowPlayingInfo)
            return
        }

        let baseNowPlayingInfo = nowPlayingInfo
        DispatchQueue.global(qos: .default).async { [weak self] in
            guard let self else {
                return
            }
            var infoWithArtwork = baseNowPlayingInfo
            let image: UIImage?
            if imageUrl.contains("http"),
               let url = URL(string: imageUrl),
               let data = try? Data(contentsOf: url) {
                image = UIImage(data: data)
            } else {
                image = UIImage(contentsOfFile: imageUrl)
            }

            if let image {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artworkImageDict[key] = artwork
                infoWithArtwork[MPMediaItemPropertyArtwork] = artwork
            }
            self.setNowPlayingInfoSafely(infoWithArtwork)
        }
    }

    private func getTextureId(_ player: BetterPlayer) -> Int64? {
        players.first { $0.value === player }?.key
    }

    private func setupUpdateListener(
        _ player: BetterPlayer,
        title: String,
        author: String,
        imageUrl: String
    ) {
        guard let key = getTextureId(player) else {
            return
        }

        let observer = player.player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 1),
            queue: nil
        ) { [weak self, weak player] _ in
            guard let self, let player else {
                return
            }
            self.setupRemoteCommandNotification(
                player,
                title: title,
                author: author,
                imageUrl: imageUrl
            )
        }
        timeObserverIdDict[key] = observer
    }

    private func disposeNotificationData(_ player: BetterPlayer) {
        if player === notificationPlayer {
            removeRemoteCommandTargets()
            notificationPlayer = nil
        }

        guard let key = getTextureId(player) else {
            setNowPlayingInfoSafely([:])
            return
        }

        if let timeObserverId = timeObserverIdDict.removeValue(forKey: key) {
            player.player.removeTimeObserver(timeObserverId)
        }
        artworkImageDict.removeValue(forKey: key)
        setNowPlayingInfoSafely([:])
    }

    private func stopOtherUpdateListener(_ player: BetterPlayer) {
        let currentPlayerTextureId = getTextureId(player)
        for textureId in Array(timeObserverIdDict.keys) {
            if currentPlayerTextureId == textureId {
                continue
            }
            if let timeObserverId = timeObserverIdDict[textureId],
               let playerToRemoveListener = players[textureId] {
                playerToRemoveListener.player.removeTimeObserver(timeObserverId)
            }
            timeObserverIdDict.removeValue(forKey: textureId)
        }
    }
}

private final class MissingBetterPlayerView: NSObject, FlutterPlatformView {
    private let emptyView = UIView()

    func view() -> UIView {
        emptyView
    }
}
