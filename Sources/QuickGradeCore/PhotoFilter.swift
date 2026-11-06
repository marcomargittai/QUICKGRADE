import Foundation

/// The filter strip from iOS Photos. Strength is separate, so 0 is the photo and 100 is the full look.
public enum PhotoFilter: String, Codable, CaseIterable, Identifiable, Equatable {
    case original
    case vivid
    case vividWarm
    case vividCool
    case dramatic
    case dramaticWarm
    case dramaticCool
    case mono
    case silvertone
    case noir

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .vividWarm: return "Vivid Warm"
        case .vividCool: return "Vivid Cool"
        case .dramatic: return "Dramatic"
        case .dramaticWarm: return "Dramatic Warm"
        case .dramaticCool: return "Dramatic Cool"
        case .mono: return "Mono"
        case .silvertone: return "Silvertone"
        case .noir: return "Noir"
        }
    }
}
