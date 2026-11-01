import Foundation

/// An object in the preview that can be dragged: the `fmac://grob?…` link
/// that `Resources/LilyPond/fmac-edit.ly` adds to its stencil in preview
/// engraves. It says where the object comes from in the source and holds
/// the property values a drag starts from.
///
/// Lengths in LilyPond units are converted with `unit` (millimetres per
/// unit), staff spaces with `staffSpace` (millimetres per staff space of
/// the object's staff). PDF and LilyPond both have y pointing up.
public struct GrobLink: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }

        public static let zero = Point(0, 0)
    }

    /// The grob name, as in `\override Script.color`.
    public var grob: String
    /// The event's class, e.g. `articulation-event`; `note-event` for an
    /// automatic beam, which has no event of its own (the location is then
    /// its first note).
    public var event: String
    public var path: String
    /// 1-based line.
    public var line: Int
    /// 0-based column in Unicode characters, where the event (or the tweaks
    /// already on it) starts.
    public var column: Int
    /// What the object shows: `mf`, `accent`, `dolce`, `3`.
    public var label: String
    /// Millimetres per LilyPond unit.
    public var unit: Double
    /// Millimetres per staff space.
    public var staffSpace: Double
    /// The stencil's extents in LilyPond units; the link's rectangle in the
    /// PDF is this box.
    public var xExtent: Point
    public var yExtent: Point
    public var extraOffset: Point
    /// Offset from the X parent.
    public var xOffset: Double?
    /// The spanner that holds the collision properties (DynamicLineSpanner,
    /// SustainPedalLineSpanner), if not the object itself.
    public var target: String?
    /// Where the event that made `target` is: tweaks for it go there.
    public var targetLine: Int?
    public var targetColumn: Int?
    /// The target's offset from its Y parent and its collision properties.
    public var yOffset: Double?
    public var padding: Double?
    public var staffPadding: Double?
    public var outsideStaffPadding: Double?
    public var direction: Int?
    /// Slurs and ties: the four Bézier control points, in LilyPond units.
    public var controlPoints: [Point]
    /// Beams: left and right position, in staff spaces.
    public var positions: Point?
    /// Which piece of a spanner broken across lines (1-based), and how many.
    public var piece: Int
    public var pieces: Int

    public init(grob: String, event: String = "", path: String, line: Int, column: Int, label: String = "",
                unit: Double = 1.7573, staffSpace: Double = 1.7573, xExtent: Point = .zero, yExtent: Point = .zero,
                extraOffset: Point = .zero, xOffset: Double? = nil, target: String? = nil,
                targetLine: Int? = nil, targetColumn: Int? = nil, yOffset: Double? = nil, padding: Double? = nil,
                staffPadding: Double? = nil, outsideStaffPadding: Double? = nil, direction: Int? = nil,
                controlPoints: [Point] = [], positions: Point? = nil, piece: Int = 1, pieces: Int = 1) {
        self.grob = grob
        self.event = event
        self.path = path
        self.line = line
        self.column = column
        self.label = label
        self.unit = unit
        self.staffSpace = staffSpace
        self.xExtent = xExtent
        self.yExtent = yExtent
        self.extraOffset = extraOffset
        self.xOffset = xOffset
        self.target = target
        self.targetLine = targetLine
        self.targetColumn = targetColumn
        self.yOffset = yOffset
        self.padding = padding
        self.staffPadding = staffPadding
        self.outsideStaffPadding = outsideStaffPadding
        self.direction = direction
        self.controlPoints = controlPoints
        self.positions = positions
        self.piece = piece
        self.pieces = pieces
    }

    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    public init?(string: String) {
        let prefix = "fmac://grob?"
        guard string.hasPrefix(prefix) else { return nil }
        var query = Substring(string.dropFirst(prefix.count))
        var fields: [String: String] = [:]
        while !query.isEmpty {
            // The file comes last and may hold & or = if it wasn't encoded.
            if query.hasPrefix("file=") {
                fields["file"] = String(query.dropFirst(5))
                break
            }
            let end = query.firstIndex(of: "&") ?? query.endIndex
            let field = query[..<end]
            if let equals = field.firstIndex(of: "=") {
                fields[String(field[..<equals])] = String(field[field.index(after: equals)...])
            }
            query = end == query.endIndex ? "" : query[query.index(after: end)...]
        }
        func text(_ key: String) -> String {
            let raw = fields[key] ?? ""
            return raw.removingPercentEncoding ?? raw
        }
        func number(_ key: String) -> Double? { Double(text(key)) }
        func point(_ string: String) -> Point? {
            let parts = string.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? Point(parts[0], parts[1]) : nil
        }
        guard let line = Int(text("line")), line >= 1, let column = Int(text("char")), column >= 0,
              !text("name").isEmpty, !text("file").isEmpty else { return nil }
        grob = text("name")
        event = text("ev")
        path = text("file")
        self.line = line
        self.column = column
        label = text("label")
        unit = number("u") ?? 1.7573
        staffSpace = number("ss") ?? unit
        xExtent = point(text("x")) ?? .zero
        yExtent = point(text("y")) ?? .zero
        extraOffset = point(text("eo")) ?? .zero
        xOffset = number("xo")
        target = text("t").isEmpty ? nil : text("t")
        if let location = point(text("tl")) {
            targetLine = Int(location.x)
            targetColumn = Int(location.y)
        }
        yOffset = number("yo")
        padding = number("pad")
        staffPadding = number("spad")
        outsideStaffPadding = number("ospad")
        direction = number("dir").map { Int($0.rounded()) }
        controlPoints = text("cp").split(separator: ";").compactMap { point(String($0)) }
        positions = point(text("pos"))
        let piece = point(text("piece"))
        self.piece = piece.map { max(1, Int($0.x)) } ?? 1
        pieces = piece.map { max(1, Int($0.y)) } ?? 1
    }

    // MARK: Units

    /// PDF points per staff space and per LilyPond unit.
    public var pointsPerStaffSpace: Double { staffSpace * 72 / 25.4 }
    public var pointsPerUnit: Double { unit * 72 / 25.4 }

    /// Where a point in the stencil's coordinates (LilyPond units) lies,
    /// in PDF points from the bottom-left corner of the link's rectangle.
    public func offsetInRectangle(_ point: Point) -> Point {
        Point((point.x - xExtent.x) * pointsPerUnit, (point.y - yExtent.x) * pointsPerUnit)
    }

    /// The drag handles of slurs, ties and beams, in PDF points from the
    /// bottom-left corner of the rectangle: four control points, or the
    /// two ends of a beam.
    public var handles: [Point] {
        if isCurve { return controlPoints.count == 4 ? controlPoints.map(offsetInRectangle) : [] }
        if grob == "Beam", let positions {
            let staffSpaceInUnits = staffSpace / unit
            return [Point(xExtent.x, positions.x * staffSpaceInUnits), Point(xExtent.y, positions.y * staffSpaceInUnits)]
                .map(offsetInRectangle)
        }
        return []
    }

    public var isCurve: Bool { ["Slur", "PhrasingSlur", "Tie"].contains(grob) }

    // MARK: Description

    /// "Dynamic", "Articulation", … for tooltips and menus.
    public var displayName: String {
        switch grob {
        case "Script": "Articulation"
        case "TextScript": "Text"
        case "DynamicText": "Dynamic"
        case "PhrasingSlur": "Phrasing slur"
        case "SustainPedal": "Pedal"
        case "TupletBracket": "Tuplet bracket"
        default: grob
        }
    }

    /// "Dynamic · mf · line 12".
    public var summary: String {
        ([displayName] + (label.isEmpty ? [] : [label]) + ["line \(line)"]).joined(separator: " · ")
    }

    // MARK: Adjusting

    /// The properties a plain drag can set for this object.
    public var properties: [AdjustProperty] {
        let candidates: [AdjustProperty]
        switch grob {
        case "Slur", "PhrasingSlur", "Tie": candidates = [.extraOffset]
        case "Beam": candidates = []
        case "Hairpin", "SustainPedal":
            candidates = [.extraOffset, .yOffset, .padding, .staffPadding, .outsideStaffPadding]
        case "TupletBracket": candidates = [.extraOffset, .padding, .staffPadding]
        default: candidates = AdjustProperty.allCases
        }
        return candidates.filter { property in
            switch property {
            case .extraOffset, .outsideStaffPadding: true
            case .xOffset: xOffset != nil
            case .yOffset: yOffset != nil
            case .padding: padding != nil
            case .staffPadding: staffPadding != nil
            }
        }
    }

    /// Moves smaller than this many staff spaces are ignored.
    public static let minimumMove = 0.05

    /// The tweak for dragging the object by `points` (PDF points) with
    /// `property`, or nil if the move is too small or the value unknown.
    public func tweak(_ property: AdjustProperty, movedBy points: Point) -> Tweak? {
        let dx = Self.significant(points.x / pointsPerStaffSpace)
        let dy = Self.significant(points.y / pointsPerStaffSpace)
        switch property {
        case .extraOffset:
            guard dx != 0 || dy != 0 else { return nil }
            return .set(property: property.rawValue, grob: nil,
                        value: .pair(Self.round(extraOffset.x + dx), Self.round(extraOffset.y + dy)))
        case .xOffset:
            guard dx != 0, let xOffset else { return nil }
            return .set(property: property.rawValue, grob: nil, value: .number(Self.round(xOffset + dx)))
        case .yOffset:
            guard dy != 0, let yOffset else { return nil }
            return .set(property: property.rawValue, grob: target, value: .number(Self.round(yOffset + dy)))
        case .padding, .staffPadding, .outsideStaffPadding:
            let current: Double? = switch property {
            case .padding: padding
            case .staffPadding: staffPadding
            default: outsideStaffPadding ?? Self.defaultOutsideStaffPadding
            }
            guard dy != 0, let current else { return nil }
            // Further from the staff is more padding: up for objects above it.
            return .set(property: property.rawValue, grob: target,
                        value: .number(Self.round(current + dy * Double(side))))
        }
    }

    /// LilyPond's value when outside-staff-padding isn't set.
    public static let defaultOutsideStaffPadding = 0.46

    /// 1 above the staff, -1 below.
    var side: Int {
        if let direction, direction != 0 { return direction }
        return (yOffset ?? 1) < 0 ? -1 : 1
    }

    /// `\shape` for moving control point `index` (or all four, for nil) of a
    /// slur or tie by `points`.
    public func shape(movingPoint index: Int?, by points: Point) -> Tweak? {
        guard isCurve else { return nil }
        // \shape scales y by staff space, but only in its single-list form.
        let dx = points.x / pointsPerUnit
        let dy = points.y / (pieces > 1 ? pointsPerUnit : pointsPerStaffSpace)
        guard abs(points.x) / pointsPerStaffSpace >= Self.minimumMove
                || abs(points.y) / pointsPerStaffSpace >= Self.minimumMove else { return nil }
        let move = Point(Self.round(dx), Self.round(dy))
        let offsets = (0..<4).map { index == nil || index == $0 ? move : .zero }
        return .shape(offsets: offsets, piece: piece, pieces: pieces)
    }

    /// `\offset positions` for moving the left and right end of a beam by
    /// `left` and `right` points.
    public func beamOffset(left: Double, right: Double) -> Tweak? {
        guard grob == "Beam" else { return nil }
        let l = Self.significant(left / pointsPerStaffSpace)
        let r = Self.significant(right / pointsPerStaffSpace)
        guard l != 0 || r != 0 else { return nil }
        return .offset(property: "positions", value: .pair(Self.round(l), Self.round(r)))
    }

    static func significant(_ value: Double) -> Double {
        abs(value) < minimumMove ? 0 : value
    }

    /// To 0.01, without -0.
    static func round(_ value: Double) -> Double {
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded
    }
}

/// What a plain drag in the preview changes.
public enum AdjustProperty: String, CaseIterable, Sendable {
    case extraOffset = "extra-offset"
    case xOffset = "X-offset"
    case yOffset = "Y-offset"
    case padding = "padding"
    case staffPadding = "staff-padding"
    case outsideStaffPadding = "outside-staff-padding"

    public var title: String {
        switch self {
        case .extraOffset: "Offset"
        case .xOffset: "X-offset"
        case .yOffset: "Y-offset"
        case .padding: "Padding"
        case .staffPadding: "Distance from Staff"
        case .outsideStaffPadding: "Outside-Staff Padding"
        }
    }

    /// Whether a drag in this mode moves the object only up and down.
    public var isVertical: Bool { self != .extraOffset && self != .xOffset }
    public var isHorizontal: Bool { self == .xOffset }
}
