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
        var playingFromData = false
        var mimeType: String?
        var session: URLSession?
        var headers: [AnyHashable: Any] = [:]
        var mediaData: Data?
        var response: URLResponse?
        var pendingRequests = Set<AVAssetResourceLoadingRequest>()
        weak var owner: CachingPlayerItem?

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
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

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
            owner?.delegate?.playerItem?(
                owner!,
                didDownloadBytesSoFar: mediaData?.count ?? 0,
                outOf: Int(dataTask.countOfBytesExpectedToReceive)
            )
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
                owner?.delegate?.playerItem?(owner!, downloadingFailedWith: error)
                return
            }
            processPendingRequests()
            if let owner, let mediaData {
                owner.delegate?.playerItem?(owner, didFinishDownloadingData: mediaData)
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
            let requestedOffset = Int(dataRequest.requestedOffset)
            let requestedLength = dataRequest.requestedLength
            let currentOffset = Int(dataRequest.currentOffset)

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
        resourceLoaderDelegate.headers = headers

        guard let schemeURL = url.withScheme(cachingPlayerItemScheme) else {
            fatalError("Urls without a scheme are not supported")
        }

        var urlWithCustomScheme = schemeURL
        if let customFileExtension {
            urlWithCustomScheme.deletePathExtension()
            urlWithCustomScheme.appendPathExtension(customFileExtension)
        }

        let asset = AVURLAsset(url: urlWithCustomScheme)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
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
        resourceLoaderDelegate.mediaData = data
        resourceLoaderDelegate.playingFromData = true
        resourceLoaderDelegate.mimeType = mimeType

        let asset = AVURLAsset(url: fakeURL)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: .main)
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
        if resourceLoaderDelegate.session == nil {
            resourceLoaderDelegate.startDataRequest(url: url)
        }
    }

    func stopDownload() {
        resourceLoaderDelegate.session?.invalidateAndCancel()
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        delegate?.playerItemReadyToPlay?(self)
    }

    @objc private func playbackStalledHandler() {
        delegate?.playerItemPlaybackStalled?(self)
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
