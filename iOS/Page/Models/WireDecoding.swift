import Foundation

/// ISO-8601 parsing that accepts what every producer actually sends:
/// the Worker's `new Date().toISOString()` (fractional seconds), the Mac's
/// Swift `.iso8601` encoder (no fractional seconds) and hook `date -u`
/// output. Foundation's `.iso8601` strategy rejects fractional seconds, which
/// used to fail the whole inbox decode.
enum PageDate {
    // ISO8601DateFormatter is documented as thread-safe.
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// Accepts an ISO string, or a number of seconds / milliseconds since the
    /// epoch (anything above 1e12 is treated as milliseconds).
    static func parse(any value: Any?) -> Date? {
        switch value {
        case let s as String:
            return parse(s)
        case let n as NSNumber:
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        default:
            return nil
        }
    }
}

extension JSONDecoder {
    /// The decoder for every Worker payload.
    static func page() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = PageDate.parse(s) { return date }
            if let n = try? c.decode(Double.self), let date = PageDate.parse(any: NSNumber(value: n)) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date")
        }
        return d
    }
}

/// Decodes a JSON array element by element, dropping elements that fail to
/// decode instead of failing the whole list.
struct LossyList<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                // A failed decode doesn't advance the container; consume the
                // bad element so the loop moves on.
                dropped += 1
                if (try? container.decode(Skip.self)) == nil { break }
            }
        }
        elements = out
        droppedCount = dropped
    }
}
