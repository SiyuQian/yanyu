import XCTest

@testable import Yanyu

final class ModelArtifactIntegrityTests: XCTestCase {
  func testVerifiesExpectedSizeAndSha256AcrossRustBoundary() throws {
    let artifactURL = try makeArtifact(contents: "hello")
    defer { try? FileManager.default.removeItem(at: artifactURL) }

    let integrity = try verifyFileIntegrity(
      path: artifactURL.path,
      expectedSizeBytes: 5,
      expectedSha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )

    XCTAssertEqual(integrity.sizeBytes, 5)
    XCTAssertEqual(
      integrity.sha256,
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
  }

  func testReturnsTypedSizeMismatchAcrossRustBoundary() throws {
    let artifactURL = try makeArtifact(contents: "hello")
    defer { try? FileManager.default.removeItem(at: artifactURL) }

    XCTAssertThrowsError(
      try verifyFileIntegrity(
        path: artifactURL.path,
        expectedSizeBytes: 6,
        expectedSha256: nil
      )
    ) { error in
      XCTAssertEqual(error as? CoreError, .FileSizeMismatch(expected: 6, actual: 5))
    }
  }

  func testReturnsTypedSha256MismatchAcrossRustBoundary() throws {
    let artifactURL = try makeArtifact(contents: "hello")
    defer { try? FileManager.default.removeItem(at: artifactURL) }

    XCTAssertThrowsError(
      try verifyFileIntegrity(
        path: artifactURL.path,
        expectedSizeBytes: nil,
        expectedSha256: String(repeating: "0", count: 64)
      )
    ) { error in
      XCTAssertEqual(
        error as? CoreError,
        .FileHashMismatch(
          expected: String(repeating: "0", count: 64),
          actual: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
      )
    }
  }

  private func makeArtifact(contents: String) throws -> URL {
    let artifactURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try Data(contents.utf8).write(to: artifactURL)
    return artifactURL
  }
}
