import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport metadata stays with the bytes until the decoder is selected.
struct DownloadedImage: Sendable {
    let data: Data
    let formatHint: String

    init(data: Data, url: URL, mimeType: String? = nil) {
        self.data = data
        let mime = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mime {
        case "image/svg+xml": formatHint = "svg"
        case "image/png": formatHint = "png"
        case "image/jpeg": formatHint = "jpg"
        case "image/gif": formatHint = "gif"
        case "image/webp": formatHint = "webp"
        case "image/bmp": formatHint = "bmp"
        case "image/tiff": formatHint = "tiff"
        case "image/heic": formatHint = "heic"
        case "image/heif": formatHint = "heif"
        case "application/pdf": formatHint = "pdf"
        default: formatHint = url.pathExtension.lowercased()
        }
    }
}

/// A single bounded streaming request. Cancellation also covers the interval
/// before Foundation creates its data task.
final class ImageDataDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let limit: Int
    private var data = Data()
    private var continuation: CheckedContinuation<DownloadedImage, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private let progress: (@Sendable (Data) -> Void)?
    private var reported = 0
    private init(url: URL, limit: Int, progress: (@Sendable (Data) -> Void)?) {
        self.url = url; self.limit = limit; self.progress = progress
    }

    /// `progress` receives the bytes received so far, at most once per 64 KiB,
    /// so progressive formats can show a preview before the download ends.
    static func load(url: URL, policy: ImageLoadingPolicy,
                     progress: (@Sendable (Data) -> Void)? = nil) async throws -> DownloadedImage {
        if url.isFileURL {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= policy.maximumDownloadBytes else { throw AsyncImageError.downloadTooLarge }
                try Task.checkCancellation()
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= policy.maximumDownloadBytes else { throw AsyncImageError.downloadTooLarge }
                return DownloadedImage(data: data, url: url)
            } catch let error as AsyncImageError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw AsyncImageError.fileNotFound }
            catch { throw AsyncImageError.fileReadFailed }
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AsyncImageError.unsupportedURL }
        let download = ImageDataDownload(url: url, limit: policy.maximumDownloadBytes, progress: progress)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { download.begin(timeout: policy.timeout, continuation: $0) }
        }, onCancel: { download.cancel() })
    }

    private func begin(timeout: Double, continuation: CheckedContinuation<DownloadedImage, Error>) {
        lock.lock()
        if isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: url); self.task = task
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.withLock { isCancelled = true }
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<DownloadedImage, Error>) {
        lock.lock()
        let continuation = continuation, session = session
        self.continuation = nil; self.session = nil; task = nil
        data = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(AsyncImageError.invalidResponse)); return
        }
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(AsyncImageError.httpStatus(response.statusCode))); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(AsyncImageError.downloadTooLarge)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var snapshot: Data?
        let oversized = lock.withLock { () -> Bool in
            guard continuation != nil else { return false }
            guard data.count <= limit - self.data.count else { return true }
            self.data.append(data)
            if progress != nil, self.data.count - reported >= 64 * 1_024 { reported = self.data.count; snapshot = self.data }
            return false
        }
        if oversized { finish(.failure(AsyncImageError.downloadTooLarge)) }
        else if let snapshot { progress?(snapshot) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(AsyncImageError.networkFailed(error.localizedDescription))) }
        else {
            finish(.success(DownloadedImage(data: lock.withLock { data }, url: task.response?.url ?? url,
                                           mimeType: task.response?.mimeType)))
        }
    }
}
