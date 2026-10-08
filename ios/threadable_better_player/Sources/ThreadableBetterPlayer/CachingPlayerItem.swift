import AVFoundation
import Foundation

private extension URL {
    func withScheme(_ scheme: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }
}

@objc protocol CachingPlayerItemDelegate: AnyObject {
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data)
    @objc optional func playerItem(
        _ playerItem: CachingPlayerItem,
        didDownloadBytesSoFar bytesDownloaded: Int,
        outOf bytesExpected: Int
    )
    @objc optional func playerItemReadyToPlay(_ playerItem: CachingPlayerItem)
    @objc optional func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem)
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error)
}

final class CachingPlayerItem: AVPlayerItem {
    final class ResourceLoaderDelegate: NSObject,
        AVAssetResourceLoaderDelegate,
        URLSessionDelegate,
        URLSessionDataDelegate,
        URLSessionTaskDelegate
    {
        let stateQueue = DispatchQueue(
            label: "io.threadable.betterplayer.resource-loader",
            qos: .utility
        )

        private let sessionDelegateQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        var playingFromData = false
        var mimeType: String?
        var session: URLSession?
        var headers: [AnyHashable: Any] = [:]
        var mediaData: Data?
        var response: URLResponse?
        var pendingRequests = Set<AVAssetResourceLoadingRequest>()
        weak var owner: CachingPlayerItem?

        override init() {
            super.init()
            sessionDelegateQueue.underlyingQueue = stateQueue
        }

        func configure(headers: [AnyHashable: Any]) {
            stateQueue.sync {
                self.headers = headers
            }
        }

        func configure(data: Data, mimeType: String) {
            stateQueue.sync {
                mediaData = data
                playingFromData = true
                self.mimeType = mimeType
            }
        }

        func resourceLoader(
            _ resourceLoader: AVAssetResourceLoader,
            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
        ) -> Bool {
            if !playingFromData && session == nil {
                guard let initialURL = owner?.url else {
                    assertionFailure("Missing media URL")
                    return false
                }
                startDataRequest(url: initialURL)
            }
            pendingRequests.insert(loadingRequest)
            processPendingRequests()
            return true
        }

        func startDataRequest(url: URL) {
            guard session == nil else {
                return
            }

            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: sessionDelegateQueue
            )

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            for (key, value) in headers {
                guard let headerKey = key as? String,
                      let headerValue = value as? String else {
                    continue
                }
                request.setValue(headerValue, forHTTPHeaderField: headerKey)
            }
            session?.dataTask(with: request).resume()
        }

        func resourceLoader(
            _ resourceLoader: AVAssetResourceLoader,
            didCancel loadingRequest: AVAssetResourceLoadingRequest
        ) {
            pendingRequests.remove(loadingRequest)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            mediaData?.append(data)
            processPendingRequests()
            let bytesDownloaded = mediaData?.count ?? 0
            let bytesExpected = Int(dataTask.countOfBytesExpectedToReceive)
            notifyOnMain { delegate, owner in
                delegate.playerItem?(
                    owner,
                    didDownloadBytesSoFar: bytesDownloaded,
                    outOf: bytesExpected
                )
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            completionHandler(.allow)
            mediaData = Data()
            self.response = response
            processPendingRequests()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                notifyOnMain { delegate, owner in
                    delegate.playerItem?(owner, downloadingFailedWith: error)
                }
                self.session = nil
                return
            }
            processPendingRequests()
            if let mediaData {
                notifyOnMain { delegate, owner in
                    delegate.playerItem?(owner, didFinishDownloadingData: mediaData)
                }
            }
            self.session = nil
        }

        private func notifyOnMain(
            _ callback: @escaping (CachingPlayerItemDelegate, CachingPlayerItem) -> Void
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner, let delegate = owner.delegate else {
                    return
                }
                callback(delegate, owner)
            }
        }

        func processPendingRequests() {
            let fulfilledRequests: [AVAssetResourceLoadingRequest] = pendingRequests.compactMap { request in
                fillInContentInformationRequest(request.contentInformationRequest)
                guard let dataRequest = request.dataRequest,
                      haveEnoughDataToFulfillRequest(dataRequest) else {
                    return nil
                }
                request.finishLoading()
                return request
            }
            for request in fulfilledRequests {
                pendingRequests.remove(request)
            }
        }

        func fillInContentInformationRequest(
            _ contentInformationRequest: AVAssetResourceLoadingContentInformationRequest?
        ) {
            if playingFromData {
                contentInformationRequest?.contentType = mimeType
                contentInformationRequest?.contentLength = Int64(mediaData?.count ?? 0)
                contentInformationRequest?.isByteRangeAccessSupported = true
                return
            }

            guard let response else {
                return
            }

            contentInformationRequest?.contentType = response.mimeType
            contentInformationRequest?.contentLength = response.expectedContentLength
            contentInformationRequest?.isByteRangeAccessSupported = true
        }

        func haveEnoughDataToFulfillRequest(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
            guard dataRequest.requestedOffset >= 0,
                  dataRequest.currentOffset >= 0,
                  let requestedOffset = Int(exactly: dataRequest.requestedOffset),
                  let currentOffset = Int(exactly: dataRequest.currentOffset) else {
                return false
            }
            let requestedLength = dataRequest.requestedLength

            guard let mediaData, mediaData.count > currentOffset else {
                return false
            }

            let bytesToRespond = min(mediaData.count - currentOffset, requestedLength)
            let range = currentOffset..<(currentOffset + bytesToRespond)
            dataRequest.respond(with: mediaData.subdata(in: range))
            return mediaData.count >= requestedLength + requestedOffset
        }

        deinit {
            session?.invalidateAndCancel()
        }
    }

    private let resourceLoaderDelegate = ResourceLoaderDelegate()
    let url: URL
    var cacheKey: String?
    weak var delegate: CachingPlayerItemDelegate?

    private let cachingPlayerItemScheme = "cachingPlayerItemScheme"

    convenience init(url: URL, cacheKey: String?, headers: [AnyHashable: Any]) {
        self.init(url: url, customFileExtension: nil, cacheKey: cacheKey, headers: headers)
    }

    init(url: URL, customFileExtension: String?, cacheKey: String?, headers: [AnyHashable: Any]) {
        self.cacheKey = cacheKey
        self.url = url
        resourceLoaderDelegate.configure(headers: headers)

        guard let schemeURL = url.withScheme(cachingPlayerItemScheme) else {
            fatalError("Urls without a scheme are not supported")
        }

        var urlWithCustomScheme = schemeURL
        if let customFileExtension {
            urlWithCustomScheme.deletePathExtension()
            urlWithCustomScheme.appendPathExtension(customFileExtension)
        }

        let asset = AVURLAsset(url: urlWithCustomScheme)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: resourceLoaderDelegate.stateQueue)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        resourceLoaderDelegate.owner = self
        addObserver(self, forKeyPath: "status", options: .new, context: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStalledHandler),
            name: .AVPlayerItemPlaybackStalled,
            object: self
        )
    }

    init(data: Data, mimeType: String, fileExtension: String) {
        guard let fakeURL = URL(string: "\(cachingPlayerItemScheme)://whatever/file.\(fileExtension)") else {
            fatalError("internal inconsistency")
        }

        self.url = fakeURL
        resourceLoaderDelegate.configure(data: data, mimeType: mimeType)

        let asset = AVURLAsset(url: fakeURL)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: resourceLoaderDelegate.stateQueue)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        resourceLoaderDelegate.owner = self
        addObserver(self, forKeyPath: "status", options: .new, context: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStalledHandler),
            name: .AVPlayerItemPlaybackStalled,
            object: self
        )
    }

    func download() {
        resourceLoaderDelegate.stateQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.resourceLoaderDelegate.startDataRequest(url: self.url)
        }
    }

    func stopDownload() {
        resourceLoaderDelegate.stateQueue.async { [weak self] in
            self?.resourceLoaderDelegate.session?.invalidateAndCancel()
            self?.resourceLoaderDelegate.session = nil
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.delegate?.playerItemReadyToPlay?(self)
        }
    }

    @objc private func playbackStalledHandler() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.delegate?.playerItemPlaybackStalled?(self)
        }
    }

    @available(*, unavailable)
    override init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]?) {
        fatalError("not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeObserver(self, forKeyPath: "status")
        resourceLoaderDelegate.session?.invalidateAndCancel()
    }
}
