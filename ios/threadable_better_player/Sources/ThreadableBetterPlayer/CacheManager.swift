import AVFoundation
import Foundation
import Network

final class CacheManager: NSObject {
    private var preCachedURLs: [String: CachingPlayerItem] = [:]
    private var completionHandler: ((Bool) -> Void)?
    private var existsInStorage = false
    private var maxCacheSize: UInt = 100 * 1024 * 1024
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
            self.maxCacheSize = maxCacheSize.uintValue
            cacheStore.maxSize = maxCacheSize.uintValue
        }
    }

    func preCacheURL(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        withHeaders headers: [AnyHashable: Any],
        completionHandler: ((Bool) -> Void)?
    ) {
        self.completionHandler = completionHandler

        let key = cacheKey ?? url.absoluteString
        if preCachedURLs[key] != nil {
            completionHandler?(true)
            return
        }

        guard let item = getCachingPlayerItem(
            url,
            cacheKey: key,
            videoExtension: videoExtension,
            headers: headers
        ) else {
            completionHandler?(false)
            return
        }

        if existsInStorage {
            completionHandler?(true)
            return
        }

        preCachedURLs[key] = item
        item.download()
    }

    func stopPreCache(
        _ url: URL,
        cacheKey: String?,
        completionHandler: ((Bool) -> Void)?
    ) {
        let key = cacheKey ?? url.absoluteString
        guard let playerItem = preCachedURLs[key] else {
            completionHandler?(false)
            return
        }
        playerItem.stopDownload()
        preCachedURLs.removeValue(forKey: key)
        completionHandler?(true)
    }

    func getCachingPlayerItemForNormalPlayback(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        headers: [AnyHashable: Any]
    ) -> AVPlayerItem? {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        if mimeTypeResult.mimeType == "application/vnd.apple.mpegurl",
           let reverseProxyURL = server?.reverseProxyURL(from: url) {
            return AVPlayerItem(url: reverseProxyURL)
        }
        return getCachingPlayerItem(
            url,
            cacheKey: cacheKey,
            videoExtension: videoExtension,
            headers: headers
        )
    }

    func getCachingPlayerItem(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        headers: [AnyHashable: Any]
    ) -> CachingPlayerItem? {
        let key = cacheKey ?? url.absoluteString
        let playerItem: CachingPlayerItem

        if let preCachedItem = preCachedURLs[key] {
            playerItem = preCachedItem
            preCachedURLs.removeValue(forKey: key)
        } else if let data = cacheStore.data(forKey: key) {
            existsInStorage = true
            let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
            if mimeTypeResult.mimeType.isEmpty {
                NSLog(
                    "Cache error: couldn't find mime type for url: %@. For this URL cache didn't work and video will be played without cache.",
                    url.absoluteString
                )
                playerItem = CachingPlayerItem(url: url, cacheKey: key, headers: headers)
            } else {
                playerItem = CachingPlayerItem(
                    data: data,
                    mimeType: mimeTypeResult.mimeType,
                    fileExtension: mimeTypeResult.fileExtension
                )
            }
        } else {
            existsInStorage = false
            playerItem = CachingPlayerItem(
                url: url,
                customFileExtension: videoExtension,
                cacheKey: key,
                headers: headers
            )
        }

        playerItem.delegate = self
        return playerItem
    }

    func clearCache() {
        cacheStore.clear()
        preCachedURLs.removeAll()
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
        cacheStore.store(data, forKey: playerItem.cacheKey ?? playerItem.url.absoluteString)
        completionHandler?(true)
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
        completionHandler?(false)
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
            let response = self.response(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            return httpResponse(status: "400 Bad Request", data: Data())
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let localURL = URL(string: "http://127.0.0.1\(parts[1])"),
              let originURL = originURL(from: localURL) else {
            return httpResponse(status: "400 Bad Request", data: Data())
        }

        if originURL.pathExtension == "m3u8" {
            return playlistResponse(for: originURL)
        }
        return segmentResponse(for: originURL)
    }

    private func originURL(from localURL: URL) -> URL? {
        guard let components = URLComponents(url: localURL, resolvingAgainstBaseURL: false),
              let encodedURL = components.queryItems?.first(where: { $0.name == Self.originURLKey })?.value else {
            return nil
        }
        return URL(string: encodedURL.removingPercentEncoding ?? encodedURL)
    }

    private func playlistResponse(for originURL: URL) -> Data {
        guard let data = fetch(originURL) else {
            return httpResponse(status: "500 Internal Server Error", data: Data())
        }
        let playlist = reverseProxyPlaylist(with: data, forOriginURL: originURL)
        return httpResponse(
            status: "200 OK",
            contentType: "application/x-mpegurl",
            data: playlist
        )
    }

    private func segmentResponse(for originURL: URL) -> Data {
        let key = originURL.absoluteString
        if let cachedData = cache.data(forKey: key) {
            return httpResponse(status: "200 OK", contentType: "video/mp2t", data: cachedData)
        }
        guard let data = fetch(originURL) else {
            return httpResponse(status: "500 Internal Server Error", data: Data())
        }
        cache.store(data, forKey: key)
        return httpResponse(status: "200 OK", contentType: "video/mp2t", data: data)
    }

    private func fetch(_ url: URL) -> Data? {
        var responseData: Data?
        let semaphore = DispatchSemaphore(value: 0)
        urlSession.dataTask(with: url) { data, _, _ in
            responseData = data
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return responseData
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
