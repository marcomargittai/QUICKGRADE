import Foundation

public enum GradePage: String, CaseIterable, Identifiable, Codable {
    case light
    case whiteBalance
    case hsl
    case style
    case curves
    case filters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "Light"
        case .whiteBalance: return "WB"
        case .hsl: return "HSL"
        case .style: return "Style"
        case .curves: return "Curves"
        case .filters: return "Filters"
        }
    }

    public var subtitle: String {
        switch self {
        case .light: return "Tone and color"
        case .whiteBalance: return "Color of the light"
        case .hsl: return "One color at a time"
        case .style: return "Finish"
        case .curves: return "Shape the tones"
        case .filters: return "Looks"
        }
    }

    public var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .whiteBalance: return "thermometer.medium"
        case .hsl: return "circle.hexagongrid.fill"
        case .style: return "sparkles"
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .filters: return "camera.filters"
        }
    }
}

public enum HSLBand: Int, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }

    /// Display color for the chip, sRGB 0...1.
    public var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (0.93, 0.27, 0.24)
        case .orange: return (0.96, 0.55, 0.18)
        case .yellow: return (0.93, 0.80, 0.22)
        case .green: return (0.32, 0.76, 0.38)
        case .aqua: return (0.22, 0.76, 0.78)
        case .blue: return (0.28, 0.48, 0.95)
        case .purple: return (0.60, 0.36, 0.92)
        case .magenta: return (0.90, 0.32, 0.62)
        }
    }
}

public struct HSLAdjustment: Codable, Equatable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public static let zero = HSLAdjustment()

    public var isZero: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

public struct CurvePoint: Identifiable, Codable {
    public var id: UUID
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }

    public static func == (lhs: CurvePoint, rhs: CurvePoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.000_001 && abs(lhs.y - rhs.y) < 0.000_001
    }
}

extension CurvePoint: Equatable {}

public struct ToneCurve: Codable, Equatable {
    public var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points
    }

    public static var identity: ToneCurve {
        ToneCurve(points: [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 1, y: 1)
        ])
    }

    public var isIdentity: Bool {
        guard points.count == 2 else { return false }
        let sorted = points.sorted { $0.x < $1.x }
        return abs(sorted[0].x) < 0.000_001 && abs(sorted[0].y) < 0.000_001
            && abs(sorted[1].x - 1) < 0.000_001 && abs(sorted[1].y - 1) < 0.000_001
    }
}

public enum CurveChannel: String, CaseIterable, Identifiable, Codable {
    case rgb, red, green, blue

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }

    public var rgb: (Double, Double, Double) {
        switch self {
        case .rgb: return (0.92, 0.92, 0.92)
        case .red: return (0.95, 0.34, 0.31)
        case .green: return (0.36, 0.82, 0.42)
        case .blue: return (0.36, 0.55, 0.98)
        }
    }
}

public struct CurveSet: Codable, Equatable {
    public var rgb: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve

    public init(rgb: ToneCurve = .identity, red: ToneCurve = .identity, green: ToneCurve = .identity, blue: ToneCurve = .identity) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = CurveSet()

    public var isIdentity: Bool {
        rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    public subscript(channel: CurveChannel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: return rgb
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}

public enum ValueDisplay {
    case signedHundred
    case unsignedHundred
    case exposure
}

public struct ControlSpec: Identifiable {
    public let id: String
    public let name: String
    public let symbol: String
    public let keyPath: WritableKeyPath<GradeSettings, Double>
    public let range: ClosedRange<Double>
    public let baseline: Double
    public let bipolar: Bool
    public let display: ValueDisplay

    public var snapDistance: Double {
        max((range.upperBound - range.lowerBound) * 0.018, display == .exposure ? 0.035 : 1.6)
    }

    public func format(_ value: Double) -> String {
        if abs(value - baseline) < 0.000_001 { return "0" }
        switch display {
        case .exposure:
            return String(format: "%+.2f", value)
        case .signedHundred:
            return String(format: "%+.0f", value)
        case .unsignedHundred:
            return String(format: "%.0f", value)
        }
    }
}

public struct GradeSettings: Codable, Equatable {
    public var exposure: Double
    public var clarity: Double
    public var highlights: Double
    public var shadows: Double
    public var contrast: Double
    public var definition: Double
    public var brightness: Double
    public var whites: Double
    public var blacks: Double
    public var saturation: Double
    public var vibrance: Double
    public var temperature: Double
    public var tint: Double
    public var hsl: [HSLAdjustment]
    public var sharpen: Double
    public var noiseReduction: Double
    public var fade: Double
    public var vignette: Double
    public var grainShadows: Double
    public var grainMidtones: Double
    public var grainHighlights: Double
    public var filter: PhotoFilter
    public var filterStrength: Double
    public var curves: CurveSet
    public var crop: CropEdit
    /// Pen strokes drawn over the finished photo.
    public var markup: [MarkupStroke]

    public init(
        exposure: Double = 0,
        clarity: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        contrast: Double = 0,
        definition: Double = 0,
        brightness: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        saturation: Double = 0,
        vibrance: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        hsl: [HSLAdjustment] = Array(repeating: .zero, count: HSLBand.allCases.count),
        sharpen: Double = 0,
        noiseReduction: Double = 0,
        fade: Double = 0,
        vignette: Double = 0,
        grainShadows: Double = 0,
        grainMidtones: Double = 0,
        grainHighlights: Double = 0,
        filter: PhotoFilter = .original,
        filterStrength: Double = 100,
        curves: CurveSet = .identity,
        crop: CropEdit = .identity,
        markup: [MarkupStroke] = []
    ) {
        self.exposure = exposure
        self.clarity = clarity
        self.highlights = highlights
        self.shadows = shadows
        self.contrast = contrast
        self.definition = definition
        self.brightness = brightness
        self.whites = whites
        self.blacks = blacks
        self.saturation = saturation
        self.vibrance = vibrance
        self.temperature = temperature
        self.tint = tint
        self.hsl = hsl.count == HSLBand.allCases.count ? hsl : Array(repeating: .zero, count: HSLBand.allCases.count)
        self.sharpen = sharpen
        self.noiseReduction = noiseReduction
        self.fade = fade
        self.vignette = vignette
        self.grainShadows = grainShadows
        self.grainMidtones = grainMidtones
        self.grainHighlights = grainHighlights
        self.filter = filter
        self.filterStrength = min(max(filterStrength, 0), 100)
        self.curves = curves
        self.crop = crop
        self.markup = markup
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, clarity, highlights, shadows, contrast, definition, brightness, whites, blacks
        case saturation, vibrance, temperature, tint, hsl, sharpen, noiseReduction, fade, vignette
        case grainShadows, grainMidtones, grainHighlights, filter, filterStrength, curves, crop, markup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            exposure: container.decode(Double.self, forKey: .exposure),
            clarity: container.decode(Double.self, forKey: .clarity),
            highlights: container.decode(Double.self, forKey: .highlights),
            shadows: container.decode(Double.self, forKey: .shadows),
            contrast: container.decode(Double.self, forKey: .contrast),
            definition: container.decodeIfPresent(Double.self, forKey: .definition) ?? 0,
            brightness: container.decode(Double.self, forKey: .brightness),
            whites: container.decode(Double.self, forKey: .whites),
            blacks: container.decode(Double.self, forKey: .blacks),
            saturation: container.decode(Double.self, forKey: .saturation),
            vibrance: container.decode(Double.self, forKey: .vibrance),
            temperature: container.decode(Double.self, forKey: .temperature),
            tint: container.decode(Double.self, forKey: .tint),
            hsl: container.decode([HSLAdjustment].self, forKey: .hsl),
            sharpen: container.decode(Double.self, forKey: .sharpen),
            noiseReduction: container.decode(Double.self, forKey: .noiseReduction),
            fade: container.decode(Double.self, forKey: .fade),
            vignette: container.decode(Double.self, forKey: .vignette),
            grainShadows: container.decode(Double.self, forKey: .grainShadows),
            grainMidtones: container.decode(Double.self, forKey: .grainMidtones),
            grainHighlights: container.decode(Double.self, forKey: .grainHighlights),
            filter: container.decodeIfPresent(PhotoFilter.self, forKey: .filter) ?? .original,
            filterStrength: container.decodeIfPresent(Double.self, forKey: .filterStrength) ?? 100,
            curves: container.decode(CurveSet.self, forKey: .curves),
            crop: container.decodeIfPresent(CropEdit.self, forKey: .crop) ?? .identity,
            markup: container.decodeIfPresent([MarkupStroke].self, forKey: .markup) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(definition, forKey: .definition)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(sharpen, forKey: .sharpen)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(fade, forKey: .fade)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(grainShadows, forKey: .grainShadows)
        try container.encode(grainMidtones, forKey: .grainMidtones)
        try container.encode(grainHighlights, forKey: .grainHighlights)
        try container.encode(filter, forKey: .filter)
        try container.encode(filterStrength, forKey: .filterStrength)
        try container.encode(curves, forKey: .curves)
        try container.encode(crop, forKey: .crop)
        try container.encode(markup, forKey: .markup)
    }

    public static let neutral = GradeSettings()

    public var isNeutral: Bool { self == .neutral }

    public func adjustment(for band: HSLBand) -> HSLAdjustment {
        guard hsl.indices.contains(band.rawValue) else { return .zero }
        return hsl[band.rawValue]
    }

    public mutating func setAdjustment(_ value: HSLAdjustment, for band: HSLBand) {
        if hsl.count != HSLBand.allCases.count {
            hsl = Array(repeating: .zero, count: HSLBand.allCases.count)
        }
        hsl[band.rawValue] = value
    }

    public var hslIsNeutral: Bool { hsl.allSatisfy(\.isZero) }

    public func isPageNeutral(_ page: GradePage) -> Bool {
        switch page {
        case .light:
            return exposure == 0 && clarity == 0 && highlights == 0 && shadows == 0
                && contrast == 0 && definition == 0 && brightness == 0 && whites == 0 && blacks == 0
                && saturation == 0 && vibrance == 0
        case .whiteBalance:
            return temperature == 0 && tint == 0
        case .hsl:
            return hslIsNeutral
        case .style:
            return sharpen == 0 && noiseReduction == 0 && fade == 0 && vignette == 0
                && grainShadows == 0 && grainMidtones == 0 && grainHighlights == 0
        case .curves:
            return curves.isIdentity
        case .filters:
            return filter == .original
        }
    }

    public mutating func reset(_ page: GradePage) {
        switch page {
        case .light:
            exposure = 0
            clarity = 0
            highlights = 0
            shadows = 0
            contrast = 0
            definition = 0
            brightness = 0
            whites = 0
            blacks = 0
            saturation = 0
            vibrance = 0
        case .whiteBalance:
            temperature = 0
            tint = 0
        case .hsl:
            hsl = Array(repeating: .zero, count: HSLBand.allCases.count)
        case .style:
            sharpen = 0
            noiseReduction = 0
            fade = 0
            vignette = 0
            grainShadows = 0
            grainMidtones = 0
            grainHighlights = 0
        case .curves:
            curves = .identity
        case .filters:
            filter = .original
            filterStrength = 100
        }
    }

    /// Point operations that live in the color cube. Temperature stays on CITemperatureAndTint.
    public var needsColorCube: Bool {
        exposure != 0 || brightness != 0 || contrast != 0 || highlights != 0 || shadows != 0
            || whites != 0 || blacks != 0 || saturation != 0 || vibrance != 0 || fade != 0
            || !curves.isIdentity || !hslIsNeutral
    }

    public static let lightControls: [ControlSpec] = [
        spec("exposure", "Exposure", "sun.max", \.exposure, -2...2, bipolar: true, display: .exposure),
        spec("clarity", "Clarity", "circle.lefthalf.filled", \.clarity, -100...100, bipolar: true, display: .signedHundred),
        spec("highlights", "Highlights", "sun.and.horizon", \.highlights, -100...100, bipolar: true, display: .signedHundred),
        spec("shadows", "Shadows", "shadow", \.shadows, -100...100, bipolar: true, display: .signedHundred),
        spec("contrast", "Contrast", "circle.righthalf.filled", \.contrast, -100...100, bipolar: true, display: .signedHundred),
        spec("definition", "Definition", "circle.circle", \.definition, -100...100, bipolar: true, display: .signedHundred),
        spec("brightness", "Brightness", "sun.min", \.brightness, -100...100, bipolar: true, display: .signedHundred),
        spec("whites", "Whites", "circle.tophalf.filled", \.whites, -100...100, bipolar: true, display: .signedHundred),
        spec("blacks", "Blacks", "circle.bottomhalf.filled", \.blacks, -100...100, bipolar: true, display: .signedHundred),
        spec("saturation", "Saturation", "drop.fill", \.saturation, -100...100, bipolar: true, display: .signedHundred),
        spec("vibrance", "Vibrance", "paintpalette", \.vibrance, -100...100, bipolar: true, display: .signedHundred)
    ]

    public static let whiteBalanceControls: [ControlSpec] = [
        spec("temperature", "Temperature", "thermometer.medium", \.temperature, -100...100, bipolar: true, display: .signedHundred),
        spec("tint", "Tint", "paintbrush.pointed", \.tint, -100...100, bipolar: true, display: .signedHundred)
    ]

    public static let styleControls: [ControlSpec] = [
        spec("sharpen", "Sharpen", "triangle", \.sharpen, 0...100, bipolar: false, display: .unsignedHundred),
        spec("noiseReduction", "Noise", "sparkle", \.noiseReduction, 0...100, bipolar: false, display: .unsignedHundred),
        spec("fade", "Fade", "moonphase.waxing.crescent", \.fade, 0...100, bipolar: false, display: .unsignedHundred),
        spec("vignette", "Vignette", "circle.dashed", \.vignette, 0...100, bipolar: false, display: .unsignedHundred)
    ]

    public static let grainControls: [ControlSpec] = [
        spec("grainShadows", "Dark", "moon.fill", \.grainShadows, 0...100, bipolar: false, display: .unsignedHundred),
        spec("grainMidtones", "Mid", "circle.lefthalf.filled", \.grainMidtones, 0...100, bipolar: false, display: .unsignedHundred),
        spec("grainHighlights", "Light", "sun.max.fill", \.grainHighlights, 0...100, bipolar: false, display: .unsignedHundred)
    ]

    public static let hslControls: [(name: String, symbol: String, keyPath: WritableKeyPath<HSLAdjustment, Double>)] = [
        ("Hue", "paintpalette", \.hue),
        ("Saturation", "drop.fill", \.saturation),
        ("Luminance", "sun.min", \.luminance)
    ]

    private static func spec(
        _ id: String,
        _ name: String,
        _ symbol: String,
        _ keyPath: WritableKeyPath<GradeSettings, Double>,
        _ range: ClosedRange<Double>,
        bipolar: Bool,
        display: ValueDisplay
    ) -> ControlSpec {
        ControlSpec(
            id: id,
            name: name,
            symbol: symbol,
            keyPath: keyPath,
            range: range,
            baseline: 0,
            bipolar: bipolar,
            display: display
        )
    }
}

public enum ImageKind {
    public static let extensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"
    ]

    public static func isPhoto(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        return false
    }

    public static let shelfExtensions: Set<String> = ["jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif"]

    /// Space opens QuickGrade for JPEG, PNG and HEIC. Every other file keeps Quick Look.
    public static func opensInShelf(_ url: URL) -> Bool {
        shelfExtensions.contains(url.pathExtension.lowercased())
    }

    /// Path Finder can still open. File-reference URLs (`/.file/id=`) appear after a
    /// file's inode changes. If that id no longer resolves, the original URL is kept.
    public static func posixFileURL(_ url: URL) -> URL {
        let pathURL = (url as NSURL).filePathURL ?? url
        return pathURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Name of the JPEG, PNG or HEIC the user selected. Finder can report
    /// `photo.jpg.quickgrade-bak` after a thumbnail replace. That suffix is removed.
    /// Returns nil when the name is not a shelf photo.
    public static func shelfSelectionName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        var candidate = trimmed
        let suffix = ".quickgrade-bak"
        if candidate.lowercased().hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
        }
        guard shelfExtensions.contains((candidate as NSString).pathExtension.lowercased()) else { return nil }
        return candidate
    }

    /// The selected file, when `name` is a shelf photo (or a bak alias of one) that exists.
    public static func shelfFile(matching name: String, in folder: URL) -> URL? {
        guard let shelf = shelfSelectionName(name) else { return nil }
        let candidate = folder.appendingPathComponent(shelf)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// Extension to use when rewriting the selected file. Each format stays itself: HEIC stays HEIC.
    public static func shelfWriteExtension(_ ext: String) -> String? {
        var value = ext.lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        guard shelfExtensions.contains(value) else { return nil }
        return value
    }
}
