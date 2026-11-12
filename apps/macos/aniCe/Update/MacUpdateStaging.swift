// SPDX-License-Identifier: GPL-3.0-or-later
// Downloads and verifies an update in a private directory on the destination volume.
import Darwin
import Foundation

enum MacUpdateStaging {
  enum Error: LocalizedError {
    case invalidDownload, invalidBundle, extractionFailed, stagingUnavailable

    var errorDescription: String? {
      switch self {
      case .invalidDownload:
        return "The update download was incomplete or invalid. Try again."
      case .invalidBundle:
        return "The downloaded app is not a valid aniCe release. Open the release on GitHub to install manually."
      case .extractionFailed:
        return "The update could not be unpacked. Try again or install the update manually."
      case .stagingUnavailable:
        return "aniCe cannot write beside the app in this folder. Move aniCe to Applications or install the update manually."
      }
    }
  }
  struct Prepared: Sendable {
    let directory: URL
    let bundle: URL
  }

  static func checkLength(_ received: Int64, advertised: Int64?, expected: Int64?, complete: Bool) throws {
    guard received >= 0, received <= MacReleaseCatalog.maxBytes,
      advertised == nil || (1...MacReleaseCatalog.maxBytes).contains(advertised!),
      expected == nil || (1...MacReleaseCatalog.maxBytes).contains(expected!),
      advertised == nil || expected == nil || advertised == expected else { throw Error.invalidDownload }
    if complete {
      guard received > 0, advertised == nil || received == advertised,
        expected == nil || received == expected else { throw Error.invalidDownload }
    }
  }

  // Only abandoned staging owned by this user is removed; an active helper updates its record.
  static func removeStale(in parent: URL) {
    let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.lastPathComponent.hasPrefix(".aniCe-update-") {
      let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
      guard (attributes?[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
        let modified = attributes?[.modificationDate] as? Date,
        modified < Date().addingTimeInterval(-86_400) else { continue }
      try? FileManager.default.removeItem(at: item)
    }
  }

  static func prepare(_ release: AvailableMacRelease, beside destination: URL, pins: Set<String>,
    progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws -> Prepared {
    guard release.assetURL == MacReleaseCatalog.assetURL(release.version),
      MacGithubRedirects.allowed(release.assetURL), !pins.isEmpty else { throw Error.invalidDownload }
    let parent = destination.deletingLastPathComponent()
    removeStale(in: parent)
    let directory = parent.appendingPathComponent(".aniCe-update-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(directory.path, 0o700) == 0 else { throw Error.stagingUnavailable }
    do {
      let archive = directory.appendingPathComponent("update.zip")
      var request = URLRequest(url: release.assetURL, timeoutInterval: 60)
      request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
      try await MacUpdateDownload(destination: archive, expected: release.assetBytes, progress: progress).start(request)
      try Task.checkCancellation()
      try MacUpdateArchive.validate(archive)
      let extract = Process()
      extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      extract.arguments = ["-x", "-k", archive.path, directory.path]
      extract.standardOutput = FileHandle.nullDevice; extract.standardError = FileHandle.nullDevice
      try extract.run(); extract.waitUntilExit()
      guard extract.terminationReason == .exit, extract.terminationStatus == 0 else { throw Error.extractionFailed }
      try Task.checkCancellation()
      let bundle = directory.appendingPathComponent("aniCe.app", isDirectory: true)
      let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
      guard let info = NSDictionary(contentsOf: infoURL),
        info["CFBundleIdentifier"] as? String == "io.github.anisharyal09.anice",
        info["CFBundleShortVersionString"] as? String == String(release.version.tag.dropFirst()),
        info["CFBundleVersion"] as? String == String(release.version.code) else { throw Error.invalidBundle }
      try MacUpdateSignature.validate(bundle, identifier: "io.github.anisharyal09.anice", pins: pins)
      try FileManager.default.removeItem(at: archive)
      return Prepared(directory: directory, bundle: bundle)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}

// A download task streams to disk in URLSession-sized chunks; iterating AsyncBytes one byte at a
// time adds avoidable per-byte overhead to a release download.
final class MacUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let expected: Int64?
  private let configuration: URLSessionConfiguration
  private let progress: @Sendable (Int64, Int64?) async -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var finished = false
  private var redirects = 0

  init(destination: URL, expected: Int64?, configuration: URLSessionConfiguration = .ephemeral,
    progress: @escaping @Sendable (Int64, Int64?) async -> Void) {
    self.destination = destination
    self.expected = expected
    self.configuration = configuration
    self.progress = progress
  }

  func start(_ request: URLRequest) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.downloadTask(with: request)
        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        let cancelled = Task.isCancelled
        lock.unlock()
        if cancelled { finish(.failure(CancellationError())) } else { task.resume() }
      }
    } onCancel: {
      lock.lock()
      let task = self.task
      lock.unlock()
      task?.cancel()
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let continuation = self.continuation
    let session = self.session
    self.continuation = nil; self.session = nil; self.task = nil
    lock.unlock()
    session?.invalidateAndCancel()
    switch result {
    case .success: continuation?.resume()
    case .failure(let error): continuation?.resume(throwing: error)
    }
  }

  private func currentExpected(_ advertised: Int64) -> Int64? {
    expected ?? (advertised >= 0 ? advertised : nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    redirects += 1
    completionHandler(redirects <= 5 && request.url.map(MacGithubRedirects.allowed) == true ? request : nil)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let advertised = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
    do {
      try MacUpdateStaging.checkLength(totalBytesWritten, advertised: advertised, expected: expected, complete: false)
    } catch {
      finish(.failure(error)); downloadTask.cancel(); return
    }
    let total = currentExpected(totalBytesExpectedToWrite)
    Task { await progress(totalBytesWritten, total) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    lock.lock(); let alreadyFinished = finished; lock.unlock()
    guard !alreadyFinished else { return }
    guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200,
      let final = http.url, MacGithubRedirects.allowed(final) else {
      finish(.failure(MacUpdateStaging.Error.invalidDownload)); return
    }
    do {
      let advertised = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
        throw MacUpdateStaging.Error.invalidDownload
      }
      try MacUpdateStaging.checkLength(size, advertised: advertised, expected: expected, complete: true)
      try FileManager.default.copyItem(at: location, to: destination)
      let fd = open(destination.path, O_RDONLY | O_NOFOLLOW)
      if fd >= 0 { fsync(fd); close(fd) }
      finish(.success(()))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else {
      finish(.failure(MacUpdateStaging.Error.invalidDownload)); return
    }
    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
      finish(.failure(CancellationError()))
    } else {
      finish(.failure(error))
    }
  }
}
