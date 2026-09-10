import SwiftUI
import UniformTypeIdentifiers

struct ExportTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .sourceCode, .data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
