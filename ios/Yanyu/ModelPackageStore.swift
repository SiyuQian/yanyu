import Darwin
import Foundation

typealias ModelPackageFile = ModelPackageArtifact
typealias ModelPackageManifest = ModelPackageDescriptor

struct InstalledModelPackage: Equatable, Sendable {
  let manifest: ModelPackageManifest
  let directoryURL: URL
}

enum ModelPackageStoreError: Error, Equatable {
  case invalidManifest
  case stagingManifestMismatch
  case invalidStagedFile
  case alreadyInstalled
  case packageNotInstalled
  case installedPackageMismatch
}

actor ModelPackageStore {
  private static let manifestFilename = ".yanyu-package-manifest.json"
  private let modelsDirectory: URL
  private let fileManager = FileManager.default

  init(modelsDirectory: URL) {
    self.modelsDirectory = modelsDirectory.standardizedFileURL
  }

  static func applicationStore() throws -> ModelPackageStore {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return ModelPackageStore(
      modelsDirectory: applicationSupport.appendingPathComponent("Models", isDirectory: true)
    )
  }

  func prepareStagingDirectory(for manifest: ModelPackageManifest) throws -> URL {
    try validate(manifest)
    try ensureDirectory(modelsDirectory)
    try excludeFromBackup(modelsDirectory)

    let stagingRoot = modelsDirectory.appendingPathComponent(".staging", isDirectory: true)
    let stagingDirectory = packageDirectory(for: manifest, under: stagingRoot)
    try ensureDirectory(stagingRoot)
    try ensureDirectory(stagingDirectory.deletingLastPathComponent())
    try ensureDirectory(stagingDirectory)
    try excludeFromBackup(stagingRoot)
    try excludeFromBackup(stagingDirectory)

    let manifestURL = stagingDirectory.appendingPathComponent(Self.manifestFilename)
    if pathExists(manifestURL) {
      guard isRegularFile(manifestURL),
        let stagedManifest = try? JSONDecoder().decode(
          ModelPackageManifest.self,
          from: Data(contentsOf: manifestURL)
        ),
        stagedManifest == manifest
      else {
        throw ModelPackageStoreError.stagingManifestMismatch
      }
      return stagingDirectory
    }

    guard try fileManager.contentsOfDirectory(atPath: stagingDirectory.path).isEmpty else {
      throw ModelPackageStoreError.stagingManifestMismatch
    }
    let data = try JSONEncoder.sorted.encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
    return stagingDirectory
  }

  func commit(
    _ manifest: ModelPackageManifest,
    from stagingDirectory: URL
  ) async throws -> InstalledModelPackage {
    try Task.checkCancellation()
    try validate(manifest)

    let expectedStagingDirectory = packageDirectory(
      for: manifest,
      under: modelsDirectory.appendingPathComponent(".staging", isDirectory: true)
    )
    guard stagingDirectory.standardizedFileURL.path == expectedStagingDirectory.path else {
      throw ModelPackageStoreError.invalidStagedFile
    }
    try validateStagingManifest(manifest, at: expectedStagingDirectory)

    for file in manifest.files {
      try Task.checkCancellation()
      let fileURL = try stagedFileURL(for: file, under: expectedStagingDirectory)
      _ = try verifyFileIntegrity(
        path: fileURL.path,
        expectedSizeBytes: file.sizeBytes,
        expectedSha256: file.sha256
      )
    }
    try Task.checkCancellation()

    let packagesRoot = modelsDirectory.appendingPathComponent("Packages", isDirectory: true)
    let destination = packageDirectory(for: manifest, under: packagesRoot)
    try ensureDirectory(packagesRoot)
    try ensureDirectory(destination.deletingLastPathComponent())
    guard !pathExists(destination) else {
      throw ModelPackageStoreError.alreadyInstalled
    }

    try fileManager.moveItem(at: expectedStagingDirectory, to: destination)
    return InstalledModelPackage(manifest: manifest, directoryURL: destination)
  }

  func remove(id: String, version: String) throws {
    do {
      try validateModelPackageIdentity(id: id, version: version)
    } catch CoreError.InvalidModelPackageManifest {
      throw ModelPackageStoreError.invalidManifest
    }
    let packagesRoot = modelsDirectory.appendingPathComponent("Packages", isDirectory: true)
    let destination = packageDirectory(id: id, version: version, under: packagesRoot)
    guard pathExists(packagesRoot) else {
      return
    }
    guard isDirectory(packagesRoot) else {
      throw ModelPackageStoreError.invalidStagedFile
    }
    let identifierDirectory = destination.deletingLastPathComponent()
    guard pathExists(identifierDirectory) else {
      return
    }
    guard isDirectory(identifierDirectory) else {
      throw ModelPackageStoreError.invalidStagedFile
    }
    guard pathExists(destination) else {
      return
    }
    guard isDirectory(destination) else {
      throw ModelPackageStoreError.invalidStagedFile
    }
    try fileManager.removeItem(at: destination)
  }

  func resolveInstalledPackage(id: String, version: String) throws -> InstalledModelPackage {
    do {
      try validateModelPackageIdentity(id: id, version: version)
    } catch CoreError.InvalidModelPackageManifest {
      throw ModelPackageStoreError.invalidManifest
    }

    let packagesRoot = modelsDirectory.appendingPathComponent("Packages", isDirectory: true)
    let directory = packageDirectory(id: id, version: version, under: packagesRoot)
    guard pathExists(packagesRoot) else {
      throw ModelPackageStoreError.packageNotInstalled
    }
    guard isDirectory(packagesRoot) else {
      throw ModelPackageStoreError.installedPackageMismatch
    }
    let identifierDirectory = directory.deletingLastPathComponent()
    guard pathExists(identifierDirectory) else {
      throw ModelPackageStoreError.packageNotInstalled
    }
    guard isDirectory(identifierDirectory) else {
      throw ModelPackageStoreError.installedPackageMismatch
    }
    guard pathExists(directory) else {
      throw ModelPackageStoreError.packageNotInstalled
    }
    guard isDirectory(directory) else {
      throw ModelPackageStoreError.installedPackageMismatch
    }

    let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
    guard isRegularFile(manifestURL),
      let manifest = try? JSONDecoder().decode(
        ModelPackageManifest.self,
        from: Data(contentsOf: manifestURL)
      ),
      manifest.id == id,
      manifest.version == version
    else {
      throw ModelPackageStoreError.installedPackageMismatch
    }
    do {
      try validate(manifest)
    } catch {
      throw ModelPackageStoreError.installedPackageMismatch
    }

    for file in manifest.files {
      let fileURL: URL
      do {
        fileURL = try stagedFileURL(for: file, under: directory)
      } catch {
        throw ModelPackageStoreError.installedPackageMismatch
      }
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
        let actualSize = (attributes[.size] as? NSNumber)?.uint64Value,
        actualSize == file.sizeBytes
      else {
        throw ModelPackageStoreError.installedPackageMismatch
      }
    }

    return InstalledModelPackage(manifest: manifest, directoryURL: directory)
  }

  private func validate(_ manifest: ModelPackageManifest) throws {
    do {
      try validateModelPackageDescriptor(descriptor: manifest)
    } catch CoreError.InvalidModelPackageManifest {
      throw ModelPackageStoreError.invalidManifest
    }
  }

  private func validateStagingManifest(
    _ manifest: ModelPackageManifest,
    at stagingDirectory: URL
  ) throws {
    guard isDirectory(stagingDirectory) else {
      throw ModelPackageStoreError.invalidStagedFile
    }
    let manifestURL = stagingDirectory.appendingPathComponent(Self.manifestFilename)
    guard isRegularFile(manifestURL),
      let stagedManifest = try? JSONDecoder().decode(
        ModelPackageManifest.self,
        from: Data(contentsOf: manifestURL)
      ),
      stagedManifest == manifest
    else {
      throw ModelPackageStoreError.stagingManifestMismatch
    }
  }

  private func stagedFileURL(for file: ModelPackageFile, under root: URL) throws -> URL {
    var fileURL = root
    let components = file.relativePath.split(separator: "/")
    for (index, component) in components.enumerated() {
      fileURL.appendPathComponent(String(component))
      let isLastComponent = index == components.count - 1
      guard isLastComponent ? isRegularFile(fileURL) : isDirectory(fileURL) else {
        throw ModelPackageStoreError.invalidStagedFile
      }
    }
    return fileURL
  }

  private func packageDirectory(for manifest: ModelPackageManifest, under root: URL) -> URL {
    packageDirectory(id: manifest.id, version: manifest.version, under: root)
  }

  private func packageDirectory(id: String, version: String, under root: URL) -> URL {
    root
      .appendingPathComponent(Self.pathComponent(for: id), isDirectory: true)
      .appendingPathComponent(Self.pathComponent(for: version), isDirectory: true)
  }

  private func ensureDirectory(_ directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard isDirectory(directory) else {
      throw ModelPackageStoreError.invalidStagedFile
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    fileType(at: url) == mode_t(S_IFDIR)
  }

  private func isRegularFile(_ url: URL) -> Bool {
    fileType(at: url) == mode_t(S_IFREG)
  }

  private func fileType(at url: URL) -> mode_t? {
    var fileStatus = stat()
    let result = url.path.withCString { lstat($0, &fileStatus) }
    guard result == 0 else {
      return nil
    }
    return fileStatus.st_mode & mode_t(S_IFMT)
  }

  private func pathExists(_ url: URL) -> Bool {
    var fileStatus = stat()
    return url.path.withCString { lstat($0, &fileStatus) } == 0
  }

  private func excludeFromBackup(_ directory: URL) throws {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(resourceValues)
  }

  private static func pathComponent(for identifier: String) -> String {
    Data(identifier.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension ModelPackageArtifact: Codable {
  private enum CodingKeys: String, CodingKey {
    case relativePath
    case sizeBytes
    case sha256
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      relativePath: try container.decode(String.self, forKey: .relativePath),
      sizeBytes: try container.decode(UInt64.self, forKey: .sizeBytes),
      sha256: try container.decode(String.self, forKey: .sha256)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(relativePath, forKey: .relativePath)
    try container.encode(sizeBytes, forKey: .sizeBytes)
    try container.encode(sha256, forKey: .sha256)
  }
}

extension ModelPackageDescriptor: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case version
    case files
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      version: try container.decode(String.self, forKey: .version),
      files: try container.decode([ModelPackageArtifact].self, forKey: .files)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(version, forKey: .version)
    try container.encode(files, forKey: .files)
  }
}
