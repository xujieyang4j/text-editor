import Foundation
import Darwin
import JavaScriptCore
import LumenEditorCore

private enum WorkerHostError: Error, LocalizedError {
    case invalidUTF8Source
    case javaScriptUnavailable
    case javaScriptException(String)
    case handlerUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidUTF8Source: "The worker source is not valid UTF-8."
        case .javaScriptUnavailable: "JavaScriptCore could not create a worker context."
        case let .javaScriptException(message): message
        case .handlerUnavailable: "The plugin worker did not install an onmessage handler."
        }
    }
}

private final class WorkerHost {
    private let expectedSourceIntegrity: String
    private let allowedPermissions: Set<PluginPermission>
    private var context: JSContext?
    private var activeRequestID: String?
    private var emittedCount = 0
    private var callbackError: (any Error)?
    private var didLoad = false
    private var didDeactivate = false

    init(expectedSourceIntegrity: String, allowedPermissions: Set<PluginPermission>) {
        self.expectedSourceIntegrity = expectedSourceIntegrity
        self.allowedPermissions = allowedPermissions
    }

    func handle(_ request: PluginWorkerRequest) throws {
        activeRequestID = request.requestID
        emittedCount = 0
        callbackError = nil
        defer { activeRequestID = nil }
        if didDeactivate { throw PluginWorkerProtocolError.invalidRequest }

        switch request.type {
        case .load:
            guard !didLoad else { throw PluginWorkerProtocolError.invalidRequest }
            try load(request)
            didLoad = true
        case .activate:
            guard didLoad else { throw PluginWorkerProtocolError.invalidRequest }
            try dispatchIfPresent(
                type: "activate", commandID: nil, context: request.context
            )
        case .runCommand:
            guard didLoad else { throw PluginWorkerProtocolError.invalidRequest }
            try dispatch(
                type: PluginWorkerRequestKind.runCommand.rawValue,
                commandID: request.commandID,
                context: request.context
            )
        case .deactivate:
            guard didLoad else { throw PluginWorkerProtocolError.invalidRequest }
            try dispatchIfPresent(
                type: "deactivate", commandID: nil, context: request.context
            )
            context = nil
            didLoad = false
            didDeactivate = true
        }
        try emit(PluginWorkerResponse(type: .completed, requestID: request.requestID))
    }

    private func load(_ request: PluginWorkerRequest) throws {
        guard let source = request.source,
              request.sourceSHA256 == expectedSourceIntegrity,
              SHA256Integrity.digest(of: source).rawValue == request.sourceSHA256 else {
            throw PluginWorkerProtocolError.invalidRequest
        }
        guard let sourceText = String(data: source, encoding: .utf8) else {
            throw WorkerHostError.invalidUTF8Source
        }
        guard let context = JSContext() else {
            throw WorkerHostError.javaScriptUnavailable
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            guard let self, let exception else { return }
            let stack = exception.objectForKeyedSubscript("stack")?.toString()
            let detail: String
            if let stack, !stack.isEmpty { detail = stack }
            else { detail = exception.toString() ?? "JavaScript exception" }
            self.callbackError = WorkerHostError.javaScriptException(
                self.bounded(detail, maximumUTF16Count: 2_000)
            )
        }
        let postMessage: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.receivePluginMessage(value)
        }
        context.setObject(postMessage, forKeyedSubscript: "__lumenPostMessage" as NSString)
        context.evaluateScript(
            "var self=this;var globalThis=this;var __lumenListeners=[];"
                + "Object.defineProperty(this,'postMessage',{value:__lumenPostMessage,"
                + "writable:false,configurable:false});"
                + "this.addEventListener=function(t,f){if(t==='message'&&typeof f==='function')"
                + "__lumenListeners.push(f);};"
                + "this.removeEventListener=function(t,f){if(t==='message')"
                + "__lumenListeners=__lumenListeners.filter(function(x){return x!==f;});};"
                + "this.__lumenDispatch=function(m){var e={data:m};"
                + "if(typeof self.onmessage==='function')self.onmessage(e);"
                + "__lumenListeners.slice().forEach(function(f){f(e);});};"
                + "this.fetch=undefined;this.XMLHttpRequest=undefined;"
                + "this.WebSocket=undefined;this.importScripts=undefined;"
        )
        context.evaluateScript(sourceText, withSourceURL: URL(string: "lumen-plugin://worker.js"))
        if let callbackError {
            self.callbackError = nil
            self.context = nil
            throw callbackError
        }
        if let exception = context.exception {
            context.exception = nil
            self.context = nil
            throw WorkerHostError.javaScriptException(
                bounded(
                    exception.toString() ?? "JavaScript exception",
                    maximumUTF16Count: 2_000
                )
            )
        }
    }

    private func dispatch(
        type: String,
        commandID: String?,
        context workerContext: PluginWorkerContext?
    ) throws {
        guard let context else { throw WorkerHostError.javaScriptUnavailable }
        guard let workerContext,
              Set(workerContext.permissions).isSubset(of: allowedPermissions),
              workerContext.document == nil
                || allowedPermissions.contains(.documentRead) else {
            throw WorkerHostError.javaScriptException("Invalid worker context permissions.")
        }
        let handler = context.objectForKeyedSubscript("__lumenDispatch")
        guard let handler, !handler.isUndefined, !handler.isNull else {
            throw WorkerHostError.handlerUnavailable
        }
        var message: [String: Any] = ["type": type]
        if let commandID { message["id"] = commandID }
        message["context"] = jsonObject(Optional(workerContext))
        _ = handler.call(withArguments: [message])
        if let callbackError {
            self.callbackError = nil
            throw callbackError
        }
        if let exception = context.exception {
            context.exception = nil
            throw WorkerHostError.javaScriptException(
                bounded(
                    exception.toString() ?? "JavaScript exception",
                    maximumUTF16Count: 2_000
                )
            )
        }
    }

    private func dispatchIfPresent(
        type: String,
        commandID: String?,
        context workerContext: PluginWorkerContext?
    ) throws {
        guard let context else { throw WorkerHostError.javaScriptUnavailable }
        let onMessage = context.objectForKeyedSubscript("onmessage")
        let listeners = context.objectForKeyedSubscript("__lumenListeners")
        let hasOnMessage = onMessage.isUndefined == false
            && onMessage.isNull == false
        let hasListeners = (listeners?.toArray()?.isEmpty == false)
        guard hasOnMessage || hasListeners else { return }
        try dispatch(type: type, commandID: commandID, context: workerContext)
    }

    private func receivePluginMessage(_ value: JSValue) {
        guard emittedCount < PluginWorkerProtocol.maximumMessagesPerRequest else {
            callbackError = PluginWorkerProtocolError.tooManyMessages(
                maximum: PluginWorkerProtocol.maximumMessagesPerRequest
            )
            return
        }
        guard let object = value.toObject() as? [String: Any],
              let type = object["type"] as? String,
              let responseType = PluginWorkerResponseKind(rawValue: type),
              responseType != .completed, responseType != .failed else {
            callbackError = PluginWorkerProtocolError.invalidMessage
            return
        }
        if responseType == .replaceDocument,
           !allowedPermissions.contains(.documentEdit) {
            callbackError = PluginWorkerRuntimeBoundaryError.documentEditDenied
            return
        }
        let text: String?
        if let candidate = object["text"] as? String {
            if responseType == .replaceDocument,
               candidate.utf8.count > PluginWorkerProtocol.maximumReplacementBytes {
                callbackError = PluginWorkerProtocolError.replacementTooLarge(
                    maximumBytes: PluginWorkerProtocol.maximumReplacementBytes
                )
                return
            }
            text = responseType == .notify
                ? bounded(candidate, maximumUTF16Count: 500)
                : candidate
        } else {
            text = nil
        }
        let response = PluginWorkerResponse(
            type: responseType,
            requestID: activeRequestID,
            id: boundedString(
                object["id"],
                maximumUTF16Count: PluginManifestSecurity.maximumCommandIDUTF16Count
            ),
            title: boundedString(
                object["title"],
                maximumUTF16Count: PluginManifestSecurity.maximumCommandTitleUTF16Count
            ),
            text: text
        )
        do {
            try emit(response)
            emittedCount += 1
        } catch {
            callbackError = error
        }
    }

    private func emit(_ response: PluginWorkerResponse) throws {
        FileHandle.standardOutput.write(try PluginWorkerWireCodec.encode(response))
    }

    private func jsonObject<T: Encodable>(_ value: T?) -> Any {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            return NSNull()
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
    }

    fileprivate func bounded(_ value: String, maximumUTF16Count: Int) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var count = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let units = value[end..<next].utf16.count
            guard count <= maximumUTF16Count - units else { break }
            count += units
            end = next
        }
        return String(value[..<end])
    }

    private func boundedString(_ value: Any?, maximumUTF16Count: Int) -> String? {
        guard let value = value as? String else { return nil }
        return bounded(value, maximumUTF16Count: maximumUTF16Count)
    }
}

private enum PluginWorkerRuntimeBoundaryError: Error, LocalizedError {
    case documentEditDenied

    var errorDescription: String? {
        "The plugin was not granted document-edit permission."
    }
}

private func run() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3,
          PluginManifestSecurity.isValidPluginID(arguments[1]),
          SHA256Integrity(rawValue: arguments[2]) != nil else {
        FileHandle.standardError.write(Data("Invalid worker identity.\n".utf8))
        exit(64)
    }
    var permissions = Set<PluginPermission>()
    for rawValue in arguments.dropFirst(3) {
        guard let permission = PluginPermission(rawValue: rawValue) else {
            FileHandle.standardError.write(Data("Invalid worker permission.\n".utf8))
            exit(64)
        }
        permissions.insert(permission)
    }
    let host = WorkerHost(
        expectedSourceIntegrity: arguments[2],
        allowedPermissions: permissions
    )
    var decoder = PluginWorkerLineDecoder()
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { break }
        do {
            for message in try decoder.append(data) {
                let request = try PluginWorkerWireCodec.decodeRequest(message)
                do {
                    try host.handle(request)
                } catch {
                    let failure = PluginWorkerResponse(
                        type: .failed,
                        requestID: request.requestID,
                        text: host.boundedFailure(error.localizedDescription)
                    )
                    try host.handleFailure(failure)
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(64)
        }
    }
    do { try decoder.finish() } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(64)
    }
}

private extension WorkerHost {
    func boundedFailure(_ message: String) -> String {
        bounded(message, maximumUTF16Count: PluginWorkerProtocol.maximumFailureUTF16Count)
    }

    func handleFailure(_ response: PluginWorkerResponse) throws {
        FileHandle.standardOutput.write(try PluginWorkerWireCodec.encode(response))
    }
}

run()
