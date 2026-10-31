import Foundation

public enum Field: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case weight
    case reps
    case distance
    case duration
    case heartRate = "heart-rate"
    case percent
    case bloodPressure = "blood-pressure"
    case volume
    case energy
    case temperature

    public var id: String { rawValue }

    public static func sorted<S: Sequence>(_ fields: S) -> [Field] where S.Element == Field {
        let set = Set(fields)
        return allCases.filter { set.contains($0) }
    }
}

public enum WeightUnit: String, CaseIterable, Sendable, Codable {
    case kg, lb
    var kilograms: Double { self == .kg ? 1 : 0.45359237 }
}

public enum DistanceUnit: String, CaseIterable, Sendable, Codable {
    case km, mi, m, yd
    var meters: Double {
        switch self {
        case .km: 1000
        case .mi: 1609.344
        case .m: 1
        case .yd: 0.9144
        }
    }
    var isLarge: Bool { self == .km || self == .mi }
}

public enum VolumeUnit: String, CaseIterable, Sendable, Codable {
    case ml, l, floz
    var milliliters: Double {
        switch self {
        case .ml: 1
        case .l: 1000
        case .floz: 29.5735295625
        }
    }
}

public enum TemperatureUnit: String, CaseIterable, Sendable, Codable {
    case celsius = "°C"
    case fahrenheit = "°F"
}

public struct UnitPreferences: Sendable, Codable, Hashable {
    public var weight: WeightUnit
    public var distance: DistanceUnit
    public var volume: VolumeUnit
    public var temperature: TemperatureUnit

    public init(weight: WeightUnit = .kg, distance: DistanceUnit = .km, volume: VolumeUnit = .ml, temperature: TemperatureUnit = .celsius) {
        self.weight = weight
        self.distance = distance
        self.volume = volume
        self.temperature = temperature
    }

    public static func defaults(for locale: Locale) -> UnitPreferences {
        switch locale.measurementSystem {
        case .us:
            UnitPreferences(weight: .lb, distance: .mi, volume: .floz, temperature: .fahrenheit)
        case .uk:
            UnitPreferences(weight: .kg, distance: .mi, volume: .ml, temperature: .celsius)
        default:
            UnitPreferences()
        }
    }
}

public enum Quantity: Hashable, Sendable {
    case weight(Double, WeightUnit)
    case reps(Int)
    case distance(Double, DistanceUnit)
    case duration(Int)
    case heartRate(Double)
    case percent(Double)
    case bloodPressure(Int, Int)
    case volume(Double, VolumeUnit)
    case energy(Double)
    case temperature(Double, TemperatureUnit)

    public var field: Field {
        switch self {
        case .weight: .weight
        case .reps: .reps
        case .distance: .distance
        case .duration: .duration
        case .heartRate: .heartRate
        case .percent: .percent
        case .bloodPressure: .bloodPressure
        case .volume: .volume
        case .energy: .energy
        case .temperature: .temperature
        }
    }

    public var text: String {
        switch self {
        case let .weight(v, u): NumberText.format(v, max: 2) + u.rawValue
        case let .reps(n): String(n)
        case let .distance(v, u): (u.isLarge ? NumberText.format(v, max: 2, min: 1) : NumberText.format(v, max: 0)) + u.rawValue
        case let .duration(s): DurationText.format(s)
        case let .heartRate(v): NumberText.format(v, max: 0) + "bpm"
        case let .percent(v): NumberText.format(v, max: 1) + "%"
        case let .bloodPressure(a, b): "\(a)/\(b)mmHg"
        case let .volume(v, u): NumberText.format(v, max: u == .ml ? 0 : 2) + u.rawValue
        case let .energy(v): NumberText.format(v, max: 0) + "kcal"
        case let .temperature(v, u): NumberText.format(v, max: 1) + u.rawValue
        }
    }

    public static func zero(_ field: Field, units: UnitPreferences) -> Quantity {
        switch field {
        case .weight: .weight(0, units.weight)
        case .reps: .reps(0)
        case .distance: .distance(0, units.distance)
        case .duration: .duration(0)
        case .heartRate: .heartRate(0)
        case .percent: .percent(0)
        case .bloodPressure: .bloodPressure(120, 80)
        case .volume: .volume(0, units.volume)
        case .energy: .energy(0)
        case .temperature: .temperature(units.temperature == .celsius ? 36.5 : 97.7, units.temperature)
        }
    }

    public func converted(to units: UnitPreferences) -> Quantity {
        switch self {
        case let .weight(v, u):
            return .weight(v * u.kilograms / units.weight.kilograms, units.weight)
        case let .distance(v, u):
            return .distance(v * u.meters / units.distance.meters, units.distance)
        case let .volume(v, u):
            return .volume(v * u.milliliters / units.volume.milliliters, units.volume)
        case let .temperature(v, u):
            if u == units.temperature { return self }
            return .temperature(u == .celsius ? v * 9 / 5 + 32 : (v - 32) * 5 / 9, units.temperature)
        default:
            return self
        }
    }

    public var numbers: [Double] {
        switch self {
        case let .weight(v, _): [v]
        case let .reps(n): [Double(n)]
        case let .distance(v, _): [v]
        case let .duration(s): [Double(s)]
        case let .heartRate(v): [v]
        case let .percent(v): [v]
        case let .bloodPressure(a, b): [Double(a), Double(b)]
        case let .volume(v, _): [v]
        case let .energy(v): [v]
        case let .temperature(v, _): [v]
        }
    }

    public var unitText: String {
        switch self {
        case let .weight(_, u): u.rawValue
        case .reps: ""
        case let .distance(_, u): u.rawValue
        case .duration: ""
        case .heartRate: "bpm"
        case .percent: "%"
        case .bloodPressure: "mmHg"
        case let .volume(_, u): u.rawValue
        case .energy: "kcal"
        case let .temperature(_, u): u.rawValue
        }
    }

    public func stepped(_ direction: Int, part: Int = 0) -> Quantity {
        let d = Double(direction)
        switch self {
        case let .weight(v, u):
            let step = u == .kg ? 2.5 : 5
            return .weight(Self.snap(v + d * step, step), u)
        case let .reps(n):
            return .reps(max(0, n + direction))
        case let .distance(v, u):
            let step = u.isLarge ? 0.1 : 100
            return .distance(max(0, Self.snap(v + d * step, step)), u)
        case let .duration(s):
            if direction > 0 {
                let step = s < 60 ? 5 : (s < 600 ? 15 : 60)
                return .duration((s / step + 1) * step)
            }
            let step = s <= 60 ? 5 : (s <= 600 ? 15 : 60)
            return .duration(max(0, ((s + step - 1) / step - 1) * step))
        case let .heartRate(v):
            return .heartRate(max(0, v.rounded() + d))
        case let .percent(v):
            return .percent(max(0, Self.snap(v + d * 0.1, 0.1)))
        case let .bloodPressure(a, b):
            return part == 0 ? .bloodPressure(max(0, a + direction), b) : .bloodPressure(a, max(0, b + direction))
        case let .volume(v, u):
            let step: Double = u == .ml ? 50 : (u == .l ? 0.1 : 1)
            return .volume(max(0, Self.snap(v + d * step, step)), u)
        case let .energy(v):
            return .energy(max(0, Self.snap(v + d * 10, 10)))
        case let .temperature(v, u):
            return .temperature(Self.snap(v + d * 0.1, 0.1), u)
        }
    }

    private static func snap(_ v: Double, _ step: Double) -> Double {
        (v / step).rounded() * step
    }
}

public struct Value: Hashable, Sendable {
    public private(set) var quantities: [Field: Quantity]

    public init(_ quantities: [Quantity] = []) {
        var map: [Field: Quantity] = [:]
        for q in quantities { map[q.field] = q }
        self.quantities = map
    }

    public var isEmpty: Bool { quantities.isEmpty }
    public var fields: [Field] { Field.sorted(quantities.keys) }
    public var ordered: [Quantity] { fields.compactMap { quantities[$0] } }
    public var text: String { ordered.map(\.text).joined(separator: " × ") }

    public subscript(field: Field) -> Quantity? {
        get { quantities[field] }
        set {
            if let newValue {
                quantities[field] = newValue
            } else {
                quantities[field] = nil
            }
        }
    }

    public func restricted(to fields: [Field]) -> Value {
        Value(ordered.filter { fields.contains($0.field) })
    }

    public func converted(to units: UnitPreferences) -> Value {
        Value(ordered.map { $0.converted(to: units) })
    }
}

public enum ValueError: Error, Equatable, Sendable {
    case unreadable(String)
}

public enum ValueParser {
    public static func parse(_ raw: String) -> Result<Value, ValueError> {
        let text = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .success(Value()) }
        let tokens = text.split(omittingEmptySubsequences: false, whereSeparator: { "×xX*".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<Field>()
        var result: [Quantity] = []
        for token in tokens {
            guard let q = quantity(token) else { return .failure(.unreadable(raw)) }
            if seen.contains(q.field) { return .failure(.unreadable(raw)) }
            seen.insert(q.field)
            result.append(q)
        }
        return .success(Value(result))
    }

    public static func value(_ raw: String) -> Value? {
        try? parse(raw).get()
    }

    static func quantity(_ token: String) -> Quantity? {
        if token.isEmpty { return nil }
        if token.contains(":") { return clock(token) }
        if token.contains("/") { return pressure(token) }
        var numberEnd = token.startIndex
        var sawDigit = false
        var sawDot = false
        var index = token.startIndex
        if token[index] == "-" || token[index] == "+" { index = token.index(after: index) }
        while index < token.endIndex {
            let c = token[index]
            if c.isASCII, c.isNumber {
                sawDigit = true
            } else if c == ".", !sawDot {
                sawDot = true
            } else {
                break
            }
            index = token.index(after: index)
        }
        numberEnd = index
        guard sawDigit else { return nil }
        let numberText = String(token[token.startIndex..<numberEnd])
        guard numberText.last != ".", let number = Double(numberText) else { return nil }
        let unit = token[numberEnd...].trimmingCharacters(in: .whitespaces).lowercased()
        let negative = number < 0
        let isInteger = !sawDot
        switch unit {
        case "":
            guard isInteger, !negative, let n = Int(numberText.replacingOccurrences(of: "+", with: "")) else { return nil }
            return .reps(n)
        case "kg": return .weight(number, .kg)
        case "lb", "lbs": return .weight(number, .lb)
        default: break
        }
        if negative { return nil }
        switch unit {
        case "km": return .distance(number, .km)
        case "mi": return .distance(number, .mi)
        case "m": return .distance(number, .m)
        case "yd": return .distance(number, .yd)
        case "s":
            guard isInteger, let n = Int(numberText.replacingOccurrences(of: "+", with: "")) else { return nil }
            return .duration(n)
        case "bpm": return .heartRate(number)
        case "%": return .percent(number)
        case "ml": return .volume(number, .ml)
        case "l": return .volume(number, .l)
        case "floz", "fl oz": return .volume(number, .floz)
        case "kcal": return .energy(number)
        case "°c": return .temperature(number, .celsius)
        case "°f": return .temperature(number, .fahrenheit)
        default: return nil
        }
    }

    static func clock(_ token: String) -> Quantity? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        guard parts.last!.count == 2, numbers.last! < 60 else { return nil }
        if numbers.count == 2 {
            return .duration(numbers[0] * 60 + numbers[1])
        }
        guard parts[1].count == 2, numbers[1] < 60 else { return nil }
        return .duration(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    static func pressure(_ token: String) -> Quantity? {
        let lower = token.lowercased()
        guard lower.hasSuffix("mmhg") else { return nil }
        let body = lower.dropLast(4).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 0, b >= 0 else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return .bloodPressure(a, b)
    }
}

public enum NumberText {
    public static func format(_ value: Double, max: Int, min: Int = 0) -> String {
        let factor = pow(10.0, Double(max))
        var rounded = (value * factor).rounded() / factor
        if rounded == 0 { rounded = 0 }
        var text = String(format: "%.\(max)f", rounded)
        if max > min, text.contains(".") {
            while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) - 1 > min {
                text.removeLast()
            }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }
}

public enum DurationText {
    public static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
}
