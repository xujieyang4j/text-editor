import Foundation

/// Stable identifiers shared with the desktop document model.
public enum MobileTextEncoding: String, CaseIterable, Codable, Equatable, Sendable {
    case utf8
    case utf8bom
    case utf16le
    case utf16be
    case utf16leNoBom = "utf16le-nobom"
    case utf16beNoBom = "utf16be-nobom"
    case gb18030
    case gbk
    case big5
    case shiftJIS = "shiftjis"
    case windows1252
    case isoLatin1 = "iso88591"

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8bom: "UTF-8 BOM"
        case .utf16le: "UTF-16 LE"
        case .utf16be: "UTF-16 BE"
        case .utf16leNoBom: "UTF-16 LE (no BOM)"
        case .utf16beNoBom: "UTF-16 BE (no BOM)"
        case .gb18030: "GB18030"
        case .gbk: "GBK"
        case .big5: "Big5"
        case .shiftJIS: "Shift JIS"
        case .windows1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        }
    }

    public var isUTF16: Bool {
        switch self {
        case .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom: true
        default: false
        }
    }
}

public enum MobileLineEnding: String, CaseIterable, Codable, Equatable, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
}

public enum MobileEncodingIssue: String, Codable, Equatable, Sendable {
    case invalidBytes = "invalid-bytes"
    case uncertain
}

/// A coordinated File Provider read prepared for the editor. Content is LF-only.
public struct MobileOpenedTextFile: Equatable, Sendable {
    public let content: String
    public let encoding: MobileTextEncoding
    public let lineEnding: MobileLineEnding
    public let revision: String?
    public let byteLength: Int64
    public let isBinary: Bool
    public let isTooLarge: Bool
    public let encodingIssue: MobileEncodingIssue?
    public let encodingRecoveryData: Data?

    public init(
        content: String,
        encoding: MobileTextEncoding,
        lineEnding: MobileLineEnding,
        revision: String?,
        byteLength: Int64,
        isBinary: Bool,
        isTooLarge: Bool,
        encodingIssue: MobileEncodingIssue? = nil,
        encodingRecoveryData: Data? = nil
    ) {
        self.content = content
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.revision = revision
        self.byteLength = byteLength
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
        self.encodingIssue = encodingIssue
        self.encodingRecoveryData = encodingRecoveryData
    }
}

public enum MobileSaveWarning: String, Codable, Equatable, Sendable {
    case verificationFailed = "verification-failed"
}

/// Pure save-state contract. A write is not clean until exact bytes are read back.
public struct MobilePersistenceState: Codable, Equatable, Sendable {
    public private(set) var baselineRevision: String?
    public private(set) var isDirty: Bool
    public private(set) var warning: MobileSaveWarning?

    public init(
        baselineRevision: String?,
        isDirty: Bool = false,
        warning: MobileSaveWarning? = nil
    ) {
        self.baselineRevision = baselineRevision
        self.isDirty = isDirty
        self.warning = warning
    }

    public mutating func markEdited() {
        isDirty = true
        warning = nil
    }

    public mutating func acceptVerifiedSave(revision: String) {
        baselineRevision = revision
        isDirty = false
        warning = nil
    }

    /// The provider accepted and verified an earlier snapshot while the user
    /// continued editing. The new disk baseline is safe, but the live buffer
    /// must remain dirty for the next save.
    public mutating func acceptVerifiedBaselineWhileDirty(revision: String) {
        baselineRevision = revision
        isDirty = true
        warning = nil
    }

    public mutating func retainAfterUnverifiedWrite(attemptedRevision: String? = nil) {
        if let attemptedRevision { baselineRevision = attemptedRevision }
        isDirty = true
        warning = .verificationFailed
    }

    /// A Save As destination could not be verified. The existing source
    /// baseline must not be replaced by a revision from that separate URL.
    public mutating func retainAfterUnverifiedCopy() {
        isDirty = true
        warning = .verificationFailed
    }
}

public enum SavePreflightError: Error, Equatable, LocalizedError, Sendable {
    case externalModification(expected: String?, actual: String)

    public var errorDescription: String? {
        switch self {
        case .externalModification:
            NSLocalizedString("error_external_modification", comment: "")
        }
    }
}

public enum MobileSavePreflight {
    public static func validate(expectedRevision: String?, currentRevision: String) throws {
        guard expectedRevision == currentRevision else {
            throw SavePreflightError.externalModification(
                expected: expectedRevision,
                actual: currentRevision
            )
        }
    }
}

public enum MobileWorkspaceCapacityRejection: Equatable, Sendable {
    case documentCount
    case estimatedMemory
}

/// A conservative lower-bound for document payloads retained by the mobile
/// workspace. UIKit/TextKit can require additional transient memory, so the
/// app also needs device-level memory-pressure testing before release.
public enum MobileWorkspaceCapacity {
    public static let maximumDocumentCount = 30
    public static let maximumEstimatedPayloadByteCount = 96 * 1_024 * 1_024
    public static let perDocumentOverheadByteCount = 4_096

    public static func estimatedPayloadByteCount(
        utf16UnitCount: Int,
        encodingRecoveryByteCount: Int = 0,
        bookmarkByteCount: Int = 0
    ) -> Int {
        var total = saturatingMultiply(max(0, utf16UnitCount), by: 2)
        total = saturatingAdd(total, max(0, encodingRecoveryByteCount))
        total = saturatingAdd(total, max(0, bookmarkByteCount))
        return saturatingAdd(total, perDocumentOverheadByteCount)
    }

    public static func rejection(
        existingEstimatedByteCounts: [Int],
        addingEstimatedByteCount: Int
    ) -> MobileWorkspaceCapacityRejection? {
        guard existingEstimatedByteCounts.count < maximumDocumentCount else {
            return .documentCount
        }
        var total = max(0, addingEstimatedByteCount)
        for byteCount in existingEstimatedByteCounts {
            total = saturatingAdd(total, max(0, byteCount))
        }
        return total > maximumEstimatedPayloadByteCount ? .estimatedMemory : nil
    }

    /// Computes a prospective TextKit UTF-16 length without overflowing.
    /// UITextView delegate ranges use UTF-16 offsets, so this can reject a
    /// paste or replacement before the workspace model accepts the mutation.
    public static func utf16UnitCount(
        current: Int, replacing replaced: Int, with replacement: Int
    ) -> Int? {
        guard current >= 0, replaced >= 0, replacement >= 0, replaced <= current else {
            return nil
        }
        let retained = current - replaced
        let (result, overflow) = retained.addingReportingOverflow(replacement)
        return overflow ? nil : result
    }

    public static func replacementRejection(
        otherEstimatedByteCounts: [Int],
        currentEstimatedByteCount: Int,
        replacementEstimatedByteCount: Int
    ) -> MobileWorkspaceCapacityRejection? {
        let current = max(0, currentEstimatedByteCount)
        let replacement = max(0, replacementEstimatedByteCount)
        guard replacement > current else { return nil }
        return rejection(
            existingEstimatedByteCounts: otherEstimatedByteCounts,
            addingEstimatedByteCount: replacement
        )
    }

    public static func maximumReplacementUTF16UnitCount(
        otherEstimatedByteCounts: [Int],
        currentUTF16UnitCount: Int,
        encodingRecoveryByteCount: Int = 0,
        bookmarkByteCount: Int = 0
    ) -> Int {
        let current = max(0, currentUTF16UnitCount)
        guard otherEstimatedByteCounts.count < maximumDocumentCount else { return current }
        var used = 0
        for byteCount in otherEstimatedByteCounts {
            used = saturatingAdd(used, max(0, byteCount))
        }
        var fixed = perDocumentOverheadByteCount
        fixed = saturatingAdd(fixed, max(0, encodingRecoveryByteCount))
        fixed = saturatingAdd(fixed, max(0, bookmarkByteCount))
        let availablePayload = used >= maximumEstimatedPayloadByteCount
            ? 0 : maximumEstimatedPayloadByteCount - used
        let availableTextBytes = fixed >= availablePayload ? 0 : availablePayload - fixed
        // Always allow the current length so deletion and other non-growing
        // replacements can recover a workspace inherited in an over-budget state.
        return max(current, availableTextBytes / 2)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private static func saturatingMultiply(_ lhs: Int, by rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : result
    }
}
