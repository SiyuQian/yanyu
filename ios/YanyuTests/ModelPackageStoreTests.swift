import Foundation
import XCTest

@testable import Yanyu

final class ModelPackageStoreTests: XCTestCase {
  func testPersistsTheSharedCoreDescriptorAsThePackageManifest() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let descriptor = ModelPackageDescriptor(
      id: "voice-en",
      version: "1.0",
      files: [
        ModelPackageArtifact(
          relativePath: "weights/model.bin",
          sizeBytes: 5,
          sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
      ]
    )

    let staging = try await store.prepareStagingDirectory(for: descriptor)
    let manifestURL = staging.appendingPathComponent(".yanyu-package-manifest.json")
    let serializedManifest = try Data(contentsOf: manifestURL)
    let restoredDescriptor = try JSONDecoder().decode(
      ModelPackageDescriptor.self,
      from: serializedManifest
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: serializedManifest) as? [String: Any])
    let files = try XCTUnwrap(object["files"] as? [[String: Any]])

    XCTAssertEqual(restoredDescriptor, descriptor)
    XCTAssertEqual(files.first?["relativePath"] as? String, "weights/model.bin")
    XCTAssertEqual(files.first?["sizeBytes"] as? UInt64, 5)
    XCTAssertNil(files.first?["relative_path"])
  }

  func testRejectsPathTraversalBeforeCreatingStagingDirectory() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = ModelPackageManifest(
      id: "voice-en",
      version: "1.0",
      files: [
        ModelPackageFile(
          relativePath: "../outside.bin",
          sizeBytes: 5,
          sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
      ]
    )

    do {
      _ = try await store.prepareStagingDirectory(for: manifest)
      XCTFail("Expected the unsafe relative path to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageStoreError, .invalidManifest)
    }

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.bin").path))
  }

  func testReusesMatchingStagingDirectoryAndRejectsChangedManifest() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    let partialFile = staging.appendingPathComponent("weights/model.bin")
    try FileManager.default.createDirectory(
      at: partialFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("partial".utf8).write(to: partialFile)

    let resumedStaging = try await store.prepareStagingDirectory(for: manifest)
    XCTAssertEqual(resumedStaging, staging)
    XCTAssertEqual(try Data(contentsOf: partialFile), Data("partial".utf8))

    let changedManifest = ModelPackageManifest(
      id: manifest.id,
      version: manifest.version,
      files: [
        ModelPackageFile(
          relativePath: "weights/model.bin",
          sizeBytes: 6,
          sha256: "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
        )
      ]
    )
    do {
      _ = try await store.prepareStagingDirectory(for: changedManifest)
      XCTFail("Expected a changed manifest to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageStoreError, .stagingManifestMismatch)
    }
  }

  func testRejectsNonemptyStagingDirectoryWithoutItsManifest() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try FileManager.default.removeItem(
      at: staging.appendingPathComponent(".yanyu-package-manifest.json")
    )
    let unexpectedFile = staging.appendingPathComponent("unexpected.bin")
    try Data("untrusted".utf8).write(to: unexpectedFile)

    do {
      _ = try await store.prepareStagingDirectory(for: manifest)
      XCTFail("Expected a nonempty staging directory without its manifest to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageStoreError, .stagingManifestMismatch)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: unexpectedFile.path))
  }

  func testCommitsVerifiedMultiFilePackageAndExcludesItFromBackup() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("hello", to: staging.appendingPathComponent("weights/model.bin"))
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))

    let installed = try await store.commit(manifest, from: staging)

    XCTAssertEqual(installed.manifest, manifest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertEqual(
      try String(
        contentsOf: installed.directoryURL.appendingPathComponent("weights/model.bin"),
        encoding: .utf8),
      "hello"
    )
    let values = try installed.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testKeepsStagingWhenFileIntegrityCheckFails() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("wrong", to: staging.appendingPathComponent("weights/model.bin"))
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))

    do {
      _ = try await store.commit(manifest, from: staging)
      XCTFail("Expected the mismatched model file to be rejected")
    } catch {
      XCTAssertEqual(
        error as? CoreError,
        .FileHashMismatch(
          expected: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
          actual: "8810ad581e59f2bc3928b261707a71308f7e139eb04820366dc4d5c18d980225"
        )
      )
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
  }

  func testResolvesInstalledPackageFromItsManifest() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("hello", to: staging.appendingPathComponent("weights/model.bin"))
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))
    let installed = try await store.commit(manifest, from: staging)

    let resolved = try await store.resolveInstalledPackage(
      id: manifest.id, version: manifest.version)

    XCTAssertEqual(resolved, installed)
  }

  func testRejectsInstalledPackageWhenAssetSizeChanges() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("hello", to: staging.appendingPathComponent("weights/model.bin"))
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))
    let installed = try await store.commit(manifest, from: staging)
    try write("tampered", to: installed.directoryURL.appendingPathComponent("weights/model.bin"))

    do {
      _ = try await store.resolveInstalledPackage(id: manifest.id, version: manifest.version)
      XCTFail("Expected the modified installed asset to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageStoreError, .installedPackageMismatch)
    }
  }

  func testRejectsSymbolicLinkInsteadOfVerifyingItsTarget() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    let outsideFile = root.appendingPathComponent("outside.bin")
    try write("hello", to: outsideFile)
    let modelFile = staging.appendingPathComponent("weights/model.bin")
    try FileManager.default.createDirectory(
      at: modelFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: modelFile, withDestinationURL: outsideFile)
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))

    do {
      _ = try await store.commit(manifest, from: staging)
      XCTFail("Expected symbolic links to be rejected")
    } catch {
      XCTAssertEqual(error as? ModelPackageStoreError, .invalidStagedFile)
    }
  }

  func testRemovesOnlyTheInstalledPackage() async throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelPackageStore(modelsDirectory: root)
    let manifest = packageManifest()
    let staging = try await store.prepareStagingDirectory(for: manifest)
    try write("hello", to: staging.appendingPathComponent("weights/model.bin"))
    try write("world", to: staging.appendingPathComponent("tokenizer/vocab.txt"))
    let installed = try await store.commit(manifest, from: staging)

    try await store.remove(id: manifest.id, version: manifest.version)

    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.directoryURL.path))
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
