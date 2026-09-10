import Combine
import Foundation
import LumenEditorMobileCore

enum MobileExternalChange: String, Equatable, Identifiable, Sendable {
    case modified
    case deleted
    case unavailable

    var id: String { rawValue }
}

@MainActor
final class MobileDocumentSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var displayName: String
    @Published var content: String {
        didSet { contentUTF16UnitCount = content.utf16.count }
    }
    private(set) var contentUTF16UnitCount: Int
    @Published var encoding: MobileTextEncoding
    @Published var lineEnding: MobileLineEnding
    @Published var persistence: MobilePersistenceState
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var cursorStatus = MobileCursorStatus(
        line: 1, column: 1, utf16Offset: 0, selectionLength: 0
    )
    @Published var fileReference: MobileFileReference?
    @Published var notice: String?
    @Published var isSaving = false
    @Published var requiresEncodingConfirmation: Bool
    @Published var externalChange: MobileExternalChange?
    var encodingRecoveryData: Data?
    private var checkpointGeneration: UInt64

    init(
        id: UUID = UUID(),
        displayName: String,
        content: String,
        encoding: MobileTextEncoding = .utf8,
        lineEnding: MobileLineEnding = .lf,
        persistence: MobilePersistenceState = MobilePersistenceState(
            baselineRevision: nil, isDirty: true
        ),
        fileReference: MobileFileReference? = nil,
        requiresEncodingConfirmation: Bool = false,
        externalChange: MobileExternalChange? = nil,
        encodingRecoveryData: Data? = nil,
        checkpointGeneration: UInt64 = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.content = content
        contentUTF16UnitCount = content.utf16.count
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.persistence = persistence
        self.fileReference = fileReference
        self.requiresEncodingConfirmation = requiresEncodingConfirmation
        self.externalChange = externalChange
        self.encodingRecoveryData = encodingRecoveryData
        self.checkpointGeneration = checkpointGeneration
    }

    var isDirty: Bool { persistence.isDirty }

    func draftSnapshot(date: Date = Date()) -> MobileDraftSnapshot {
        if checkpointGeneration < UInt64.max { checkpointGeneration += 1 }
        MobileDraftSnapshot(
            id: id,
            displayName: displayName,
            content: content,
            encoding: encoding,
            lineEnding: lineEnding,
            bookmarkData: fileReference?.bookmarkData,
            sourceRevision: persistence.baselineRevision,
            isDirty: persistence.isDirty,
            requiresEncodingConfirmation: requiresEncodingConfirmation,
            selectionLocation: selection.location,
            selectionLength: selection.length,
            checkpointGeneration: checkpointGeneration,
            encodingRecoveryData: encodingRecoveryData,
            checkpointedAt: date
        )
    }
}
