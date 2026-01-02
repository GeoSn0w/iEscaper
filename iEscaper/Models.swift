import Foundation
import SwiftUI

struct Device: Identifiable {
    let id = UUID()
    let udid: String
    let name: String
    let model: String
    let version: String
    let buildVersion: String
    let productType: String
    
    var displayName: String {
        "\(name) (\(model) - iOS \(version)) - \(udid)"
    }
}

enum PatchOperation: String, CaseIterable {
    case enableIPad = "Enable iPadOS Mode"
    case restoreIPhone = "Restore iPhone Mode"
    case useAsIs = "Use file as-is"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let timestamp: String
    
    init(message: String, level: LogLevel) {
        self.message = message
        self.level = level
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.timestamp = formatter.string(from: Date())
    }
}

enum LogLevel {
    case normal
    case info
    case warning
    case error
    case success
    
    var color: Color {
        switch self {
        case .normal: return .primary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

struct MobileGestaltData: Codable {
    var cacheData: Data?
    var cacheExtra: [String: Any]
    var cacheVersion: String?
    
    enum CodingKeys: String, CodingKey {
        case cacheData = "CacheData"
        case cacheExtra = "CacheExtra"
        case cacheVersion = "CacheVersion"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheData = try container.decodeIfPresent(Data.self, forKey: .cacheData)
        cacheVersion = try container.decodeIfPresent(String.self, forKey: .cacheVersion)
        
        if let extraDict = try? container.decode([String: AnyCodable].self, forKey: .cacheExtra) {
            cacheExtra = extraDict.mapValues { $0.value }
        } else {
            cacheExtra = [:]
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cacheData, forKey: .cacheData)
        try container.encodeIfPresent(cacheVersion, forKey: .cacheVersion)
        
        let codableDict = cacheExtra.mapValues { AnyCodable($0) }
        try container.encode(codableDict, forKey: .cacheExtra)
    }
}

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
