import Darwin
import Foundation

struct ModelPackageDownloadSource: Equatable, Sendable {
  let relativePath: String
  let url: URL
}

struct ModelPackageDownloadProgress: Equatable, Sendable {
  let completedBytes: UInt64
  let totalBytes: UInt64

  var fractionCompleted: Double {
    guard totalBytes > 0 else {
      return 1
    }
    return min(Double(completedBytes) / Double(totalBytes), 1)
  }
}

enum ModelPackageInstallerError: Error, Equatable {
  case invalidSources
  case insecureSourceURL
  case invalidStagingPath
  case packageSizeOverflow
}

enum ModelPackageDownloadTransportError: Error, Equatable {
  case invalidResponse
  case httpStatus(Int)
  case responseRedirectedToInsecureURL
  case downloadedSizeMismatch(expected: UInt64, actual: UInt64)
}

private struct ModelPackageResumeMetadata: Codable {
  let sourceURL: String
  let entityTag: String
}

protocol ModelPackageDownloadTransport: Sendable {
  func download(
    from url: URL,
    to destination: URL,
    expectedSizeBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) async throws
}

/// Streams HTTPS artifacts to staging and resumes partial files when the server provides a strong ETag.
struct URLSessionModelPackageDownloadTransport: ModelPackageDownloadTransport {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func download(
    from url: URL,
    to destination: URL,
    expectedSizeBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) async throws {
    guard Self.isSecureURL(url) else {
      throw ModelPackageInstallerError.insecureSourceURL
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let partialURL = destination.appendingPathExtension("yanyu-partial")
    let metadataURL = destination.appendingPathExtension("yanyu-partial.json")
    let partialFileType = Self.fileType(at: partialURL)
    guard partialFileType == nil || partialFileType == mode_t(S_IFREG) else {
      throw ModelPackageDownloadTransportError.invalidResponse
    }
    var metadata = Self.readResumeMetadata(at: metadataURL, for: url)
    var partialBytes = Self.regularFileSize(at: partialURL)
    if partialBytes > expectedSizeBytes || (partialBytes > 0 && metadata == nil) {
      Self.discardPartialDownload(at: partialURL, metadataURL: metadataURL)
      partialBytes = 0
      metadata = nil
    }
    if partialBytes == expectedSizeBytes, metadata != nil {
      try fileManager.moveItem(at: partialURL, to: destination)
      try? fileManager.removeItem(at: metadataURL)
      progress(expectedSizeBytes)
      return
    }
    if partialBytes == 0 {
      try? fileManager.removeItem(at: metadataURL)
      metadata = nil
    }
    progress(partialBytes)

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let metadata, partialBytes > 0 {
      request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
      request.setValue(metadata.entityTag, forHTTPHeaderField: "If-Range")
    }
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ModelPackageDownloadTransportError.invalidResponse
    }
    guard let responseURL = response.url, Self.isSecureURL(responseURL) else {
      throw ModelPackageDownloadTransportError.responseRedirectedToInsecureURL
    }
    if httpResponse.statusCode == 416 {
      if partialBytes == expectedSizeBytes, metadata != nil {
        try fileManager.moveItem(at: partialURL, to: destination)
        try? fileManager.removeItem(at: metadataURL)
        progress(expectedSizeBytes)
        return
      }
      Self.discardPartialDownload(at: partialURL, metadataURL: metadataURL)
      throw ModelPackageDownloadTransportError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw ModelPackageDownloadTransportError.httpStatus(httpResponse.statusCode)
    }
    guard
      Self.header("Content-Encoding", in: httpResponse)?.lowercased() == nil
        || Self.header("Content-Encoding", in: httpResponse)?.lowercased() == "identity"
    else {
      throw ModelPackageDownloadTransportError.invalidResponse
    }

    var fileHandle: FileHandle?
    var canResumeAfterFailure = false
    do {
      let appendResponse: Bool
      if httpResponse.statusCode == 206 {
        guard partialBytes > 0,
          let metadata,
          Self.isValidPartialResponse(
            httpResponse,
            expectedOffset: partialBytes,
            expectedSizeBytes: expectedSizeBytes,
            expectedEntityTag: metadata.entityTag
          )
        else {
          Self.discardPartialDownload(at: partialURL, metadataURL: metadataURL)
          throw ModelPackageDownloadTransportError.invalidResponse
        }
        appendResponse = true
        canResumeAfterFailure = true
      } else if httpResponse.statusCode == 200 {
        appendResponse = false
        if let entityTag = Self.strongEntityTag(in: httpResponse) {
          metadata = ModelPackageResumeMetadata(
            sourceURL: url.absoluteString,
            entityTag: entityTag
          )
          try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
          canResumeAfterFailure = true
        } else {
          metadata = nil
          try? fileManager.removeItem(at: metadataURL)
        }
      } else {
        throw ModelPackageDownloadTransportError.httpStatus(httpResponse.statusCode)
      }

      if !appendResponse {
        if !fileManager.fileExists(atPath: partialURL.path) {
          guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
          }
        }
      }
      let handle = try FileHandle(forWritingTo: partialURL)
      fileHandle = handle
      if appendResponse {
        try handle.seekToEnd()
      } else {
        try handle.truncate(atOffset: 0)
      }
      var bufferedBytes = [UInt8]()
      bufferedBytes.reserveCapacity(64 * 1024)
      let responseStartBytes = appendResponse ? partialBytes : 0
      var responseBytes: UInt64 = 0

      for try await byte in bytes {
        try Task.checkCancellation()
        let (receivedBytes, overflow) = responseStartBytes.addingReportingOverflow(responseBytes)
        guard !overflow, receivedBytes < expectedSizeBytes else {
          canResumeAfterFailure = false
          throw ModelPackageDownloadTransportError.downloadedSizeMismatch(
            expected: expectedSizeBytes,
            actual: overflow ? UInt64.max : receivedBytes + 1
          )
        }
        responseBytes += 1
        bufferedBytes.append(byte)
        if bufferedBytes.count == 64 * 1024 {
          try handle.write(contentsOf: Data(bufferedBytes))
          bufferedBytes.removeAll(keepingCapacity: true)
          progress(responseStartBytes + responseBytes)
        }
      }

      if !bufferedBytes.isEmpty {
        try handle.write(contentsOf: Data(bufferedBytes))
      }
      try handle.close()
      fileHandle = nil
      let receivedBytes = responseStartBytes + responseBytes
      guard receivedBytes == expectedSizeBytes else {
        throw ModelPackageDownloadTransportError.downloadedSizeMismatch(
          expected: expectedSizeBytes,
          actual: receivedBytes
        )
      }
      progress(receivedBytes)
      try fileManager.moveItem(at: partialURL, to: destination)
      try? fileManager.removeItem(at: metadataURL)
    } catch {
      try? fileHandle?.close()
      if !canResumeAfterFailure {
        Self.discardPartialDownload(at: partialURL, metadataURL: metadataURL)
      }
      throw error
    }
  }

  private static func isValidPartialResponse(
    _ response: HTTPURLResponse,
    expectedOffset: UInt64,
    expectedSizeBytes: UInt64,
    expectedEntityTag: String
  ) -> Bool {
    guard let contentRange = header("Content-Range", in: response),
      validatePartialContentRange(
        value: contentRange,
        expectedOffset: expectedOffset,
        expectedSize: expectedSizeBytes
      )
    else {
      return false
    }
    if let responseEntityTag = header("ETag", in: response) {
      return responseEntityTag == expectedEntityTag && isStrongEntityTag(responseEntityTag)
    }
    return true
  }

  private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
    response.allHeaderFields.first { key, _ in
      String(describing: key).caseInsensitiveCompare(name) == .orderedSame
    }.map { String(describing: $0.value) }
  }

  private static func strongEntityTag(in response: HTTPURLResponse) -> String? {
    guard let entityTag = header("ETag", in: response), isStrongEntityTag(entityTag) else {
      return nil
    }
    return entityTag
  }

  private static func isStrongEntityTag(_ entityTag: String) -> Bool {
    !entityTag.isEmpty && !entityTag.uppercased().hasPrefix("W/")
  }

  private static func readResumeMetadata(
    at metadataURL: URL,
    for sourceURL: URL
  ) -> ModelPackageResumeMetadata? {
    guard fileType(at: metadataURL) == mode_t(S_IFREG),
      let data = try? Data(contentsOf: metadataURL),
      let metadata = try? JSONDecoder().decode(ModelPackageResumeMetadata.self, from: data),
      metadata.sourceURL == sourceURL.absoluteString,
      isStrongEntityTag(metadata.entityTag)
    else {
      return nil
    }
    return metadata
  }

  private static func regularFileSize(at url: URL) -> UInt64 {
    guard fileType(at: url) == mode_t(S_IFREG) else {
      return 0
    }
    var fileStatus = stat()
    guard url.path.withCString({ lstat($0, &fileStatus) }) == 0 else {
      return 0
    }
    return UInt64(fileStatus.st_size)
  }

  private static func discardPartialDownload(at partialURL: URL, metadataURL: URL) {
    _ = partialURL.path.withCString { unlink($0) }
    _ = metadataURL.path.withCString { unlink($0) }
  }

  private static func fileType(at url: URL) -> mode_t? {
    var fileStatus = stat()
    let result = url.path.withCString { lstat($0, &fileStatus) }
    guard result == 0 else {
      return nil
    }
    return fileStatus.st_mode & mode_t(S_IFMT)
  }

  private static func isSecureURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme?.lowercased() == "https"
      && components.host?.isEmpty == false
      && components.user == nil
      && components.password == nil
  }
}

/// Downloads, verifies, and atomically installs a multi-file model package.
actor ModelPackageInstaller {
  private let store: ModelPackageStore
  private let transport: any ModelPackageDownloadTransport
  private let fileManager = FileManager.default

  init(
    store: ModelPackageStore,
    transport: any ModelPackageDownloadTransport = URLSessionModelPackageDownloadTransport()
  ) {
    self.store = store
    self.transport = transport
  }

  func install(
    _ manifest: ModelPackageManifest,
    from sources: [ModelPackageDownloadSource],
    progress: @escaping @Sendable (ModelPackageDownloadProgress) -> Void = { _ in }
  ) async throws -> InstalledModelPackage {
    try validateSources(manifest: manifest, sources: sources)
    let totalBytes = try totalSize(of: manifest.files)
    let stagingDirectory = try await store.prepareStagingDirectory(for: manifest)
    var completedBytes: UInt64 = 0

    for file in manifest.files {
      try Task.checkCancellation()
      let destination = try stagedURL(for: file, under: stagingDirectory)
      if fileType(at: destination) == mode_t(S_IFREG),
        (try? verifyFileIntegrity(
          path: destination.path,
          expectedSizeBytes: file.sizeBytes,
          expectedSha256: file.sha256
        )) != nil
      {
        completedBytes += file.sizeBytes
        progress(
          ModelPackageDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes))
        continue
      }

      if fileType(at: destination) != nil {
        guard fileType(at: destination) == mode_t(S_IFREG) else {
          throw ModelPackageInstallerError.invalidStagingPath
        }
        try fileManager.removeItem(at: destination)
      }

      let source = sources.first { $0.relativePath == file.relativePath }
      guard let source else {
        throw ModelPackageInstallerError.invalidSources
      }
      let alreadyCompletedBytes = completedBytes
      do {
        try await transport.download(
          from: source.url,
          to: destination,
          expectedSizeBytes: file.sizeBytes
        ) { receivedBytes in
          let fileBytes = min(receivedBytes, file.sizeBytes)
          progress(
            ModelPackageDownloadProgress(
              completedBytes: min(alreadyCompletedBytes + fileBytes, totalBytes),
              totalBytes: totalBytes
            )
          )
        }
        _ = try verifyFileIntegrity(
          path: destination.path,
          expectedSizeBytes: file.sizeBytes,
          expectedSha256: file.sha256
        )
      } catch {
        try? fileManager.removeItem(at: destination)
        throw error
      }
      completedBytes += file.sizeBytes
      progress(
        ModelPackageDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes))
    }

    try Task.checkCancellation()
    return try await store.commit(manifest, from: stagingDirectory)
  }

  private func validateSources(
    manifest: ModelPackageManifest,
    sources: [ModelPackageDownloadSource]
  ) throws {
    let expectedPaths = manifest.files.map(\.relativePath)
    let sourcePaths = sources.map(\.relativePath)
    guard Set(expectedPaths).count == expectedPaths.count,
      Set(sourcePaths).count == sourcePaths.count,
      Set(expectedPaths) == Set(sourcePaths)
    else {
      throw ModelPackageInstallerError.invalidSources
    }

    guard sources.allSatisfy({ Self.isSecureSourceURL($0.url) }) else {
      throw ModelPackageInstallerError.insecureSourceURL
    }
  }

  private func totalSize(of files: [ModelPackageFile]) throws -> UInt64 {
    var total: UInt64 = 0
    for file in files {
      let (nextTotal, overflow) = total.addingReportingOverflow(file.sizeBytes)
      guard !overflow else {
        throw ModelPackageInstallerError.packageSizeOverflow
      }
      total = nextTotal
    }
    return total
  }

  private func stagedURL(for file: ModelPackageFile, under root: URL) throws -> URL {
    let components = file.relativePath.split(separator: "/").map(String.init)
    guard let filename = components.last else {
      throw ModelPackageInstallerError.invalidStagingPath
    }
    var parent = root
    for component in components.dropLast() {
      parent.appendPathComponent(component, isDirectory: true)
      if fileType(at: parent) == nil {
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
      }
      guard fileType(at: parent) == mode_t(S_IFDIR) else {
        throw ModelPackageInstallerError.invalidStagingPath
      }
    }
    return parent.appendingPathComponent(filename)
  }

  private func fileType(at url: URL) -> mode_t? {
    var fileStatus = stat()
    let result = url.path.withCString { lstat($0, &fileStatus) }
    guard result == 0 else {
      return nil
    }
    return fileStatus.st_mode & mode_t(S_IFMT)
  }

  private static func isSecureSourceURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme?.lowercased() == "https"
      && components.host?.isEmpty == false
      && components.user == nil
      && components.password == nil
  }
}
