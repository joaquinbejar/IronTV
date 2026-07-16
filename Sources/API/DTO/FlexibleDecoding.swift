import Foundation

/// Xtream panels are PHP-backed: numeric fields arrive as `Int` or `String`
/// (or occasionally `Double`) depending on panel version, and any field may be
/// `null` or absent. These wrappers absorb that variance; unparseable values
/// decode as `nil` rather than failing the whole payload.
@propertyWrapper
public struct FlexibleInt: Codable, Equatable, Sendable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int? = nil) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = int
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = Int(double)
        } else if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            wrappedValue = Int(trimmed) ?? Double(trimmed).map(Int.init)
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

@propertyWrapper
public struct FlexibleString: Codable, Equatable, Sendable {
    public var wrappedValue: String?

    public init(wrappedValue: String? = nil) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let string = try? container.decode(String.self) {
            wrappedValue = string
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            wrappedValue = String(bool)
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// A wrapped property declared as `@FlexibleInt var x: Int?` still requires its
// key to be present by default. These overloads make an absent key decode as
// nil, matching the panels' habit of dropping fields entirely.
public extension KeyedDecodingContainer {
    func decode(_ type: FlexibleInt.Type, forKey key: Key) throws -> FlexibleInt {
        try decodeIfPresent(FlexibleInt.self, forKey: key) ?? FlexibleInt()
    }

    func decode(_ type: FlexibleString.Type, forKey key: Key) throws -> FlexibleString {
        try decodeIfPresent(FlexibleString.self, forKey: key) ?? FlexibleString()
    }
}
