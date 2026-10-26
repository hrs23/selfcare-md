import HealthKit
import SelfcareCore

struct HealthTypeDef {
    enum Kind {
        case category(HKCategoryTypeIdentifier)
        case quantity(HKQuantityTypeIdentifier)
        case bloodPressure
    }

    let constant: String
    let kind: Kind
    let aggregate: Bool
    let defaultOn: Bool

    var sampleType: HKSampleType {
        switch kind {
        case let .category(id): HKCategoryType(id)
        case let .quantity(id): HKQuantityType(id)
        case .bloodPressure: HKCorrelationType(.bloodPressure)
        }
    }

    var readTypes: [HKObjectType] {
        switch kind {
        case .bloodPressure: [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
        default: [sampleType]
        }
    }
}

enum HealthTypes {
    static let workoutKey = "HKWorkoutType"

    static let others: [HealthTypeDef] = [
        HealthTypeDef(constant: "HKCategoryTypeIdentifierMindfulSession", kind: .category(.mindfulSession), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierBodyMass", kind: .quantity(.bodyMass), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierBodyFatPercentage", kind: .quantity(.bodyFatPercentage), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKCorrelationTypeIdentifierBloodPressure", kind: .bloodPressure, aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierBodyTemperature", kind: .quantity(.bodyTemperature), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierRestingHeartRate", kind: .quantity(.restingHeartRate), aggregate: false, defaultOn: false),
        HealthTypeDef(constant: "HKCategoryTypeIdentifierToothbrushingEvent", kind: .category(.toothbrushingEvent), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKCategoryTypeIdentifierHandwashingEvent", kind: .category(.handwashingEvent), aggregate: false, defaultOn: false),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierDietaryWater", kind: .quantity(.dietaryWater), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages", kind: .quantity(.numberOfAlcoholicBeverages), aggregate: false, defaultOn: true),
        HealthTypeDef(constant: "HKCategoryTypeIdentifierSleepAnalysis", kind: .category(.sleepAnalysis), aggregate: true, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierStepCount", kind: .quantity(.stepCount), aggregate: true, defaultOn: true),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierActiveEnergyBurned", kind: .quantity(.activeEnergyBurned), aggregate: true, defaultOn: false),
        HealthTypeDef(constant: "HKQuantityTypeIdentifierAppleExerciseTime", kind: .quantity(.appleExerciseTime), aggregate: true, defaultOn: false),
    ]

    static func def(_ constant: String) -> HealthTypeDef? {
        others.first { $0.constant == constant }
    }

    static var defaultEnabled: [String] {
        [workoutKey] + others.filter(\.defaultOn).map(\.constant)
    }

    static let distanceTypes: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
        .distanceRowing, .distancePaddleSports, .distanceCrossCountrySkiing, .distanceSkatingSports,
    ]

    static let workoutTypes: [(String, HKWorkoutActivityType)] = [
        ("Running", .running), ("Walking", .walking), ("Hiking", .hiking), ("Cycling", .cycling), ("HandCycling", .handCycling),
        ("Swimming", .swimming), ("WheelchairWalkPace", .wheelchairWalkPace), ("WheelchairRunPace", .wheelchairRunPace),
        ("Rowing", .rowing), ("PaddleSports", .paddleSports), ("CrossCountrySkiing", .crossCountrySkiing),
        ("DownhillSkiing", .downhillSkiing), ("Snowboarding", .snowboarding), ("SkatingSports", .skatingSports),
        ("SwimBikeRun", .swimBikeRun), ("Elliptical", .elliptical), ("StairClimbing", .stairClimbing), ("Stairs", .stairs),
        ("StepTraining", .stepTraining), ("HighIntensityIntervalTraining", .highIntensityIntervalTraining),
        ("MixedCardio", .mixedCardio), ("JumpRope", .jumpRope), ("CrossTraining", .crossTraining),
        ("FunctionalStrengthTraining", .functionalStrengthTraining), ("TraditionalStrengthTraining", .traditionalStrengthTraining),
        ("CoreTraining", .coreTraining), ("Yoga", .yoga), ("Pilates", .pilates), ("Barre", .barre), ("Flexibility", .flexibility),
        ("MindAndBody", .mindAndBody), ("TaiChi", .taiChi), ("Cooldown", .cooldown), ("PreparationAndRecovery", .preparationAndRecovery),
        ("CardioDance", .cardioDance), ("SocialDance", .socialDance), ("Kickboxing", .kickboxing), ("Boxing", .boxing),
        ("MartialArts", .martialArts), ("Wrestling", .wrestling), ("Fencing", .fencing), ("Climbing", .climbing),
        ("Gymnastics", .gymnastics), ("TrackAndField", .trackAndField), ("FitnessGaming", .fitnessGaming), ("Play", .play),
        ("WaterFitness", .waterFitness), ("WaterPolo", .waterPolo), ("WaterSports", .waterSports), ("SurfingSports", .surfingSports),
        ("Sailing", .sailing), ("UnderwaterDiving", .underwaterDiving), ("SnowSports", .snowSports), ("Curling", .curling),
        ("Hockey", .hockey), ("AmericanFootball", .americanFootball), ("AustralianFootball", .australianFootball),
        ("Soccer", .soccer), ("Rugby", .rugby), ("Basketball", .basketball), ("Volleyball", .volleyball), ("Handball", .handball),
        ("Lacrosse", .lacrosse), ("Baseball", .baseball), ("Softball", .softball), ("Cricket", .cricket), ("Tennis", .tennis),
        ("TableTennis", .tableTennis), ("Badminton", .badminton), ("Squash", .squash), ("Racquetball", .racquetball),
        ("Pickleball", .pickleball), ("DiscSports", .discSports), ("Golf", .golf), ("Archery", .archery), ("Bowling", .bowling),
        ("EquestrianSports", .equestrianSports), ("Fishing", .fishing), ("Hunting", .hunting), ("Transition", .transition),
        ("Other", .other),
    ]

    static func constant(for type: HKWorkoutActivityType) -> String? {
        workoutTypes.first { $0.1 == type }.map { "HKWorkoutActivityType" + $0.0 }
    }

    static func activityType(for constant: String) -> HKWorkoutActivityType? {
        guard constant.hasPrefix("HKWorkoutActivityType") else { return nil }
        let suffix = String(constant.dropFirst("HKWorkoutActivityType".count))
        return workoutTypes.first { $0.0 == suffix }?.1
    }

    static let asleepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]
}
