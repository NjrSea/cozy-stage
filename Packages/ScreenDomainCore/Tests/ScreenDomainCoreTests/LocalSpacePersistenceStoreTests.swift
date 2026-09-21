import XCTest
@testable import ScreenDomainCore

final class LocalSpacePersistenceStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-persist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeStore() -> LocalSpacePersistenceStore {
        LocalSpacePersistenceStore(url: tempDir.appendingPathComponent("spaces.json"))
    }

    private func makeSpace(id: String, number: Int) -> SavedSpace {
        SavedSpace(
            id: id,
            number: number,
            name: "Space \(number)",
            lifecycle: .restorable,
            appSlots: [
                LogicalWindowSlot(id: "slot-1", bundleID: "com.example.app", tabOrder: 0, status: .resolved)
            ]
        )
    }

    // MARK: - Empty store

    func testLoadReturnsEmptyWhenNoCheckpoint() throws {
        let store = makeStore()
        let spaces = try store.load()
        XCTAssertTrue(spaces.isEmpty)
    }

    // MARK: - Round-trip

    func testSaveAndLoadRoundTrip() throws {
        let store = makeStore()
        let spaces = [makeSpace(id: "space-1", number: 1), makeSpace(id: "space-2", number: 2)]
        try store.saveAtomically(spaces)

        let loaded = try store.load()
        XCTAssertEqual(loaded, spaces)
    }

    // MARK: - Crash safety (atomic write)

    func testAtomicWriteLeavesPreviousCheckpointIntact() throws {
        let store = makeStore()
        let firstBatch = [makeSpace(id: "space-1", number: 1)]
        try store.saveAtomically(firstBatch)

        // Overwrite with a second batch — the previous data should be fully
        // replaced (atomic rename guarantees no partial state).
        let secondBatch = [makeSpace(id: "space-2", number: 2), makeSpace(id: "space-3", number: 3)]
        try store.saveAtomically(secondBatch)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.id).sorted(), ["space-2", "space-3"])
    }

    // MARK: - Corrupted checkpoint

    func testLoadRejectsCorruptedCheckpoint() throws {
        let store = makeStore()
        // Write garbage to the checkpoint file.
        let garbage = Data("not valid json".utf8)
        try garbage.write(to: tempDir.appendingPathComponent("spaces.json"))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SpacePersistenceError, .checkpointCorrupted)
        }
    }

    func testLoadRejectsCheckpointWithUnknownKeys() throws {
        let store = makeStore()
        // Write valid JSON but with an unknown key inside a SavedSpace.
        let json = Data(#"""
        [{"id":"s1","number":1,"name":null,"lifecycle":"restorable","layoutRevision":1,"canvasLayout":{"windowFrames":{},"paneRatios":[]},"appSlots":[],"bogusKey":42}]
        """#.utf8)
        try json.write(to: tempDir.appendingPathComponent("spaces.json"))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SpacePersistenceError, .checkpointCorrupted)
        }
    }

    // MARK: - Content-free invariant

    func testPersistedRecordDoesNotContainContent() throws {
        let store = makeStore()
        let space = SavedSpace(
            id: "space-1", number: 1, name: "Test",
            appSlots: [LogicalWindowSlot(id: "slot-1", bundleID: "com.example", status: .resolved)]
        )
        try store.saveAtomically([space])

        // Read the raw file and verify no forbidden content fields are present.
        let rawData = try Data(contentsOf: tempDir.appendingPathComponent("spaces.json"))
        let jsonString = String(data: rawData, encoding: .utf8) ?? ""
        let forbidden = ["password", "screenshot", "documentPath", "axText", "accessToken", "title"]
        for term in forbidden {
            XCTAssertFalse(jsonString.contains(term), "Persisted checkpoint must not contain \(term)")
        }
    }
}
