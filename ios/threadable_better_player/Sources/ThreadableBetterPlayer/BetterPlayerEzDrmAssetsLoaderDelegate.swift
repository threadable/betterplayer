import AVFoundation
import Foundation

final class BetterPlayerEzDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private static let defaultLicenseServerURL = URL(string: "https://fps.ezdrm.com/api/licenses/")!

    private let certificateURL: URL
    private let licenseURL: URL?
    private let callbackQueue: DispatchQueue
    private let session: URLSession
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var cancelledRequestIds = Set<ObjectIdentifier>()

    init(certificateURL: URL, licenseURL: URL?, callbackQueue: DispatchQueue) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.callbackQueue = callbackQueue
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func appCertificate() throws -> Data {
        try Data(contentsOf: certificateURL)
    }

    private func contentKeyRequest(
        requestBytes: Data,
        assetId: String,
        customParams: String,
        requestId: ObjectIdentifier,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        let baseURL = licenseURL ?? Self.defaultLicenseServerURL
        guard let keyServerURL = URL(string: "\(baseURL)\(assetId)\(customParams)") else {
            completion(nil, URLError(.badURL))
            return
        }

        var request = URLRequest(url: keyServerURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-type")
        request.httpBody = requestBytes
        request.timeoutInterval = 30

        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                completion(nil, error ?? URLError(.badServerResponse))
                return
            }
            completion(data, nil)
        }
        callbackQueue.async { [weak self] in
            guard let self else {
                return
            }
            if self.cancelledRequestIds.remove(requestId) != nil {
                task.cancel()
                return
            }
            self.tasks[requestId] = task
            task.resume()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let assetURL = loadingRequest.request.url,
              assetURL.scheme == "skd" else {
            return false
        }

        let requestId = ObjectIdentifier(loadingRequest)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }
            let absoluteString = assetURL.absoluteString
            let assetId = String(absoluteString.suffix(36))
            do {
                let certificate = try self.appCertificate()
                let requestBytes = try loadingRequest.streamingContentKeyRequestData(
                    forApp: certificate,
                    contentIdentifier: Data(absoluteString.utf8),
                    options: nil
                )
                let customParams = "?customdata=\(assetId)"
                self.contentKeyRequest(
                    requestBytes: requestBytes,
                    assetId: assetId,
                    customParams: customParams,
                    requestId: requestId
                ) { [weak self] responseData, error in
                    guard let self else {
                        return
                    }
                    self.callbackQueue.async {
                        self.tasks.removeValue(forKey: requestId)
                        let wasCancelled = self.cancelledRequestIds.remove(requestId) != nil
                        guard !wasCancelled else {
                            return
                        }
                        if let responseData, error == nil {
                            loadingRequest.dataRequest?.respond(with: responseData)
                            loadingRequest.finishLoading()
                        } else {
                            loadingRequest.finishLoading(with: error)
                        }
                    }
                }
            } catch {
                self.callbackQueue.async {
                    self.tasks.removeValue(forKey: requestId)
                    let wasCancelled = self.cancelledRequestIds.remove(requestId) != nil
                    guard !wasCancelled else {
                        return
                    }
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestId = ObjectIdentifier(loadingRequest)
        callbackQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.cancelledRequestIds.insert(requestId)
            self.tasks.removeValue(forKey: requestId)?.cancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        return self.resourceLoader(
            resourceLoader,
            shouldWaitForLoadingOfRequestedResource: renewalRequest
        )
    }
}
