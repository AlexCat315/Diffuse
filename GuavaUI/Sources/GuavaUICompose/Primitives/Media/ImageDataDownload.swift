import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single bounded streaming request. Cancellation also covers the interval
/// before Foundation creates its data task.
final class ImageDataDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isCancelled = false
    init(limit: Int) { self.limit = limit }

    static func load(url: URL, policy: ImageLoadingPolicy) async throws -> Data {
        if url.isFileURL {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= policy.maximumDownloadBytes else { throw AsyncImageError.downloadTooLarge }
                try Task.checkCancellation()
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= policy.maximumDownloadBytes else { throw AsyncImageError.downloadTooLarge }
                return data
            } catch let error as AsyncImageError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw AsyncImageError.fileNotFound }
            catch { throw AsyncImageError.fileReadFailed }
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AsyncImageError.unsupportedURL }
        let download = ImageDataDownload(limit: policy.maximumDownloadBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { download.begin(url: url, timeout: policy.timeout, continuation: $0) }
        }, onCancel: { download.cancel() })
    }

    private func begin(url: URL, timeout: Double, continuation: CheckedContinuation<Data, Error>) {
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
    private func finish(_ result: Result<Data, Error>) {
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
        let oversized = lock.withLock { () -> Bool in
            guard continuation != nil else { return false }
            guard data.count <= limit - self.data.count else { return true }
            self.data.append(data); return false
        }
        if oversized { finish(.failure(AsyncImageError.downloadTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(AsyncImageError.networkFailed(error.localizedDescription))) }
        else { finish(.success(lock.withLock { data })) }
    }
}
