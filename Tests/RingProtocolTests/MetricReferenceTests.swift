import XCTest
@testable import RingProtocol

final class MetricReferenceTests: XCTestCase {
    func testHourlyAveragesUseEverySampleKeepGapsAndRejectInvalidReadings() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        let end = start.addingTimeInterval(3 * 3600 + 600)
        var chart = RingChartAverager(metric: .respiration, start: start, end: end, calendar: calendar, interval: .hour)
        for (seconds, value) in [(60.0,12.0),(600,12),(1800,12),(3599,18),(3 * 3600,20),(3 * 3600 + 600,22)] {
            chart.append(RingReading(metric: .respiration, value: value, date: start.addingTimeInterval(seconds)))
        }
        chart.append(RingReading(metric: .heartRate, value: 80, date: start))
        chart.append(RingReading(metric: .respiration, value: .nan, date: start))
        chart.append(RingReading(metric: .respiration, value: 15, date: start.addingTimeInterval(-1)))
        chart.append(RingReading(metric: .respiration, value: 15, date: end.addingTimeInterval(1)))
        XCTAssertEqual(chart.sourceCount, 6)
        XCTAssertEqual(chart.readings.map(\.value), [13.5,21])
        XCTAssertEqual(chart.readings.map(\.date), [start,start.addingTimeInterval(3 * 3600)])
    }
    func testHourlyAveragesRespectShortAndRepeatedDSTHours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        for (month, day, hours) in [(3,29,23),(10,25,25)] {
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            var chart = RingChartAverager(metric: .heartRate, start: start, end: end, calendar: calendar, interval: .hour)
            for hour in 0..<hours {
                chart.append(RingReading(metric: .heartRate, value: Double(60 + hour), date: start.addingTimeInterval(Double(hour * 3600 + 1800))))
            }
            XCTAssertEqual(chart.readings.count, hours)
            XCTAssertEqual(chart.readings.map(\.date), (0..<hours).map { start.addingTimeInterval(Double($0 * 3600)) })
            XCTAssertEqual(chart.readings.map(\.value), (0..<hours).map { Double(60 + $0) })
        }
    }
    func testHistoricalWindowsRespectCalendarDaysAndRejectFutureDates() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        for (month, day, hours) in [(3,29,23),(10,25,25)] {
            let selected = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let window = RingHistoryWindow(selectedDay: selected, days: 7, now: now, calendar: calendar)
            XCTAssertEqual(window.nextDay.timeIntervalSince(window.dayStart), Double(hours * 3600))
            XCTAssertEqual(window.chartEnd, window.nextDay)
            XCTAssertEqual(calendar.dateComponents([.day], from: window.trendStart, to: window.dayStart).day, 6)
            XCTAssertFalse(window.isToday)
        }
        let future = calendar.date(byAdding: .day, value: 5, to: now)!
        let clamped = RingHistoryWindow(selectedDay: future, now: now, calendar: calendar)
        XCTAssertTrue(clamped.isToday); XCTAssertEqual(clamped.chartEnd, now)
        XCTAssertEqual(clamped.dayStart, calendar.startOfDay(for: now))
    }
    func testDailyAveragesUseAllSamplesAndKeepMissingDaysEmptyAcrossDST() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        let repeatedHour = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 1, minute: 30))!
        var daily = RingChartAverager(metric: .heartRate, start: start, end: end, calendar: calendar)
        daily.append(RingReading(metric: .heartRate, value: 60, date: repeatedHour))
        daily.append(RingReading(metric: .heartRate, value: 100, date: repeatedHour.addingTimeInterval(3600)))
        daily.append(RingReading(metric: .heartRate, value: 120, date: end))
        daily.append(RingReading(metric: .oxygen, value: 95, date: end))
        daily.append(RingReading(metric: .heartRate, value: .nan, date: end))
        daily.append(RingReading(metric: .heartRate, value: 72, date: start.addingTimeInterval(-1)))
        daily.append(RingReading(metric: .heartRate, value: 72, date: end.addingTimeInterval(1)))
        XCTAssertEqual(daily.sourceCount, 3)
        XCTAssertEqual(daily.readings.map(\.value), [80, 120])
        XCTAssertEqual(daily.readings.map { calendar.component(.day, from: $0.date) }, [25,28])
        XCTAssertTrue(daily.readings.allSatisfy { $0.date == calendar.startOfDay(for: $0.date) })
    }
    func testDailyMeanIsSampleWeightedAndPreservesDecimals() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        var daily = RingChartAverager(metric: .respiration, start: start, end: start.addingTimeInterval(86399), calendar: calendar)
        for (index, value) in [12.0,12,12,18].enumerated() {
            daily.append(RingReading(metric: .respiration, value: value, date: start.addingTimeInterval(Double(index * 3600))))
        }
        XCTAssertEqual(daily.readings.count, 1)
        XCTAssertEqual(daily.readings[0].value, 13.5, accuracy: 0.000001)
        XCTAssertEqual(daily.sourceCount, 4)
    }
    func testTrendReductionPreservesSpikesEndpointsAndChronologyWithBoundedOutput() {
        let start = Date(timeIntervalSince1970: 1_783_000_000)
        var sampler = RingTrendSampler(start: start, end: start.addingTimeInterval(100_000))
        for index in (0..<100_000).reversed() {
            let value: Double = index == 12_345 ? 220 : (index == 45_678 ? 30 : 72)
            sampler.append(RingReading(metric: .heartRate, value: value, date: start.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(sampler.sourceCount, 100_000)
        let values = sampler.readings
        XCTAssertLessThanOrEqual(values.count, 1202)
        XCTAssertEqual(values.first?.date, start)
        XCTAssertEqual(values.last?.date, start.addingTimeInterval(99_999))
        XCTAssertEqual(values.map(\.value).min(), 30); XCTAssertEqual(values.map(\.value).max(), 220)
        XCTAssertEqual(values.map(\.date), values.map(\.date).sorted())
        sampler.append(RingReading(metric: .heartRate, value: 72, date: start.addingTimeInterval(-1)))
        sampler.append(RingReading(metric: .heartRate, value: .nan, date: start))
        XCTAssertEqual(sampler.sourceCount, 100_000)
    }
    func title(_ metric: RingMetric, _ value: Double, age: Int? = nil, sex: ReferenceSex = .unspecified, context: ReadingContext = .unspecified, maximum: Int? = nil) -> String? {
        MetricReferences.category(for: metric, value: value, profile: ReferenceProfile(age: age, sex: sex, maximumHeartRateOverride: maximum), context: context)?.title
    }
    func testHRVNoLongerUsesPopulationAgeBands() {
        XCTAssertNil(MetricReferences.range(for: .hrv, profile: ReferenceProfile(age: 35)))
        XCTAssertEqual(title(.hrv, 40), "Building baseline")
        XCTAssertEqual(title(.hrv, 40, age: 70), "Building baseline")
        XCTAssertTrue(MetricReferences.rows(for: .hrv, profile: ReferenceProfile(age: 35)).isEmpty)
    }
    func testAdultBreathingRangeDoesNotDependOnDemographics() {
        for age in [nil, 18, 50, 65, 80] as [Int?] {
            XCTAssertEqual(MetricReferences.range(for: .respiration, profile: ReferenceProfile(age: age)), 12...20)
            for (value, expected) in [(11.9,"Below typical"),(12,"Typical range"),(20,"Typical range"),(20.1,"Above typical")] {
                XCTAssertEqual(title(.respiration, value, age: age), expected)
            }
        }
        XCTAssertEqual(title(.respiration, 0), "Outside reference")
    }
    func testPersonalHRVBaselineRequiresDistinctPriorDaysAndExcludesCurrentAndOldSamples() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        func reading(_ days: Int, _ value: Double, hour: Int = 1, observation: Bool = false) -> RingReading {
            RingReading(metric: .hrv, value: value, date: today.addingTimeInterval(Double(-days * 86400 + hour * 3600)), isObservationTime: observation)
        }
        var samples = (1...6).map { reading($0, Double($0 * 10)) }
        samples += [reading(0, 200), reading(29, 200), reading(7, 200, observation: true), reading(7, 0), reading(-1, 200)]
        let building = HRVBaseline(readings: samples, before: today, calendar: cal)
        XCTAssertEqual(building.dayCount, 6); XCTAssertNil(building.range)
        samples.append(reading(7, 70))
        let ready = HRVBaseline(readings: samples, before: today, calendar: cal)
        XCTAssertEqual(ready.dayCount, 7); XCTAssertEqual(ready.median, 40)
        XCTAssertEqual(ready.range, 25...55)
        XCTAssertEqual(ready.category(value: 24).title, "Below your usual")
        XCTAssertEqual(ready.category(value: 25).title, "Within your usual")
        XCTAssertEqual(ready.category(value: 55).title, "Within your usual")
        XCTAssertEqual(ready.category(value: 56).title, "Above your usual")
        XCTAssertEqual(ready.category(value: 0).title, "Outside reference")
        samples += Array(repeating: reading(7, 70), count: 100)
        XCTAssertEqual(HRVBaseline(readings: samples, before: today, calendar: cal).median, 40)
    }
    func testHRVDailyMediansGiveDaysEqualWeightAcrossDST() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        var samples: [RingReading] = []
        for offset in 1...7 {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            for hour in 1...(offset == 1 ? 20 : 1) {
                samples.append(RingReading(metric: .hrv, value: offset == 1 ? 200 : 40, date: day.addingTimeInterval(Double(hour * 3600))))
            }
        }
        let baseline = HRVBaseline(readings: samples, before: today, calendar: cal)
        XCTAssertEqual(baseline.dayCount, 7); XCTAssertEqual(baseline.median, 40)
    }
    func testSleepGuidanceAgeBoundariesAndIncompleteRecordingLabels() {
        XCTAssertNil(SleepDurationReference(profile: ReferenceProfile()))
        for (age, maximum): (Int, Double?) in [(18,nil),(60,nil),(61,9),(64,9),(65,8),(90,8)] {
            let guidance = SleepDurationReference(profile: ReferenceProfile(age: age))!
            XCTAssertEqual(guidance.minimumHours, 7); XCTAssertEqual(guidance.maximumHours, maximum)
            XCTAssertEqual(guidance.category(recordedSeconds: 7 * 3600 - 1)?.title, "Below recommended duration")
            XCTAssertEqual(guidance.category(recordedSeconds: 7 * 3600)?.title, "Recommended duration met")
            XCTAssertNil(guidance.category(recordedSeconds: 0))
            if let maximum {
                XCTAssertEqual(guidance.category(recordedSeconds: maximum * 3600)?.title, "Recommended duration met")
                XCTAssertEqual(guidance.category(recordedSeconds: maximum * 3600 + 1)?.title, "Above recommended duration")
            } else { XCTAssertEqual(guidance.category(recordedSeconds: 10 * 3600)?.title, "Recommended duration met") }
        }
    }
    func testEmotionAndFatigueBoundaryCategories() {
        for (value, expected) in [(0,"Low mood index"),(33,"Low mood index"),(34,"Calm range"),(66,"Calm range"),(67,"Joyful range"),(100,"Joyful range")] {
            XCTAssertEqual(title(.mood, Double(value)), expected)
        }
        for (value, expected) in [(0,"Normal"),(29,"Normal"),(30,"Mild"),(59,"Mild"),(60,"Moderate"),(79,"Moderate"),(80,"Severe"),(100,"Severe")] {
            XCTAssertEqual(title(.fatigue, Double(value)), expected)
        }
        XCTAssertEqual(title(.mood, 101), "Outside reference")
        XCTAssertEqual(title(.fatigue, 255), "Outside reference")
    }
    func testStressUsesOnlySuppliedScaleAndPAISupportsScoresAboveEighty() {
        for (value, expected) in [(1,"Relaxed"),(29,"Relaxed"),(30,"Normal"),(59,"Normal"),(60,"Medium"),(79,"Medium"),(80,"High"),(99,"High")] {
            XCTAssertEqual(title(.stress, Double(value)), expected)
        }
        for value in [0,100,255] { XCTAssertEqual(title(.stress, Double(value)), "Outside reference") }
        for (value, expected) in [(0,"Low score"),(24,"Low score"),(25,"Needs improvement"),(49,"Needs improvement"),(50,"Acceptable"),(79,"Acceptable"),(80,"Great"),(90,"Great"),(101,"Great")] {
            XCTAssertEqual(title(.pai, Double(value)), expected)
        }
    }
    func testOxygenNeverReassuresAtNinetyAndRetainsOriginalReferenceTable() {
        XCTAssertEqual(title(.oxygen, 100), "Typical range")
        XCTAssertEqual(title(.oxygen, 95), "Typical range")
        XCTAssertEqual(title(.oxygen, 94), "Below typical")
        XCTAssertEqual(title(.oxygen, 93), "Below typical")
        XCTAssertEqual(title(.oxygen, 92), "Low reading")
        XCTAssertEqual(title(.oxygen, 90), "Low reading")
        XCTAssertEqual(title(.oxygen, 88), "Very low reading")
        XCTAssertEqual(title(.oxygen, 69), "Very low reading")
        XCTAssertEqual(MetricReferences.category(for: .oxygen, value: 90, profile: ReferenceProfile())?.tone, .high)
        XCTAssertEqual(MetricReferences.rows(for: .oxygen, profile: ReferenceProfile()).first?.range, "90–100%")
    }
    func testPulseHistoryIsNotAutomaticallyTreatedAsRestingOrExercise() {
        XCTAssertEqual(title(.heartRate, 55, age: 35, sex: .male), "Choose context")
        XCTAssertEqual(title(.heartRate, 55, age: 35, context: .resting), "Below typical")
    }
    func testAdultRestingReferenceIncludesBothBoundariesWithoutDemographics() {
        for age in [nil, 18, 35, 65, 90] as [Int?] {
            for sex in ReferenceSex.allCases {
                for (value, expected) in [(1.0,"Below typical"),(59.9,"Below typical"),(60,"Typical range"),(80,"Typical range"),(100,"Typical range"),(100.1,"Above typical"),(140,"Above typical")] {
                    XCTAssertEqual(title(.heartRate, value, age: age, sex: sex, context: .resting), expected)
                }
            }
        }
        XCTAssertEqual(title(.heartRate, 0, context: .resting), "Outside reference")
        let rows = MetricReferences.rows(for: .heartRate, profile: ReferenceProfile(), context: .resting)
        XCTAssertEqual(rows.map(\.range), ["<60 bpm", "60–100 bpm", ">100 bpm"])
        XCTAssertEqual(MetricReferences.range(for: .heartRate, profile: ReferenceProfile()), 60...100)
    }
    func testExerciseZonesUseContinuousPercentagesAndMaximumOverride() {
        // Age 20 gives 200 bpm; 121 bpm = 60.5%, which must not fall in a gap.
        for (value, expected) in [(99,"Below warm-up zone"),(100,"Warm-up"),(120,"Warm-up"),(121,"Fat-burning"),(140,"Fat-burning"),(141,"Aerobic"),(160,"Aerobic"),(161,"Anaerobic"),(180,"Anaerobic"),(181,"Extreme"),(200,"Extreme"),(201,"Above estimated maximum")] {
            XCTAssertEqual(title(.heartRate, Double(value), age: 20, context: .exercise), expected)
        }
        XCTAssertEqual(title(.heartRate, 120, age: 60, context: .exercise, maximum: 200), "Warm-up")
        XCTAssertEqual(title(.heartRate, 120, age: 60, context: .exercise), "Aerobic")
        XCTAssertEqual(title(.heartRate, 120, context: .exercise, maximum: 200), "Warm-up")
    }
    func testInvalidAndUnreferencedValuesDoNotAcquireHealthLabels() {
        XCTAssertEqual(title(.stress, .nan), "Outside reference")
        XCTAssertEqual(title(.mood, -.infinity), "Outside reference")
        XCTAssertEqual(title(.pai, -1), "Outside reference")
        XCTAssertNil(title(.steps, 6000))
        XCTAssertNil(ReferenceProfile(age: 200, maximumHeartRateOverride: 500).maximumHeartRate)
    }
}
