import AVFoundation
import Foundation
import Network

final class CacheManager: NSObject {
    private let cacheQueue = DispatchQueue(
        label: "io.threadable.betterplayer.cache",
        qos: .utility
    )
    private var preCachedURLs: [String: CachingPlayerItem] = [:]
    private var preCacheCompletions: [ObjectIdentifier: [(Bool) -> Void]] = [:]
    private var cacheableItemGenerations: [ObjectIdentifier: UInt64] = [:]
    private var cacheGeneration: UInt64 = 0
    private let cacheStore = DiskCacheStore(name: "BetterPlayerCache")
    private var server: HLSCachingReverseProxyServer?

    func setup() {
        let cache = DiskCacheStore(name: "BetterPlayerHLSCache")
        let webServer = HLSCachingReverseProxyServer(urlSession: .shared, cache: cache)
        webServer.start(port: 8080)
        server = webServer
    }

    func setMaxCacheSize(_ maxCacheSize: NSNumber?) {
        if let maxCacheSize {
            cacheQueue.async { [cacheStore] in
                cacheStore.maxSize = maxCacheSize.uintValue
            }
        }
    }

    func preCacheURL(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        withHeaders headers: [AnyHashable: Any],
        completionHandler: ((Bool) -> Void)?
    ) {
        let key = cacheKey ?? url.absoluteString
        cacheQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let preCachedItem = self.preCachedURLs[key] {
                if let completionHandler {
                    self.preCacheCompletions[ObjectIdentifier(preCachedItem), default: []].append(
                        completionHandler
                    )
                }
                return
            }

            if self.cacheStore.data(forKey: key) != nil {
                DispatchQueue.main.async {
                    completionHandler?(true)
                }
                return
            }

            let item = CachingPlayerItem(
                url: url,
                customFileExtension: videoExtension,
                cacheKey: key,
                headers: headers
            )
            item.delegate = self
            self.preCachedURLs[key] = item
            if let completionHandler {
                self.preCacheCompletions[ObjectIdentifier(item), default: []].append(
                    completionHandler
                )
            }
            self.cacheableItemGenerations[ObjectIdentifier(item)] = self.cacheGeneration
            item.download()
        }
    }

    func stopPreCache(
        _ url: URL,
        cacheKey: String?,
        completionHandler: ((Bool) -> Void)?
    ) {
        let key = cacheKey ?? url.absoluteString
        cacheQueue.async { [weak self] in
            guard let self, let playerItem = self.preCachedURLs.removeValue(forKey: key) else {
                DispatchQueue.main.async {
                    completionHandler?(false)
                }
                return
            }
            playerItem.stopDownload()
            let itemId = ObjectIdentifier(playerItem)
            self.cacheableItemGenerations.removeValue(forKey: itemId)
            self.preCacheCompletions.removeValue(forKey: itemId)
            DispatchQueue.main.async {
                completionHandler?(true)
            }
        }
    }

    func getCachingPlayerItemForNormalPlayback(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        headers: [AnyHashable: Any],
        completion: @escaping (AVPlayerItem?) -> Void
    ) {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        if mimeTypeResult.mimeType == "application/vnd.apple.mpegurl",
           let reverseProxyURL = server?.reverseProxyURL(from: url) {
            completion(AVPlayerItem(url: reverseProxyURL))
            return
        }
        let key = cacheKey ?? url.absoluteString
        cacheQueue.async { [weak self] in
            guard let self else {
                return
            }

            let preCachedItem = self.preCachedURLs.removeValue(forKey: key)
            let cachedData = preCachedItem == nil ? self.cacheStore.data(forKey: key) : nil
            DispatchQueue.main.async {
                let playerItem: AVPlayerItem
                let shouldTrackDownload: Bool
                if let preCachedItem {
                    playerItem = preCachedItem
                    shouldTrackDownload = true
                } else if let cachedData, !mimeTypeResult.mimeType.isEmpty {
                    playerItem = CachingPlayerItem(
                        data: cachedData,
                        mimeType: mimeTypeResult.mimeType,
                        fileExtension: mimeTypeResult.fileExtension
                    )
                    shouldTrackDownload = false
                } else {
                    if cachedData != nil {
                        NSLog(
                            "Cache error: couldn't find mime type for url: %@. For this URL cache didn't work and video will be played without cache.",
                            url.absoluteString
                        )
                    }
                    playerItem = CachingPlayerItem(
                        url: url,
                        customFileExtension: videoExtension,
                        cacheKey: key,
                        headers: headers
                    )
                    shouldTrackDownload = true
                }
                if shouldTrackDownload, let cachingItem = playerItem as? CachingPlayerItem {
                    cachingItem.delegate = self
                    self.registerCachingItem(cachingItem)
                }
                completion(playerItem)
            }
        }
    }

    func clearCache(completion: (() -> Void)? = nil) {
        cacheQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.cacheGeneration &+= 1
            self.cacheableItemGenerations.removeAll()
            self.preCachedURLs.values.forEach { $0.stopDownload() }
            self.preCachedURLs.removeAll()
            self.preCacheCompletions.removeAll()
            self.cacheStore.clear()
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    private func finishPreCache(item: CachingPlayerItem, success: Bool) {
        let key = item.cacheKey ?? item.url.absoluteString
        if preCachedURLs[key] === item {
            preCachedURLs.removeValue(forKey: key)
        }
        let completions = preCacheCompletions.removeValue(forKey: ObjectIdentifier(item)) ?? []
        DispatchQueue.main.async {
            completions.forEach { $0(success) }
        }
    }

    private func registerCachingItem(_ item: CachingPlayerItem) {
        let itemId = ObjectIdentifier(item)
        cacheQueue.sync {
            cacheableItemGenerations[itemId] = cacheGeneration
        }
    }

    func isPreCacheSupported(url: URL, videoExtension: String?) -> Bool {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        return !mimeTypeResult.mimeType.isEmpty
            && mimeTypeResult.mimeType != "application/vnd.apple.mpegurl"
    }

    private func getMimeType(
        url: URL,
        explicitVideoExtension: String?
    ) -> (fileExtension: String, mimeType: String) {
        let fileExtension = explicitVideoExtension ?? url.pathExtension
        let mimeType: String
        switch fileExtension {
        case "m3u", "m3u8":
            mimeType = "application/vnd.apple.mpegurl"
        case "3gp":
            mimeType = "video/3gpp"
        case "mp4", "m4a", "m4p", "m4b", "m4r", "m4v":
            mimeType = "video/mp4"
        case "m1v", "mpg", "mp2", "mpeg", "mpe", "mpv":
            mimeType = "video/mpeg"
        case "ogg":
            mimeType = "video/ogg"
        case "mov", "qt":
            mimeType = "video/quicktime"
        case "webm":
            mimeType = "video/webm"
        case "asf", "wma", "wmv":
            mimeType = "video/ms-asf"
        case "avi":
            mimeType = "video/x-msvideo"
        default:
            mimeType = ""
        }
        return (fileExtension, mimeType)
    }
}

extension CacheManager: CachingPlayerItemDelegate {
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data) {
        let key = playerItem.cacheKey ?? playerItem.url.absoluteString
        cacheQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard self.cacheableItemGenerations.removeValue(
                forKey: ObjectIdentifier(playerItem)
            ) != nil else {
                return
            }
            self.cacheStore.store(data, forKey: key)
            self.finishPreCache(item: playerItem, success: true)
        }
    }

    func playerItem(
        _ playerItem: CachingPlayerItem,
        didDownloadBytesSoFar bytesDownloaded: Int,
        outOf bytesExpected: Int
    ) {
        let percentage = bytesExpected > 0
            ? Double(bytesDownloaded) / Double(bytesExpected) * 100.0
            : 0.0
        _ = String(format: "%.1f%%", percentage)
    }

    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        NSLog("Error when downloading the file %@", error as NSError)
        cacheQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard self.cacheableItemGenerations.removeValue(
                forKey: ObjectIdentifier(playerItem)
            ) != nil else {
                return
            }
            self.finishPreCache(item: playerItem, success: false)
        }
    }
}

final class DiskCacheStore {
    var maxSize: UInt = 100 * 1024 * 1024

    private let fileManager = FileManager.default
    private let directory: URL

    init(name: String) {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = cachesDirectory.appendingPathComponent(name, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    func store(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    func clear() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        files.forEach { try? fileManager.removeItem(at: $0) }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(stableHash(key), isDirectory: false)
    }

    private func pruneIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return
        }

        var totalSize = files.reduce(UInt(0)) { total, file in
            total + fileSize(file)
        }
        guard totalSize > maxSize else {
            return
        }

        let sortedFiles = files.sorted {
            modificationDate($0) < modificationDate($1)
        }
        for file in sortedFiles where totalSize > maxSize {
            totalSize = totalSize > fileSize(file) ? totalSize - fileSize(file) : 0
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileSize(_ url: URL) -> UInt {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt(values?.fileSize ?? 0)
    }

    private func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func stableHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

final class HLSCachingReverseProxyServer {
    private static let originURLKey = "__hls_origin_url"

    private let urlSession: URLSession
    private let cache: DiskCacheStore
    private let queue = DispatchQueue(label: "io.threadable.betterplayer.hls-proxy")
    private let cacheQueue = DispatchQueue(
        label: "io.threadable.betterplayer.hls-cache",
        qos: .utility
    )
    private var listener: NWListener?
    private var port: UInt16?

    init(urlSession: URLSession, cache: DiskCacheStore) {
        self.urlSession = urlSession
        self.cache = cache
    }

    func start(port requestedPort: UInt16) {
        guard listener == nil else {
            return
        }
        do {
            let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            port = requestedPort
        } catch {
            NSLog("Failed to start HLS cache proxy: %@", error as NSError)
        }
    }

    func reverseProxyURL(from originURL: URL) -> URL? {
        guard let port else {
            return nil
        }
        guard var components = URLComponents(url: originURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: Self.originURLKey, value: originURL.absoluteString))
        components.queryItems = queryItems
        return components.url
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            self.response(for: data ?? Data()) { response in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for requestData: Data, completion: @escaping (Data) -> Void) {
        guard let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            completion(httpResponse(status: "400 Bad Request", data: Data()))
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let localURL = URL(string: "http://127.0.0.1\(parts[1])"),
              let originURL = originURL(from: localURL) else {
            completion(httpResponse(status: "400 Bad Request", data: Data()))
            return
        }

        if originURL.pathExtension == "m3u8" {
            playlistResponse(for: originURL, completion: completion)
            return
        }
        segmentResponse(for: originURL, completion: completion)
    }

    private func originURL(from localURL: URL) -> URL? {
        guard let components = URLComponents(url: localURL, resolvingAgainstBaseURL: false),
              let encodedURL = components.queryItems?.first(where: { $0.name == Self.originURLKey })?.value else {
            return nil
        }
        return URL(string: encodedURL.removingPercentEncoding ?? encodedURL)
    }

    private func playlistResponse(for originURL: URL, completion: @escaping (Data) -> Void) {
        fetch(originURL) { data in
            guard let data else {
                completion(self.httpResponse(status: "500 Internal Server Error", data: Data()))
                return
            }
            let playlist = self.reverseProxyPlaylist(with: data, forOriginURL: originURL)
            completion(self.httpResponse(
                status: "200 OK",
                contentType: "application/x-mpegurl",
                data: playlist
            ))
        }
    }

    private func segmentResponse(for originURL: URL, completion: @escaping (Data) -> Void) {
        let key = originURL.absoluteString
        cacheQueue.async {
            if let cachedData = self.cache.data(forKey: key) {
                completion(self.httpResponse(
                    status: "200 OK",
                    contentType: "video/mp2t",
                    data: cachedData
                ))
                return
            }

            self.fetch(originURL) { data in
                self.cacheQueue.async {
                    guard let data else {
                        completion(self.httpResponse(
                            status: "500 Internal Server Error",
                            data: Data()
                        ))
                        return
                    }
                    self.cache.store(data, forKey: key)
                    completion(self.httpResponse(
                        status: "200 OK",
                        contentType: "video/mp2t",
                        data: data
                    ))
                }
            }
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        urlSession.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    private func reverseProxyPlaylist(with data: Data, forOriginURL originURL: URL) -> Data {
        guard let playlist = String(data: data, encoding: .utf8) else {
            return data
        }
        let rewritten = playlist
            .components(separatedBy: .newlines)
            .map { processPlaylistLine($0, forOriginURL: originURL) }
            .joined(separator: "\n")
        return Data(rewritten.utf8)
    }

    private func processPlaylistLine(_ line: String, forOriginURL originURL: URL) -> String {
        guard !line.isEmpty else {
            return line
        }
        if line.hasPrefix("#") {
            return lineByReplacingURI(line: line, forOriginURL: originURL)
        }
        guard let absoluteURL = absoluteURL(from: line, forOriginURL: originURL),
              let reverseProxyURL = reverseProxyURL(from: absoluteURL) else {
            return line
        }
        return reverseProxyURL.absoluteString
    }

    private func lineByReplacingURI(line: String, forOriginURL originURL: URL) -> String {
        guard let expression = try? NSRegularExpression(pattern: "URI=\"(.*)\"") else {
            return line
        }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let result = expression.firstMatch(in: line, range: range) else {
            return line
        }
        let uri = (line as NSString).substring(with: result.range(at: 1))
        guard let absoluteURL = absoluteURL(from: uri, forOriginURL: originURL),
              let reverseProxyURL = reverseProxyURL(from: absoluteURL) else {
            return line
        }
        return expression.stringByReplacingMatches(
            in: line,
            range: range,
            withTemplate: "URI=\"\(reverseProxyURL.absoluteString)\""
        )
    }

    private func absoluteURL(from line: String, forOriginURL originURL: URL) -> URL? {
        guard ["m3u8", "ts"].contains(originURL.pathExtension) else {
            return nil
        }
        if line.hasPrefix("http://") || line.hasPrefix("https://") {
            return URL(string: line)
        }
        guard let scheme = originURL.scheme, let host = originURL.host else {
            return nil
        }
        let path = line.hasPrefix("/")
            ? line
            : originURL.deletingLastPathComponent().appendingPathComponent(line).path
        return URL(string: "\(scheme)://\(host)\(path)")?.standardized
    }

    private func httpResponse(
        status: String,
        contentType: String = "application/octet-stream",
        data: Data
    ) -> Data {
        var response = Data(
            """
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType)\r
            Content-Length: \(data.count)\r
            Connection: close\r
            \r
            """.utf8
        )
        response.append(data)
        return response
    }
}
