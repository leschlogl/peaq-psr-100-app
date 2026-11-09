import XCTest
@testable import PeaqRing

final class ReferencePreferencesTests: XCTestCase {
    @MainActor
    func testOptionalProfilePersistsWithoutInventingDefaults() {
        let suite = "ReferencePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ReferencePreferences(defaults: defaults)
        XCTAssertNil(first.profile.age)
        XCTAssertEqual(first.profile.sex, .unspecified)
        defaults.set(35, forKey: "referenceAge")
        let legacy = ReferencePreferences(defaults: defaults)
        XCTAssertEqual(legacy.profile.age, 35)
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertFalse(first.saveBirthYear(year - 17))
        XCTAssertTrue(first.saveBirthYear(year - 35))
        first.sex = .female
        first.maximumHeartRate = 190
        let next = ReferencePreferences(defaults: defaults)
        XCTAssertEqual(next.profile.age, 35)
        XCTAssertEqual(next.age(in: year + 1), 36)
        XCTAssertNil(defaults.object(forKey: "referenceAge"))
        XCTAssertEqual(next.profile.sex, .female)
        XCTAssertEqual(next.profile.maximumHeartRate, 190)
        next.maximumHeartRate = 0
        XCTAssertEqual(next.profile.maximumHeartRate, 185)
        XCTAssertNil(defaults.object(forKey: "ringID"))
        XCTAssertTrue(next.saveBirthYear(nil))
        XCTAssertNil(next.profile.age)
        XCTAssertNil(ReferencePreferences(defaults: defaults).profile.age)
    }
}
