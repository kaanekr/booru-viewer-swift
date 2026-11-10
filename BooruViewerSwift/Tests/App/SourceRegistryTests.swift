import XCTest
@testable import BooruViewer

/// Ensures the app-layer registry can build every source the picker offers.
final class SourceRegistryTests: XCTestCase {
    /// Every `SourceID` must resolve, and the adapter must report the id it was built for.
    func testEverySourceIDResolvesToMatchingSource() {
        XCTAssertEqual(SourceID.allCases.count, 13, "The registry must cover the 13 RN source IDs.")

        for id in SourceID.allCases {
            guard let source = SourceRegistry.source(for: id) else {
                XCTFail("SourceRegistry returned nil for '\(id.rawValue)'.")
                continue
            }
            XCTAssertEqual(
                source.id,
                id,
                "Source for '\(id.rawValue)' reported '\(source.id.rawValue)'."
            )
            XCTAssertFalse(
                source.displayName.isEmpty,
                "Source '\(id.rawValue)' has no display name."
            )
        }
    }
}
