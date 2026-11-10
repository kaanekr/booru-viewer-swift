import Foundation

/// Decodes one array element and turns a decoding failure into nil, so the surrounding array still decodes.
/// Use `[FailableDecodable<T>]` and `compactMap { $0.value }` to keep only the elements that succeed.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
