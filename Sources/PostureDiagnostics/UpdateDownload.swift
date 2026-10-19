import Foundation

/// A delegate-backed download preserves intermediate byte callbacks; completion-handler
/// downloads (including the async convenience API) suppress those callbacks on macOS.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var cancelled = false
    private var savedFile: URL?
    private var stagingError: Error?

    private init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration,
                      progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        let delegate = UpdateDownload(progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        }, onCancel: { delegate.cancel() })
    }
    private func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        self.continuation = continuation; downloadTask = task
        let wasCancelled = cancelled
        lock.unlock()
        task.resume()
        if wasCancelled { task.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = downloadTask; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes its temporary file as soon as this delegate method returns.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kukusit-download-\(UUID()).zip")
        do {
            try FileManager.default.moveItem(at: location, to: file)
            lock.lock(); savedFile = file; lock.unlock()
        } catch {
            lock.lock(); stagingError = error; lock.unlock()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation, file = savedFile
        let failure: Error? = cancelled ? CancellationError() : error ?? stagingError
        self.continuation = nil; savedFile = nil; downloadTask = nil
        lock.unlock()
        guard let continuation else { return }
        if let failure {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: failure)
        } else if let file, let response = task.response {
            continuation.resume(returning: (file, response))
        } else {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}
