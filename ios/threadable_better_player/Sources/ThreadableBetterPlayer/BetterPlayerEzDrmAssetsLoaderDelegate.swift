import AVFoundation
import Foundation

final class BetterPlayerEzDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private static let defaultLicenseServerURL = URL(string: "https://fps.ezdrm.com/api/licenses/")!

    private let certificateURL: URL
    private let licenseURL: URL?

    init(certificateURL: URL, licenseURL: URL?) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        super.init()
    }

    private func appCertificate() throws -> Data {
        try Data(contentsOf: certificateURL)
    }

    private func contentKey(
        requestBytes: Data,
        assetId: String,
        customParams: String
    ) -> Data? {
        let baseURL = licenseURL ?? Self.defaultLicenseServerURL
        guard let keyServerURL = URL(string: "\(baseURL)\(assetId)\(customParams)") else {
            return nil
        }

        var request = URLRequest(url: keyServerURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-type")
        request.httpBody = requestBytes

        var responseData: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            responseData = data
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return responseData
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let assetURL = loadingRequest.request.url,
              assetURL.scheme == "skd" else {
            return false
        }

        let absoluteString = assetURL.absoluteString
        let assetId = String(absoluteString.suffix(36))

        let certificate: Data
        do {
            certificate = try appCertificate()
        } catch {
            loadingRequest.finishLoading(
                with: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorClientCertificateRejected
                )
            )
            return true
        }

        let requestBytes: Data
        do {
            requestBytes = try loadingRequest.streamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: Data(absoluteString.utf8),
                options: nil
            )
        } catch {
            loadingRequest.finishLoading(with: nil)
            return true
        }

        let customParams = "?customdata=\(assetId)"
        let responseData = contentKey(
            requestBytes: requestBytes,
            assetId: assetId,
            customParams: customParams
        )

        if let responseData {
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        } else {
            loadingRequest.finishLoading(with: nil)
        }
        return true
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
