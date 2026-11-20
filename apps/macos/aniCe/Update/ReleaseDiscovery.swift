// SPDX-License-Identifier: GPL-3.0-or-later
// Checks GitHub releases with bounded metadata, conditional requests and an Atom fallback.
import Foundation

struct MacReleaseResponse: Sendable {
  let status: Int
  let data: Data
  let etag: String?
}

protocol MacReleaseTransport: Sendable {
  func request(_ url: URL, method: String, etag: String?) async throws -> MacReleaseResponse
}

final class MacGithubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private var redirectCount = 0
  static func allowed(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      parts.port == nil || parts.port == 443, let host = parts.host?.lowercased() else { return false }
    return ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(host)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    redirectCount += 1
    completionHandler(redirectCount <= 5 && request.url.map(Self.allowed) == true ? request : nil)
  }
}

struct MacGithubReleaseTransport: MacReleaseTransport {
  func request(_ url: URL, method: String, etag: String?) async throws -> MacReleaseResponse {
    guard MacGithubRedirects.allowed(url) else { throw URLError(.unsupportedURL) }
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: .ephemeral, delegate: MacGithubRedirects(), delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = method
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, let finalURL = http.url, MacGithubRedirects.allowed(finalURL) else { throw URLError(.badServerResponse) }
    guard method != "HEAD", http.statusCode == 200 else {
      return MacReleaseResponse(status: http.statusCode, data: Data(), etag: nil)
    }
    guard http.expectedContentLength <= 2_097_152 else { throw URLError(.dataLengthExceedsMaximum) }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 2_097_152 else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return MacReleaseResponse(status: http.statusCode, data: data, etag: http.value(forHTTPHeaderField: "ETag"))
  }
}

private final class MacAtomTags: NSObject, XMLParserDelegate {
  var versions = Set<String>()
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]) {
    guard elementName == "link", let href = attributes["href"] else { return }
    let prefix = "\(MacReleaseCatalog.root)/tag/"
    guard href.hasPrefix(prefix) else { return }
    let tag = String(href.dropFirst(prefix.count))
    if UpdateVersion.parse(tag) != nil { versions.insert(tag) }
  }
}

enum MacDiscoveryResult: Equatable {
  case available(AvailableMacRelease)
  case upToDate
  case deferred
  case failed(String)
}

@MainActor final class MacReleaseDiscovery {
  private let defaults: UserDefaults
  private let transport: any MacReleaseTransport
  private var checking = false
  init(defaults: UserDefaults = .standard, transport: any MacReleaseTransport = MacGithubReleaseTransport()) {
    self.defaults = defaults; self.transport = transport
  }
  var includeBeta: Bool {
    get { defaults.bool(forKey: "updates.includeBeta") }
    set { defaults.set(newValue, forKey: "updates.includeBeta") }
  }
  var automaticChecks: Bool {
    get { defaults.object(forKey: "updates.automaticChecks") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "updates.automaticChecks") }
  }
  func skip(_ tag: String) { defaults.set(tag, forKey: "updates.skippedTag") }

  func nextAutomaticCheck(now: Date = Date()) -> Date {
    let failures = min(max(defaults.integer(forKey: "updates.failures"), 0), 7)
    let last = defaults.double(forKey: "updates.lastAttempt")
    let success = defaults.double(forKey: "updates.lastSuccess")
    return UpdateSchedule.nextCheck(now: now, lastSuccess: success, lastAttempt: last, failures: failures)
  }

  func isEligible(_ release: AvailableMacRelease) -> Bool {
    release.version.tag != defaults.string(forKey: "updates.skippedTag") && (includeBeta || !release.version.prerelease)
  }

  func shouldNotify(_ release: AvailableMacRelease) -> Bool {
    guard automaticChecks, isEligible(release) else { return false }
    guard let previous = defaults.string(forKey: notificationKey(release)).flatMap(UpdateVersion.parse) else { return true }
    return release.version > previous
  }

  func markNotified(_ release: AvailableMacRelease) {
    defaults.set(release.version.tag, forKey: notificationKey(release))
  }

  private func notificationKey(_ release: AvailableMacRelease) -> String {
    release.version.prerelease ? "updates.notifiedPrerelease" : "updates.notifiedStable"
  }

  func cachedNotice(current: UpdateVersion) throws -> AvailableMacRelease? {
    guard let release = try cachedRelease(current: current), isEligible(release) else { return nil }
    return release
  }

  func check(current: UpdateVersion, force: Bool = false, now: Date = Date()) async -> MacDiscoveryResult {
    guard !Task.isCancelled else { return .deferred }
    guard force || automaticChecks else { return .deferred }
    guard !checking else { return .deferred }
    checking = true; defer { checking = false }
    let failures = min(max(defaults.integer(forKey: "updates.failures"), 0), 7)
    let time = now.timeIntervalSince1970
    if !force, now < nextAutomaticCheck(now: now) {
      do {
        if let release = try cachedRelease(current: current) {
          return isEligible(release) ? .available(release) : .deferred
        }
        let source = defaults.string(forKey: "updates.lastSource")
        if failures == 0, defaults.double(forKey: "updates.lastSuccess") > 0,
          source == "atom" || (source == "api" && defaults.data(forKey: "updates.cachedReleases") != nil) {
          return .upToDate
        }
      } catch {
        return .deferred
      }
      return .deferred
    }
    defaults.set(time, forKey: "updates.lastAttempt")
    do {
      let endpoint = URL(string: "https://api.github.com/repos/anisharyal09/aniCe/releases?per_page=100")!
      var response = try await transport.request(endpoint, method: "GET", etag: defaults.string(forKey: "updates.etag"))
      try Task.checkCancellation()
      if response.status == 304, defaults.data(forKey: "updates.cachedReleases") == nil {
        defaults.removeObject(forKey: "updates.etag")
        response = try await transport.request(endpoint, method: "GET", etag: nil)
        try Task.checkCancellation()
      }
      let release: AvailableMacRelease?
      switch response.status {
      case 200:
        release = try MacReleaseCatalog.fromJSON(response.data, current: current, includeBeta: includeBeta)
        try Task.checkCancellation()
        defaults.set(response.data, forKey: "updates.cachedReleases")
        defaults.set(response.etag, forKey: "updates.etag")
        defaults.set("api", forKey: "updates.lastSource")
      case 304:
        guard let data = defaults.data(forKey: "updates.cachedReleases") else { throw URLError(.cannotDecodeContentData) }
        release = try MacReleaseCatalog.fromJSON(data, current: current, includeBeta: includeBeta)
        try Task.checkCancellation()
        defaults.set("api", forKey: "updates.lastSource")
      case 403, 429:
        release = try await fromAtom(current: current)
        try Task.checkCancellation()
        defaults.set("atom", forKey: "updates.lastSource")
        defaults.set(release?.version.tag, forKey: "updates.atomTag")
      default: throw NSError(domain: "aniCe.Update", code: response.status, userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(response.status)"])
      }
      try Task.checkCancellation()
      defaults.set(0, forKey: "updates.failures")
      defaults.set(time, forKey: "updates.lastSuccess")
      if let release, release.version.tag != defaults.string(forKey: "updates.skippedTag") { return .available(release) }
      return .upToDate
    } catch is CancellationError {
      return .deferred
    } catch {
      if Task.isCancelled { return .deferred }
      defaults.set(min(failures + 1, 7), forKey: "updates.failures")
      return .failed(error.localizedDescription)
    }
  }

  private func cachedRelease(current: UpdateVersion) throws -> AvailableMacRelease? {
    if defaults.string(forKey: "updates.lastSource") == "api", let data = defaults.data(forKey: "updates.cachedReleases") {
      return try MacReleaseCatalog.fromJSON(data, current: current, includeBeta: includeBeta)
    }
    guard let tag = defaults.string(forKey: "updates.atomTag"), let version = UpdateVersion.parse(tag),
      version > current, includeBeta || !version.prerelease else { return nil }
    return AvailableMacRelease(version: version, notes: "Release notes are available on GitHub.", assetURL: MacReleaseCatalog.assetURL(version), assetBytes: nil)
  }

  private func fromAtom(current: UpdateVersion) async throws -> AvailableMacRelease? {
    let response = try await transport.request(URL(string: "\(MacReleaseCatalog.root).atom")!, method: "GET", etag: nil)
    try Task.checkCancellation()
    guard response.status == 200 else { throw URLError(.badServerResponse) }
    guard let xml = String(data: response.data, encoding: .utf8), !xml.contains("\0"),
      !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw URLError(.cannotDecodeContentData) }
    let tags = MacAtomTags(), parser = XMLParser(data: response.data)
    parser.delegate = tags; parser.shouldResolveExternalEntities = false
    guard parser.parse() else { throw URLError(.cannotDecodeContentData) }
    let versions = tags.versions.compactMap(UpdateVersion.parse).sorted(by: >)
    for version in versions where version > current && (includeBeta || !version.prerelease) {
      let asset = MacReleaseCatalog.assetURL(version)
      let status = try await transport.request(asset, method: "HEAD", etag: nil).status
      try Task.checkCancellation()
      if status == 200 {
        return AvailableMacRelease(version: version, notes: "Release notes are available on GitHub.", assetURL: asset, assetBytes: nil)
      }
    }
    return nil
  }
}
