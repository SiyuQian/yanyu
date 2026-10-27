import Foundation
import XCTest

@testable import Yanyu

final class ModelPackageInstallerTests: XCTestCase {
  func testURLSessionTransportStreamsToTemporaryFileAndChecksSize() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticModelResponseURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = URLSessionModelPackageDownloadTransport(session: session)
    let source = URL(string: "https://models.example.test/model.bin")!
    let destination = root.appendingPathComponent("weights/model.bin")

    try await transport.download(
      from: source,
      to: destination,
      expectedSizeBytes: 5,
      progress: { _ in }
    )

    XCTAssertEqual(try Data(contentsOf: destination), Data("hello".utf8))
    do {
      try await transport.download(
        from: source,
        to: root.appendingPathComponent("wrong-size.bin"),
        expectedSizeBytes: 6,
        progress: { _ in }
      )
      XCTFail("Expected a response with the wrong size to be rejected")
    } catch {
      XCTAssertEqual(
        error as? ModelPackageDownloadTransportError,
        .downloadedSizeMismatch(expected: 6, actual: 5)
      )
    }

    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertEqual(remainingFiles, ["weights"])
  }

  func testURLSessionTransportResumesUsingStrongEntityTagAndRange() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StaticModelResponseURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = URLSessionModelPackageDownloadTransport(session: session)
    let source = URL(string: "https://models.example.test/resume.bin")!
    let destination = root.appendingPathComponent("resume.bin")
    let expectedData = Data(repeating: 0x61, count: 100_000)
    let progress = ModelPackageByteProgressRecorder()

    do {
      try await transport.download(
        from: source,
        to: destination,
        expectedSizeBytes: UInt64(expectedData.count),
        progress: { progress.append($0) }
      )
      XCTFail("Expected the first response to be incomplete")
    } catch {
      XCTAssertEqual(
        error as? ModelPackageDownloadTransportError,
        .downloadedSizeMismatch(expected: UInt64(expectedData.count), actual: 65_536)
      )
    }

    let partialFile = destination.appendingPathExtension("yanyu-partial")
    let partialAttributes = try FileManager.default.attributesOfItem(atPath: partialFile.path)
    XCTAssertEqual((partialAttributes[.size] as? NSNumber)?.uint64Value, 65_536)

    try await transport.download(
      from: source,
      to: destination,
      expectedSizeBytes: UInt64(expectedData.count),
      progress: { progress.append($0) }
    )

    XCTAssertEqual(try Data(contentsOf: destination), expectedData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partialFile.path))
    XCTAssertEqual(progress.values.last, UInt64(expectedData.count))
  }

  func testDownloadsVerifiesAndAtomicallyInstallsPackage() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let sources = packageSources()
    let downloader = StubModelPackageDownloadTransport(
      dataByURL: [sources[0].url: Data("hello".utf8), sources[1].url: Data("world".utf8)])
    let installer = ModelPackageInstaller(store: store, transport: downloader)
    let progress = ModelPackageDownloadProgressRecorder()

    let installed = try await installer.install(manifest, from: sources) { value in
      progress.append(value)
    }

    XCTAssertEqual(installed.manifest, manifest)
    XCTAssertEqual(
      try String(
        contentsOf: installed.directoryURL.appendingPathComponent("weights/model.bin"),
        encoding: .utf8),
      "hello"
    )
    let requestedURLs = await downloader.requestedURLs()
    let progressValues = progress.values
    XCTAssertEqual(requestedURLs, sources.map(\.url))
    XCTAssertEqual(progressValues.last?.completedBytes, 10)
    XCTAssertEqual(progressValues.last?.totalBytes, 10)
  }

  func testReusesVerifiedStagedFileWhenRetryingPackageInstall() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("hello", to: staging.appendingPathComponent("weights/model.bin"))
    let sources = packageSources()
    let downloader = StubModelPackageDownloadTransport(
      dataByURL: [sources[1].url: Data("world".utf8)])
    let installer = ModelPackageInstaller(store: store, transport: downloader)

    _ = try await installer.install(manifest, from: sources)

    let requestedURLs = await downloader.requestedURLs()
    XCTAssertEqual(requestedURLs, [sources[1].url])
  }

  func testRetryResumesAfterCompletedFilesAndDeletesInterruptedFile() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let sources = packageSources()
    let downloader = StubModelPackageDownloadTransport(
      dataByURL: [sources[0].url: Data("hello".utf8), sources[1].url: Data("world".utf8)])
    let installer = ModelPackageInstaller(store: store, transport: downloader)
    await downloader.failNextDownload(
      from: sources[1].url,
      afterWriting: Data("part".utf8)
    )

    do {
      _ = try await installer.install(manifest, from: sources)
      XCTFail("Expected the interrupted file download to fail")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
    }

    let staging = try await store.prepareStagingDirectory(for: manifest)
    let completedFile = staging.appendingPathComponent("weights/model.bin")
    let interruptedFile = staging.appendingPathComponent("tokenizer/vocab.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: completedFile.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedFile.path))

    _ = try await installer.install(manifest, from: sources)

    let requestedURLs = await downloader.requestedURLs()
    XCTAssertEqual(requestedURLs, [sources[0].url, sources[1].url, sources[1].url])
  }

  func testRejectsInsecureSourceBeforeCreatingStagingDirectory() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let sources = packageSources().map {
      ModelPackageDownloadSource(
        relativePath: $0.relativePath,
        url: URL(string: $0.url.absoluteString.replacingOccurrences(of: "https", with: "http"))!
      )
    }
    let downloader = StubModelPackageDownloadTransport(dataByURL: [:])
    let installer = ModelPackageInstaller(store: store, transport: downloader)

    do {
      _ = try await installer.install(packageManifest(), from: sources)
      XCTFail("Expected an insecure source URL to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageInstallerError, .insecureSourceURL)
    }

    let requestedURLs = await downloader.requestedURLs()
    XCTAssertEqual(requestedURLs, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testRejectsSourcesThatDoNotExactlyMatchManifestFiles() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let sources = [packageSources()[0]]
    let downloader = StubModelPackageDownloadTransport(dataByURL: [:])
    let installer = ModelPackageInstaller(store: store, transport: downloader)

    do {
      _ = try await installer.install(packageManifest(), from: sources)
      XCTFail("Expected missing package sources to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageInstallerError, .invalidSources)
    }

    let requestedURLs = await downloader.requestedURLs()
    XCTAssertEqual(requestedURLs, [])
  }

  func testRemovesDownloadedFileWhenHashVerificationFails() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = ModelPackageManifest(
      id: "voice-en",
      version: "1.0",
      files: [
        ModelPackageFile(
          relativePath: "weights/model.bin",
          sizeBytes: 5,
          sha256: String(repeating: "0", count: 64)
        )
      ]
    )
    let source = ModelPackageDownloadSource(
      relativePath: "weights/model.bin",
      url: URL(string: "https://models.example.test/model.bin")!
    )
    let downloader = StubModelPackageDownloadTransport(
      dataByURL: [source.url: Data("hello".utf8)])
    let installer = ModelPackageInstaller(store: store, transport: downloader)

    do {
      _ = try await installer.install(manifest, from: [source])
      XCTFail("Expected the invalid file hash to be rejected")
    } catch {
      XCTAssertEqual(
        error as? CoreError,
        .FileHashMismatch(
          expected: String(repeating: "0", count: 64),
          actual: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
      )
    }

    let stagedFile =
      root
      .appendingPathComponent(".staging", isDirectory: true)
      .appendingPathComponent("dm9pY2UtZW4", isDirectory: true)
      .appendingPathComponent("MS4w", isDirectory: true)
      .appendingPathComponent("weights/model.bin")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
  }

  private func packageManifest() -> ModelPackageManifest {
    ModelPackageManifest(
      id: "voice-en",
      version: "1.0",
      files: [
        ModelPackageFile(
          relativePath: "weights/model.bin",
          sizeBytes: 5,
          sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        ),
        ModelPackageFile(
          relativePath: "tokenizer/vocab.txt",
          sizeBytes: 5,
          sha256: "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
        ),
      ]
    )
  }

  private func packageSources() -> [ModelPackageDownloadSource] {
    [
      ModelPackageDownloadSource(
        relativePath: "weights/model.bin",
        url: URL(string: "https://models.example.test/model.bin")!
      ),
      ModelPackageDownloadSource(
        relativePath: "tokenizer/vocab.txt",
        url: URL(string: "https://models.example.test/vocab.txt")!
      ),
    ]
  }

  private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
  }

  private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }
}

private actor StubModelPackageDownloadTransport: ModelPackageDownloadTransport {
  private let dataByURL: [URL: Data]
  private var requested = [URL]()
  private var failedDownloads = [URL: Data]()

  init(dataByURL: [URL: Data]) {
    self.dataByURL = dataByURL
  }

  func download(
    from url: URL,
    to destination: URL,
    expectedSizeBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) async throws {
    requested.append(url)
    if let partialData = failedDownloads.removeValue(forKey: url) {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try partialData.write(to: destination)
      throw URLError(.networkConnectionLost)
    }
    guard let data = dataByURL[url] else {
      throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination)
    progress(UInt64(data.count))
  }

  func requestedURLs() -> [URL] {
    requested
  }

  func failNextDownload(from url: URL, afterWriting partialData: Data) {
    failedDownloads[url] = partialData
  }
}

private final class ModelPackageDownloadProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues = [ModelPackageDownloadProgress]()

  var values: [ModelPackageDownloadProgress] {
    lock.lock()
    defer { lock.unlock() }
    return recordedValues
  }

  func append(_ value: ModelPackageDownloadProgress) {
    lock.lock()
    defer { lock.unlock() }
    recordedValues.append(value)
  }
}

private final class ModelPackageByteProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues = [UInt64]()

  var values: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return recordedValues
  }

  func append(_ value: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    recordedValues.append(value)
  }
}

private final class StaticModelResponseURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
      let response = makeResponse(for: url)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if url.path == "/resume.bin" {
      let data = Data(repeating: 0x61, count: 100_000)
      if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
        let range = rangeHeader.split(separator: "=").last,
        let offsetText = range.split(separator: "-").first,
        let offset = Int(offsetText),
        offset < data.count
      {
        client?.urlProtocol(self, didLoad: Data(data.dropFirst(offset)))
        client?.urlProtocolDidFinishLoading(self)
      } else {
        client?.urlProtocol(self, didLoad: Data(data.prefix(65_536)))
        client?.urlProtocolDidFinishLoading(self)
      }
    } else {
      client?.urlProtocol(self, didLoad: Data("hello".utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private func makeResponse(for url: URL) -> HTTPURLResponse? {
    if url.path == "/resume.bin" {
      if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
        let range = rangeHeader.split(separator: "=").last,
        let offsetText = range.split(separator: "-").first,
        let offset = Int(offsetText)
      {
        let remainingBytes = 100_000 - offset
        return HTTPURLResponse(
          url: url,
          statusCode: 206,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Length": String(remainingBytes),
            "Content-Range": "bytes \(offset)-99999/100000",
            "ETag": "\"model-v1\"",
          ]
        )
      }
      return HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "65536", "ETag": "\"model-v1\""]
      )
    }
    return HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "5"]
    )
  }
}
