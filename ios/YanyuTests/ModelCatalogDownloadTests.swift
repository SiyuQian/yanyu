import Foundation
import XCTest

@testable import Yanyu

final class ModelCatalogDownloadTests: XCTestCase {
  func testBuildsPackageManifestAndPinnedHTTPSSourceFromSharedCatalog() throws {
    let qwen = try XCTUnwrap(
      bundledModelCatalog().first { $0.name == "Qwen3-ASR 0.6B" })
    let artifact = try XCTUnwrap(
      qwen.files.first { $0.filename == "Qwen3-ASR-0.6B-Q4_K_M.gguf" })

    let download = try makeCatalogModelPackageDownload(model: qwen, file: artifact)

    XCTAssertEqual(
      download.manifest.id,
      "handy-computer/Qwen3-ASR-0.6B-gguf/Qwen3-ASR-0.6B-Q4_K_M.gguf"
    )
    XCTAssertEqual(download.manifest.version, "e4e16599b900eb0cb36e524514756bb92eb092b7")
    XCTAssertEqual(
      download.manifest.files,
      [
        ModelPackageArtifact(
          relativePath: "Qwen3-ASR-0.6B-Q4_K_M.gguf",
          sizeBytes: artifact.sizeBytes,
          sha256: try XCTUnwrap(artifact.sha256)
        )
      ]
    )
    XCTAssertEqual(download.sources.count, 1)
    XCTAssertEqual(download.sources.first?.relativePath, artifact.filename)
    XCTAssertEqual(
      download.sources.first?.url.absoluteString,
      "https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/resolve/"
        + "e4e16599b900eb0cb36e524514756bb92eb092b7/Qwen3-ASR-0.6B-Q4_K_M.gguf"
    )
  }

  func testRejectsAnArtifactThatIsNotPartOfTheCatalogModel() throws {
    let qwen = try XCTUnwrap(
      bundledModelCatalog().first { $0.name == "Qwen3-ASR 0.6B" })
    let otherArtifact = QuantFile(
      filename: "not-in-this-model.gguf",
      quant: "Q4_K_M",
      sizeBytes: 5,
      sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )

    XCTAssertThrowsError(try makeCatalogModelPackageDownload(model: qwen, file: otherArtifact))
  }

  func testRejectsUnsafeCatalogArtifactPathsBeforeCreatingAnInstallPlan() throws {
    var qwen = try XCTUnwrap(
      bundledModelCatalog().first { $0.name == "Qwen3-ASR 0.6B" })
    qwen.files = [
      QuantFile(
        filename: "../outside.gguf",
        quant: "Q4_K_M",
        sizeBytes: 5,
        sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      )
    ]

    XCTAssertThrowsError(try makeCatalogModelPackageDownload(model: qwen, file: qwen.files[0]))
  }
}
