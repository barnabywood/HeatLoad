import Foundation

public enum HeatActivityType: String, CaseIterable, Codable, Identifiable {
    case sauna
    case steamRoom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sauna: return "Sauna"
        case .steamRoom: return "Steam Room"
        }
    }
}

public struct HeartRateReading: Codable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let bpm: Double

    public init(id: UUID = UUID(), timestamp: Date, bpm: Double) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

public struct HeatSession: Codable, Identifiable {
    public let id: UUID
    public let activityType: HeatActivityType
    public let startDate: Date
    public let endDate: Date
    public let hadColdShower: Bool
    public let plannedDurationSeconds: Int
    public let averageHeartRate: Double
    public let maxHeartRate: Double
    public let activeCalories: Double
    public let totalCalories: Double

    public init(
        id: UUID = UUID(),
        activityType: HeatActivityType,
        startDate: Date,
        endDate: Date,
        hadColdShower: Bool,
        plannedDurationSeconds: Int,
        averageHeartRate: Double,
        maxHeartRate: Double,
        activeCalories: Double = 0,
        totalCalories: Double = 0
    ) {
        self.id = id
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.hadColdShower = hadColdShower
        self.plannedDurationSeconds = plannedDurationSeconds
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.activeCalories = activeCalories
        self.totalCalories = totalCalories
    }

    public var actualDurationSeconds: Int {
        max(0, Int(endDate.timeIntervalSince(startDate)))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case activityType
        case startDate
        case endDate
        case hadColdShower
        case plannedDurationSeconds
        case averageHeartRate
        case maxHeartRate
        case activeCalories
        case totalCalories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        activityType = try container.decode(HeatActivityType.self, forKey: .activityType)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        hadColdShower = try container.decode(Bool.self, forKey: .hadColdShower)
        plannedDurationSeconds = try container.decode(Int.self, forKey: .plannedDurationSeconds)
        averageHeartRate = try container.decode(Double.self, forKey: .averageHeartRate)
        maxHeartRate = try container.decode(Double.self, forKey: .maxHeartRate)
        activeCalories = try container.decodeIfPresent(Double.self, forKey: .activeCalories) ?? 0
        totalCalories = try container.decodeIfPresent(Double.self, forKey: .totalCalories) ?? 0
    }
}
