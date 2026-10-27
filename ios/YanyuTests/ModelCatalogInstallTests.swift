import Foundation
import XCTest

@testable import Yanyu

@MainActor
final class ModelCatalogInstallTests: XCTestCase {
  func testDownloadsVerifiesAndLoadsCatalogModel() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsName = "YanyuCatalogModelInstallTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }

    let candidate = try catalogCandidate(root: root, filename: "Qwen3-ASR-test.gguf")
    let modelData = candidate.data
    let model = candidate.model
    let file = candidate.file
    let download = try makeCatalogModelPackageDownload(model: model, file: file)
    let transport = CatalogInstallStubTransport(dataByURL: [download.sources[0].url: modelData])
    let store = ModelPackageStore(modelsDirectory: root.appendingPathComponent("installed"))
    let engine = CatalogInstallFakeTranscriptionEngine()
    let viewModel = DictationViewModel(
      transcriptionEngine: engine,
      modelPackageStore: store,
      modelPackageDownloadTransport: transport,
      userDefaults: defaults
    )

    await viewModel.installCatalogModel(model: model, file: file)

    let loadedModelURL = try XCTUnwrap(engine.loadedModelURL)
    XCTAssertEqual(try Data(contentsOf: loadedModelURL), modelData)
    XCTAssertTrue(loadedModelURL.path.contains("/Packages/"))
    XCTAssertEqual(defaults.string(forKey: "yanyu.ios.debug-model-path"), loadedModelURL.path)
    XCTAssertEqual(defaults.string(forKey: "yanyu.ios.debug-model-name"), "Qwen3-ASR 0.6B · test")
    XCTAssertEqual(
      defaults.string(forKey: "yanyu.ios.debug-model-package-id"),
      download.manifest.id
    )
    XCTAssertEqual(
      defaults.string(forKey: "yanyu.ios.debug-model-package-version"),
      download.manifest.version
    )
    XCTAssertTrue(viewModel.isModelLoaded)
    XCTAssertNil(viewModel.catalogModelInstallErrorKey)
    XCTAssertFalse(viewModel.isInstallingCatalogModel)
    let requestedURLs = await transport.requestedURLs()
    XCTAssertEqual(requestedURLs, [download.sources[0].url])
  }

  func testCancellingCatalogModelDownloadLeavesNoModelAndNoError() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let candidate = try catalogCandidate(root: root, filename: "Qwen3-ASR-cancel.gguf")
    let download = try makeCatalogModelPackageDownload(
      model: candidate.model,
      file: candidate.file
    )
    let transport = CatalogInstallStubTransport(
      dataByURL: [download.sources[0].url: candidate.data],
      holdsDownloadUntilCancelled: true
    )
    let engine = CatalogInstallFakeTranscriptionEngine()
    let viewModel = DictationViewModel(
      transcriptionEngine: engine,
      modelPackageStore: ModelPackageStore(
        modelsDirectory: root.appendingPathComponent("installed")),
      modelPackageDownloadTransport: transport
    )
    let installation = Task {
      await viewModel.installCatalogModel(model: candidate.model, file: candidate.file)
    }
    await transport.waitUntilDownloadStarts()

    XCTAssertTrue(viewModel.isInstallingCatalogModel)
    viewModel.cancelCatalogModelInstall()
    await installation.value

    XCTAssertFalse(viewModel.isInstallingCatalogModel)
    XCTAssertFalse(viewModel.isModelLoaded)
    XCTAssertNil(engine.loadedModelURL)
    XCTAssertNil(viewModel.catalogModelInstallErrorKey)
  }

  func testModelLoadFailureKeepsVerifiedPackageForRetry() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsName = "YanyuCatalogModelRetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let candidate = try catalogCandidate(root: root, filename: "Qwen3-ASR-retry.gguf")
    let download = try makeCatalogModelPackageDownload(
      model: candidate.model,
      file: candidate.file
    )
    let transport = CatalogInstallStubTransport(dataByURL: [download.sources[0].url: candidate.data]
    )
    let store = ModelPackageStore(modelsDirectory: root.appendingPathComponent("installed"))
    let engine = CatalogInstallFakeTranscriptionEngine()
    engine.failNextLoad = true
    let viewModel = DictationViewModel(
      transcriptionEngine: engine,
      modelPackageStore: store,
      modelPackageDownloadTransport: transport,
      userDefaults: defaults
    )

    await viewModel.installCatalogModel(model: candidate.model, file: candidate.file)

    XCTAssertFalse(viewModel.isModelLoaded)
    XCTAssertNil(defaults.string(forKey: "yanyu.ios.debug-model-path"))
    let installedPackage = try await store.resolveInstalledPackage(
      id: download.manifest.id,
      version: download.manifest.version
    )
    XCTAssertEqual(installedPackage.manifest, download.manifest)

    await viewModel.installCatalogModel(model: candidate.model, file: candidate.file)

    XCTAssertTrue(viewModel.isModelLoaded)
    XCTAssertNil(viewModel.catalogModelInstallErrorKey)
    XCTAssertNotNil(defaults.string(forKey: "yanyu.ios.debug-model-path"))
    let requestedURLs = await transport.requestedURLs()
    XCTAssertEqual(requestedURLs, [download.sources[0].url])
  }

  private func catalogCandidate(
    root: URL,
    filename: String
  ) throws -> (model: ModelDescriptor, file: QuantFile, data: Data) {
    let data = minimalGGUF(architecture: "qwen3_asr")
    let sourceFile = root.appendingPathComponent("source.gguf")
    try data.write(to: sourceFile)
    let integrity = try verifyFileIntegrity(
      path: sourceFile.path,
      expectedSizeBytes: nil,
      expectedSha256: nil
    )
    var model = try XCTUnwrap(bundledModelCatalog().first { $0.name == "Qwen3-ASR 0.6B" })
    let file = QuantFile(
      filename: filename,
      quant: "test",
      sizeBytes: integrity.sizeBytes,
      sha256: integrity.sha256
    )
    model.files = [file]
    return (model, file, data)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func minimalGGUF(architecture: String) -> Data {
    var data = Data("GGUF".utf8)
    data.appendLittleEndian(UInt32(3))
    data.appendLittleEndian(UInt64(0))
    data.appendLittleEndian(UInt64(1))
    data.appendGGUFString("general.architecture")
    data.appendLittleEndian(UInt32(8))
    data.appendGGUFString(architecture)
    return data
  }
}

private actor CatalogInstallStubTransport: ModelPackageDownloadTransport {
  private let dataByURL: [URL: Data]
  private let holdsDownloadUntilCancelled: Bool
  private var requested = [URL]()
  private var startWaiter: CheckedContinuation<Void, Never>?

  init(dataByURL: [URL: Data], holdsDownloadUntilCancelled: Bool = false) {
    self.dataByURL = dataByURL
    self.holdsDownloadUntilCancelled = holdsDownloadUntilCancelled
  }

  func download(
    from url: URL,
    to destination: URL,
    expectedSizeBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) async throws {
    requested.append(url)
    startWaiter?.resume()
    startWaiter = nil
    if holdsDownloadUntilCancelled {
      try await Task.sleep(for: .seconds(60))
    }
    guard let data = dataByURL[url], UInt64(data.count) == expectedSizeBytes else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination)
    progress(UInt64(data.count))
  }

  func requestedURLs() -> [URL] {
    requested
  }

  func waitUntilDownloadStarts() async {
    guard requested.isEmpty else {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiter = continuation
    }
  }
}

@MainActor
private final class CatalogInstallFakeTranscriptionEngine: TranscriptionEngine {
  private(set) var loadedModelURL: URL?
  var failNextLoad = false

  func loadModel(at modelURL: URL) async throws {
    if failNextLoad {
      failNextLoad = false
      throw URLError(.cannotLoadFromNetwork)
    }
    loadedModelURL = modelURL
  }

  func transcribe(
    fileAt audioURL: URL,
    language: String?,
    progress: @escaping @MainActor (TranscriptionProgress) -> Void
  ) async throws -> TranscriptionOutcome {
    TranscriptionOutcome(
      text: "",
      detectedLanguage: nil,
      audioDurationMs: 0,
      processingDurationMs: 0
    )
  }

  func cancel() {}
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
  }

  fileprivate mutating func appendGGUFString(_ value: String) {
    let bytes = Data(value.utf8)
    appendLittleEndian(UInt64(bytes.count))
    append(bytes)
  }
}
