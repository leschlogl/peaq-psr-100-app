import XCTest
@testable import PeaqRing

final class RingBatteryReminderTests: XCTestCase {
    func testThresholdIsInclusiveAndFreshRecoveryRearmsIt() {
        var state = RingBatteryReminderState()
        XCTAssertFalse(state.enabled)
        state.enabled = true
        state.setThreshold(20)

        XCTAssertTrue(state.accept(reading(24)))
        XCTAssertFalse(state.evaluateFreshReading())
        XCTAssertTrue(state.accept(reading(20)))
        XCTAssertTrue(state.evaluateFreshReading())
        state.setReminded(true)

        XCTAssertTrue(state.accept(reading(18)))
        XCTAssertFalse(state.evaluateFreshReading())
        XCTAssertTrue(state.accept(reading(21)))
        XCTAssertFalse(state.evaluateFreshReading())
        XCTAssertFalse(state.reminded)
        XCTAssertTrue(state.accept(reading(19)))
        XCTAssertTrue(state.evaluateFreshReading())
    }

    func testStandardReadingCannotReplaceOrRearmPersistedVendorReading() throws {
        let suite = "RingBatteryReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var state = RingBatteryReminderState()
        state.enabled = true
        state.setThreshold(25)
        XCTAssertTrue(state.accept(reading(21)))
        XCTAssertTrue(state.evaluateFreshReading())
        state.setReminded(true)
        state.save(ringID: "first", defaults: defaults)

        var restored = RingBatteryReminderState.load(ringID: "first", defaults: defaults)
        XCTAssertEqual(restored, state)
        XCTAssertFalse(restored.accept(reading(90, source: .standard, time: 200)))
        XCTAssertEqual(restored.latest?.date, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(restored.reminded)
        XCTAssertFalse(restored.accept(reading(101, time: 200)))
        XCTAssertTrue(restored.accept(reading(20, time: 200)))
        XCTAssertFalse(restored.evaluateFreshReading())
        XCTAssertEqual(RingBatteryReminderState.load(ringID: "second", defaults: defaults), RingBatteryReminderState())
    }

    func testStandardReadingCanReplaceOldVendorReadingIfServiceIsAbsent() {
        var state = RingBatteryReminderState()
        XCTAssertTrue(state.accept(reading(30)))
        XCTAssertTrue(state.accept(reading(23, source: .standard, time: 200), vendorExpected: false))
        XCTAssertEqual(state.latest?.source, .standard)
        XCTAssertEqual(state.latest?.percent, 23)
    }

    func testDisabledReminderDoesNotConsumeTheLowPeriod() {
        var state = RingBatteryReminderState()
        XCTAssertTrue(state.accept(reading(18, source: .standard)))
        XCTAssertFalse(state.evaluateFreshReading())
        XCTAssertFalse(state.reminded)

        state.enabled = true
        state.setThreshold(17) // Unsupported picker value leaves the threshold unchanged.
        XCTAssertEqual(state.threshold, 20)
        XCTAssertTrue(state.accept(reading(18, source: .standard, time: 200)))
        XCTAssertTrue(state.evaluateFreshReading())
    }

    private func reading(_ percent: Int, source: RingBatteryReading.Source = .vendor,
                         time: TimeInterval = 100) -> RingBatteryReading {
        RingBatteryReading(percent: percent, date: Date(timeIntervalSince1970: time), source: source)
    }
}
