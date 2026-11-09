import Foundation
import Combine

@MainActor
final class ReferencePreferences: ObservableObject {
    static let shared = ReferencePreferences()
    @Published private(set) var birthYear: Int
    @Published private var legacyAge: Int
    var age: Int { age(in: Calendar.current.component(.year, from: Date())) }
    func age(in year: Int) -> Int { birthYear > 0 ? year - birthYear : legacyAge }
    @discardableResult
    func saveBirthYear(_ year: Int?, currentYear: Int = Calendar.current.component(.year, from: Date())) -> Bool {
        if let year, !(18...120).contains(currentYear - year) { return false }
        birthYear = year ?? 0
        legacyAge = 0
        defaults.set(birthYear, forKey: "referenceBirthYear")
        defaults.removeObject(forKey: "referenceAge")
        return true
    }
    @Published var sex: ReferenceSex {
        didSet { defaults.set(sex.rawValue, forKey: "referenceSex") }
    }
    @Published var maximumHeartRate: Int {
        didSet { defaults.set(maximumHeartRate, forKey: "referenceMaximumHeartRate") }
    }
    private let defaults: UserDefaults
    var profile: ReferenceProfile {
        ReferenceProfile(age: age, sex: sex, maximumHeartRateOverride: maximumHeartRate)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        birthYear = defaults.integer(forKey: "referenceBirthYear")
        legacyAge = defaults.integer(forKey: "referenceAge")
        sex = ReferenceSex(rawValue: defaults.string(forKey: "referenceSex") ?? "") ?? .unspecified
        maximumHeartRate = defaults.integer(forKey: "referenceMaximumHeartRate")
    }
}
