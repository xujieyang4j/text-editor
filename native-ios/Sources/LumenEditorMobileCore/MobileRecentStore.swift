import Foundation

public struct MobileRecentFile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmarkData: Data
    public var lastOpenedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
    }
}

public actor MobileRecentStore {
    public static let maximumCount = 30
    public static let maximumBookmarkByteCount = 1 * 1_024 * 1_024
    // JSONEncoder stores Data as Base64, so the file bound must include that
    // expansion plus bounded metadata for every record.
    public static let maximumStoreByteCount = maximumCount
        * ((maximumBookmarkByteCount * 4 / 3) + 4_096)

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [MobileRecentFile]?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public static func applicationStore(fileManager: FileManager = .default) -> MobileRecentStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MobileRecentStore(
            fileURL: root.appendingPathComponent("RecentFiles.json"),
            fileManager: fileManager
        )
    }

    public func records() -> [MobileRecentFile] {
        if let cachedRecords { return cachedRecords }
        let loaded = readRecords()
        cachedRecords = loaded
        return loaded
    }

    @discardableResult
    public func record(
        displayName: String,
        bookmarkData: Data,
        date: Date = Date()
    ) throws -> [MobileRecentFile] {
        guard !bookmarkData.isEmpty, bookmarkData.count <= Self.maximumBookmarkByteCount else {
            return records()
        }
        var records = self.records()
        let existing = records.first { $0.bookmarkData == bookmarkData }
        records.removeAll { $0.bookmarkData == bookmarkData }
        records.insert(MobileRecentFile(
            id: existing?.id ?? UUID(),
            displayName: displayName,
            bookmarkData: bookmarkData,
            lastOpenedAt: date
        ), at: 0)
        records = Array(records.prefix(Self.maximumCount))
        try write(records)
        cachedRecords = records
        return records
    }

    @discardableResult
    public func remove(id: UUID) throws -> [MobileRecentFile] {
        var records = self.records()
        records.removeAll { $0.id == id }
        try write(records)
        cachedRecords = records
        return records
    }

    private func readRecords() -> [MobileRecentFile] {
        guard let data = try? readBoundedData(
                  maximumByteCount: Self.maximumStoreByteCount
              ),
              let decoded = try? decoder.decode([MobileRecentFile].self, from: data) else {
            return []
        }
        return Array(decoded.filter {
            !$0.bookmarkData.isEmpty && $0.bookmarkData.count <= Self.maximumBookmarkByteCount
        }.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(Self.maximumCount))
    }

    private func write(_ records: [MobileRecentFile]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
        let data = try encoder.encode(records)
        guard data.count <= Self.maximumStoreByteCount else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(
            to: fileURL,
            options: protectedAtomicWriteOptions
        )
    }

    private func readBoundedData(maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 1_048_576))
        while true {
            let remaining = maximumByteCount - data.count
            let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
            if chunk.isEmpty { return data }
            guard chunk.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
    }

    private var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    private var protectedAtomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
