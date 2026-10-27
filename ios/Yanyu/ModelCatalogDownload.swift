import Foundation

struct CatalogModelPackageDownload: Equatable, Sendable {
  let manifest: ModelPackageManifest
  let sources: [ModelPackageDownloadSource]
}

enum CatalogModelPackageDownloadError: Error, Equatable {
  case unsupportedSource
  case artifactNotInCatalog
  case invalidArtifact
  case invalidDownloadURL
}

/// Converts a bundled catalog artifact into the manifest and immutable source expected by the
/// package installer. The bundled SHA-256 is the trust anchor for downloaded bytes.
func makeCatalogModelPackageDownload(
  model: ModelDescriptor,
  file: QuantFile
) throws -> CatalogModelPackageDownload {
  guard model.files.contains(file) else {
    throw CatalogModelPackageDownloadError.artifactNotInCatalog
  }
  guard case .huggingFace(let repoId, let revision) = model.source else {
    throw CatalogModelPackageDownloadError.unsupportedSource
  }
  guard isSafeRepositoryID(repoId), isSafeRevision(revision), isSafeFilename(file.filename),
    file.sizeBytes > 0,
    let sha256 = file.sha256,
    isSha256(sha256)
  else {
    throw CatalogModelPackageDownloadError.invalidArtifact
  }

  var urlComponents = URLComponents()
  urlComponents.scheme = "https"
  urlComponents.host = "huggingface.co"
  urlComponents.path = "/\(repoId)/resolve/\(revision)/\(file.filename)"
  guard let sourceURL = urlComponents.url,
    sourceURL.scheme == "https",
    sourceURL.host == "huggingface.co",
    sourceURL.user == nil,
    sourceURL.password == nil
  else {
    throw CatalogModelPackageDownloadError.invalidDownloadURL
  }

  let manifest = ModelPackageManifest(
    id: "\(repoId)/\(file.filename)",
    version: revision,
    files: [
      ModelPackageFile(relativePath: file.filename, sizeBytes: file.sizeBytes, sha256: sha256)
    ]
  )
  do {
    try validateModelPackageDescriptor(descriptor: manifest)
  } catch {
    throw CatalogModelPackageDownloadError.invalidArtifact
  }

  return CatalogModelPackageDownload(
    manifest: manifest,
    sources: [ModelPackageDownloadSource(relativePath: file.filename, url: sourceURL)]
  )
}

private func isSafeRepositoryID(_ repositoryID: String) -> Bool {
  let components = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
  return components.count == 2
    && components.allSatisfy { component in
      !component.isEmpty
        && component != "."
        && component != ".."
        && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }
}

private func isSafeRevision(_ revision: String) -> Bool {
  !revision.isEmpty
    && revision != "."
    && revision != ".."
    && !revision.contains("/")
    && !revision.contains("\\")
    && !revision.contains("\0")
}

private func isSafeFilename(_ filename: String) -> Bool {
  !filename.isEmpty
    && filename.hasSuffix(".gguf")
    && !filename.contains("/")
    && !filename.contains("\\")
    && !filename.contains("\0")
    && filename != "."
    && filename != ".."
}

private func isSha256(_ digest: String) -> Bool {
  digest.utf8.count == 64
    && digest.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
