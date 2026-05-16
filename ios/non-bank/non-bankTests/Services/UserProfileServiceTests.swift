import XCTest
@testable import non_bank

/// Tests for `UserProfileService` — the UserDefaults-backed display
/// name persistence used by the share-link flow. Each test clears
/// the underlying key in `setUp`/`tearDown` so they don't leak state
/// into each other or into the running app's defaults.
final class UserProfileServiceTests: XCTestCase {

    /// Mirrors the private constant in UserProfileService. Kept in
    /// sync by hand — if the service's storage key changes, this
    /// suite will start failing visibly rather than silently
    /// reading stale state.
    private let key = "user_profile_display_name"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Read

    func testDisplayName_whenUnset_returnsNil() {
        XCTAssertNil(UserProfileService.displayName())
        XCTAssertFalse(UserProfileService.isNameSet)
    }

    func testDisplayName_whenStoredValueIsEmptyString_returnsNil() {
        // A previously-set name that was cleared in the UI typically
        // round-trips through this branch: the editor binds to a
        // String, sets "", and we treat that as "not set".
        UserDefaults.standard.set("", forKey: key)
        XCTAssertNil(UserProfileService.displayName())
        XCTAssertFalse(UserProfileService.isNameSet)
    }

    func testDisplayName_whenStoredValueIsWhitespaceOnly_returnsNil() {
        UserDefaults.standard.set("   \t\n  ", forKey: key)
        XCTAssertNil(UserProfileService.displayName())
        XCTAssertFalse(UserProfileService.isNameSet)
    }

    func testDisplayName_returnsTrimmedValue() {
        UserDefaults.standard.set("  Nikita  ", forKey: key)
        XCTAssertEqual(UserProfileService.displayName(), "Nikita")
        XCTAssertTrue(UserProfileService.isNameSet)
    }

    // MARK: - Write

    func testSetDisplayName_persistsTrimmedValue() {
        UserProfileService.setDisplayName("  Nikita  ")
        XCTAssertEqual(UserProfileService.displayName(), "Nikita")
        // Also assert the raw stored value is trimmed — protects against
        // a future change that trims on read but not on write.
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Nikita")
    }

    func testSetDisplayName_withEmptyString_clearsStorage() {
        UserProfileService.setDisplayName("Nikita")
        UserProfileService.setDisplayName("")
        XCTAssertNil(UserProfileService.displayName())
        // Storage really removed, not just stored as "".
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testSetDisplayName_withWhitespaceOnly_clearsStorage() {
        UserProfileService.setDisplayName("Nikita")
        UserProfileService.setDisplayName("    ")
        XCTAssertNil(UserProfileService.displayName())
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testSetDisplayName_preservesUnicodeAndEmoji() {
        // Display names ship into share-link JSON via the `sn` field.
        // They must round-trip Cyrillic, accented Latin, and emoji
        // without normalisation surprises.
        UserProfileService.setDisplayName("Никита 🦊")
        XCTAssertEqual(UserProfileService.displayName(), "Никита 🦊")
    }
}
