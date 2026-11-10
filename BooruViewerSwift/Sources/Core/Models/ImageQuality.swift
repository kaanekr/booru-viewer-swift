import Foundation

/// Mirrors RN `ImageQuality` (src/services/storage.ts:6). Raw values equal the RN strings.
enum ImageQuality: String, Codable, CaseIterable, Sendable {
    case preview
    case auto
    case full
}
