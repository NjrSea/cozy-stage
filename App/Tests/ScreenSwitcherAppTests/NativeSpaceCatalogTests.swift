import CoreGraphics
import XCTest
@testable import ScreenSwitcherApp

final class NativeSpaceCatalogTests: XCTestCase {
    func testExactWindowFocusEventMatchesAltTabSafeMouseDown() {
        let windowID = CGWindowID(0x1234_5678)

        let records = NativeExactWindowFocusEventRecord.makeKeySequence(windowID: windowID)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.map { $0[0x08] }, [0x01])
        guard let record = records.first else { return }
        XCTAssertEqual(record.count, 0x100)
        XCTAssertEqual(record[0x04], 0xf8)
        XCTAssertEqual(record[0x3a], 0x10)
        XCTAssertEqual(
            record.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0x3c, as: CGWindowID.self)
            },
            windowID
        )
        let point = record.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0x20, as: CGPoint.self)
        }
        XCTAssertEqual(point, CGPoint(x: 300_000, y: 300_000))
    }

    func testSourceWindowIndexOnlyMatchesOneBindingWithTheSamePID() {
        let matches = SystemNativeSpaceCatalog.uniqueSourceWindowIDs(
            candidates: [
                ("unique", 41, 801),
                ("duplicate-a", 42, 802),
                ("duplicate-b", 42, 802),
                ("pid-mismatch", 43, 803)
            ],
            windows: [
                (801, 41),
                (802, 42),
                (803, 44),
                (804, 45)
            ]
        )

        XCTAssertEqual(matches, [801: "unique"])
    }

    func testExactWindowFocusTransactionOrdersFrontBeforeKeyAndDefersRestoration() {
        var events: [String] = []
        let transaction = NativeExactWindowFocusTransaction(
            resolveProcess: { _ in ProcessSerialNumber() },
            front: { _, windowID, options in
                events.append("front")
                XCTAssertEqual(windowID, 77)
                XCTAssertEqual(options, 0x200)
                return .success
            },
            postEvent: { _, event in
                events.append("key")
                XCTAssertEqual(event, NativeExactWindowFocusEventRecord.makeKeySequence(windowID: 77)[0])
                return .success
            }
        )

        let preparation = transaction.prepare(
            cgWindowID: 77,
            processIdentifier: 1234,
            restoration: { events.append("restore") }
        )

        guard case let .ready(session) = preparation else {
            return XCTFail("expected exact focus session")
        }
        XCTAssertEqual(events, ["front", "key"])
        session.restoreOrigin()
        XCTAssertEqual(events, ["front", "key", "restore"])
    }

    func testExactWindowFocusTransactionProjectsFailuresAndRestoresOnlyAfterFrontAttempt() {
        func failure(
            resolveProcess: NativeExactWindowFocusTransaction.ProcessResolver? = { _ in
                ProcessSerialNumber()
            },
            frontResult: CGError = .success,
            keyResult: CGError = .success
        ) -> (NativeExactWindowFocusFailure?, Int) {
            var restoreCount = 0
            let transaction = NativeExactWindowFocusTransaction(
                resolveProcess: resolveProcess,
                front: resolveProcess == nil ? nil : { _, _, _ in frontResult },
                postEvent: { _, _ in keyResult }
            )
            let preparation = transaction.prepare(
                cgWindowID: 77,
                processIdentifier: 1234,
                restoration: { restoreCount += 1 }
            )
            guard case let .failed(failure) = preparation else {
                return (nil, restoreCount)
            }
            return (failure, restoreCount)
        }

        XCTAssertEqual(failure(resolveProcess: nil).0, .symbolUnavailable)
        XCTAssertEqual(failure(resolveProcess: { _ in nil }).0, .processResolutionFailed)

        let frontRejected = failure(frontResult: .failure)
        XCTAssertEqual(frontRejected.0, .frontProcessRejected)
        XCTAssertEqual(frontRejected.1, 1)

        let keyRejected = failure(keyResult: .failure)
        XCTAssertEqual(keyRejected.0, .keyEventRejected)
        XCTAssertEqual(keyRejected.1, 1)
    }
}
