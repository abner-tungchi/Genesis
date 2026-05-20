import XCTest
@testable import GenesisCore

final class SourceWriterTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testPlanWithoutCommitDoesNothing() throws {
        let writer = SourceWriter(root: tmpDir)
        try writer.plan(relativePath: "Sources/Foo/Bar.swift", content: "x")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        XCTAssertEqual(contents, [], "plan() must not touch fs")
        XCTAssertEqual(writer.writtenFileCount, 0)
    }

    func testCommitWritesAllPlannedFiles() throws {
        let writer = SourceWriter(root: tmpDir)
        try writer.plan(relativePath: "a.txt", content: "A")
        try writer.plan(relativePath: "Sources/Foo/b.swift", content: "B")
        try writer.commit()

        let a = try String(contentsOf: tmpDir.appendingPathComponent("a.txt"), encoding: .utf8)
        let b = try String(contentsOf: tmpDir.appendingPathComponent("Sources/Foo/b.swift"), encoding: .utf8)
        XCTAssertEqual(a, "A")
        XCTAssertEqual(b, "B")
        XCTAssertEqual(writer.writtenFileCount, 2)
    }

    func testRollbackRemovesWrittenFiles() throws {
        let writer = SourceWriter(root: tmpDir)
        try writer.plan(relativePath: "x.txt", content: "X")
        try writer.plan(relativePath: "Sources/Inner/y.swift", content: "Y")
        try writer.commit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("x.txt").path))

        writer.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("x.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Sources/Inner").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Sources").path))
    }

    func testRollbackPreservesPreExistingDirs() throws {
        let preExisting = tmpDir.appendingPathComponent("preExisting", isDirectory: true)
        try FileManager.default.createDirectory(at: preExisting, withIntermediateDirectories: true)
        try "pre".write(to: preExisting.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let writer = SourceWriter(root: tmpDir)
        try writer.plan(relativePath: "preExisting/new.txt", content: "new")
        try writer.commit()
        writer.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: preExisting.path), "pre-existing dir must remain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preExisting.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preExisting.appendingPathComponent("new.txt").path))
    }

    // MARK: - Phase 1.f: same-run duplicate planned path detection

    func testDuplicatePlannedPathThrows() throws {
        let writer = SourceWriter(root: tmpDir)
        try writer.plan(relativePath: "Sources/Foo.swift", content: "first")
        XCTAssertThrowsError(try writer.plan(relativePath: "Sources/Foo.swift", content: "second")) { error in
            guard case let GenesisError.outputDirHasConflict(_, conflict) = error else {
                XCTFail("expected outputDirHasConflict, got \(error)")
                return
            }
            XCTAssertTrue(conflict.contains("duplicate planned path"), "got: \(conflict)")
            XCTAssertTrue(conflict.contains("Sources/Foo.swift"), "got: \(conflict)")
        }
    }
}
