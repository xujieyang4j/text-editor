import Foundation
import Darwin
import JavaScriptCore

private let maximumBundleBytes = 8 * 1_024 * 1_024
private let maximumRequestBytes = 1 * 1_024 * 1_024
private let maximumErrorUTF8Bytes = 4 * 1_024

private struct AnalyzeRequest: Decodable {
    let text: String
    let language: String
    let tabWidth: Int
    let indentWidth: Int
    let insertSpaces: Bool
}

private enum ParserWorkerError: Error, LocalizedError {
    case invalidArguments
    case invalidBundlePath
    case invalidBundleSize
    case invalidBundleUTF8
    case invalidRequestSize
    case invalidRequest
    case javaScriptUnavailable
    case javaScriptException(String)
    case parserUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Expected one parser bundle path argument."
        case .invalidBundlePath: "The parser bundle path is not a regular file."
        case .invalidBundleSize: "The parser bundle exceeds its byte limit."
        case .invalidBundleUTF8: "The parser bundle is not valid UTF-8."
        case .invalidRequestSize: "The parser request exceeds its byte limit."
        case .invalidRequest: "The parser request is invalid."
        case .javaScriptUnavailable: "JavaScriptCore could not create a context."
        case let .javaScriptException(message): message
        case .parserUnavailable: "LumenCodeMirrorParser.analyze is unavailable."
        case .invalidResponse: "The parser returned an invalid response."
        }
    }
}

private func readBoundedStandardInput() throws -> Data {
    var result = Data()
    while true {
        let remaining = maximumRequestBytes - result.count
        guard remaining >= 0 else { throw ParserWorkerError.invalidRequestSize }
        let chunk = try FileHandle.standardInput.read(
            upToCount: min(64 * 1_024, remaining + 1)
        ) ?? Data()
        if chunk.isEmpty { break }
        guard chunk.count <= remaining else {
            throw ParserWorkerError.invalidRequestSize
        }
        result.append(chunk)
    }
    guard !result.isEmpty else { throw ParserWorkerError.invalidRequest }
    return result
}

private func readParserBundle(at url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
        throw ParserWorkerError.invalidBundlePath
    }
    guard let byteCount = values.fileSize,
          byteCount > 0, byteCount <= maximumBundleBytes else {
        throw ParserWorkerError.invalidBundleSize
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard !data.isEmpty, data.count <= maximumBundleBytes else {
        throw ParserWorkerError.invalidBundleSize
    }
    guard let source = String(data: data, encoding: .utf8) else {
        throw ParserWorkerError.invalidBundleUTF8
    }
    return source
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ParserWorkerError.invalidArguments
    }
    let rawPath = CommandLine.arguments[1]
    guard (rawPath as NSString).isAbsolutePath, !rawPath.utf8.contains(0) else {
        throw ParserWorkerError.invalidBundlePath
    }
    let bundleURL = URL(fileURLWithPath: rawPath, isDirectory: false)
        .standardizedFileURL.resolvingSymlinksInPath()
    let source = try readParserBundle(at: bundleURL)
    let requestData = try readBoundedStandardInput()
    guard let request = try? JSONDecoder().decode(
        AnalyzeRequest.self, from: requestData
    ),
          request.text.utf16.count <= 128 * 1_024,
          request.language.utf16.count <= 128,
          (1...16).contains(request.tabWidth),
          (1...16).contains(request.indentWidth),
          let requestJSON = String(data: requestData, encoding: .utf8) else {
        throw ParserWorkerError.invalidRequest
    }

    guard let context = JSContext() else {
        throw ParserWorkerError.javaScriptUnavailable
    }
    context.exceptionHandler = { _, _ in }
    context.evaluateScript(source, withSourceURL: bundleURL)
    if let exception = context.exception, !exception.isUndefined {
        throw ParserWorkerError.javaScriptException(
            exception.toString() ?? "JavaScript exception"
        )
    }
    guard let parser = context.objectForKeyedSubscript("LumenCodeMirrorParser"),
          !parser.isUndefined, !parser.isNull,
          let analyze = parser.objectForKeyedSubscript("analyze"),
          !analyze.isUndefined, !analyze.isNull else {
        throw ParserWorkerError.parserUnavailable
    }
    let response = analyze.call(withArguments: [requestJSON])
    if let exception = context.exception, !exception.isUndefined {
        throw ParserWorkerError.javaScriptException(
            exception.toString() ?? "JavaScript exception"
        )
    }
    guard let response, !response.isUndefined, !response.isNull,
          let json = response.toString(), !json.isEmpty,
          let responseData = json.data(using: .utf8) else {
        throw ParserWorkerError.invalidResponse
    }
    try FileHandle.standardOutput.write(contentsOf: responseData)
}

do {
    try run()
} catch {
    var message = error.localizedDescription
    if message.utf8.count > maximumErrorUTF8Bytes {
        message = String(decoding: message.utf8.prefix(maximumErrorUTF8Bytes), as: UTF8.self)
    }
    if let data = (message + "\n").data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
    exit(EXIT_FAILURE)
}
