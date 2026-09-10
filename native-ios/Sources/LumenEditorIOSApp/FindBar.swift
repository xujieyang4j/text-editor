import LumenEditorMobileCore
import SwiftUI

struct FindBar: View {
    @ObservedObject var document: MobileDocumentSession
    @ObservedObject var commands: MobileEditorCommandCenter
    let maximumReplacementUTF16UnitCount: () -> Int
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var search = ""
    @State private var replacement = ""
    @State private var options = MobileFindOptions()
    @State private var showReplacement = false
    @State private var resultSummary = ""
    @State private var errorMessage: String?
    @State private var summaryTask: Task<Void, Never>?
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var isWorking = false
    @FocusState private var focusedField: Field?

    private enum Field { case search, replacement }

    var body: some View {
        VStack(spacing: 7) {
            searchControls

            if showReplacement {
                replacementControls
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Toggle(String(localized: "match_case"), isOn: $options.isCaseSensitive)
                    Toggle(String(localized: "whole_word"), isOn: $options.isWholeWord)
                    Toggle(String(localized: "regex"), isOn: $options.usesRegularExpression)
                }
                .toggleStyle(.button)
                .font(.caption)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .onAppear {
            focusedField = .search
            scheduleSummaryUpdate(immediately: true)
        }
        .onChange(of: search) { _, _ in
            cancelOperation()
            scheduleSummaryUpdate()
        }
        .onChange(of: replacement) { _, _ in cancelOperation() }
        .onChange(of: options) { _, _ in
            cancelOperation()
            scheduleSummaryUpdate()
        }
        .onChange(of: document.content) { _, _ in
            cancelOperation()
            scheduleSummaryUpdate()
        }
        .onChange(of: document.selection) { _, _ in
            cancelOperation()
            scheduleSummaryUpdate(immediately: true)
        }
        .onDisappear {
            summaryTask?.cancel()
            cancelOperation()
        }
    }

    private var query: MobileFindQuery {
        MobileFindQuery(search: search, replacement: replacement, options: options)
    }

    @ViewBuilder
    private var searchControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    replacementDisclosure
                    searchField
                }
                HStack(spacing: 8) {
                    resultIndicator
                    Spacer(minLength: 8)
                    navigationButtons
                }
            }
        } else {
            HStack(spacing: 8) {
                replacementDisclosure
                searchField
                resultIndicator
                navigationButtons
            }
        }
    }

    private var replacementDisclosure: some View {
        Button { showReplacement.toggle() } label: {
            Image(systemName: showReplacement ? "chevron.down" : "chevron.right")
        }
        .accessibilityLabel(String(localized: "toggle_replace"))
        .accessibilityIdentifier("ToggleReplaceButton")
    }

    private var searchField: some View {
        TextField(String(localized: "find_placeholder"), text: $search)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .search)
            .submitLabel(.search)
            .onSubmit { move(.next) }
            .accessibilityIdentifier("FindField")
    }

    private var resultIndicator: some View {
        Group {
            if isWorking { ProgressView().controlSize(.small) }
            else { Text(resultSummary) }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 34)
        .accessibilityLabel(
            isWorking ? String(localized: "searching") : String(localized: "find_result_count")
        )
        .accessibilityValue(isWorking ? "" : resultSummary)
    }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            Button { move(.previous) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel(String(localized: "previous_match"))
                .disabled(isWorking)
            Button { move(.next) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(String(localized: "next_match"))
                .disabled(isWorking)
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel(String(localized: "close"))
                .accessibilityIdentifier("CloseFindButton")
        }
    }

    @ViewBuilder
    private var replacementControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                replacementField
                HStack {
                    Spacer()
                    replacementButtons
                }
            }
        } else {
            HStack(spacing: 8) {
                replacementField
                replacementButtons
            }
        }
    }

    private var replacementField: some View {
        TextField(String(localized: "replace_placeholder"), text: $replacement)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .replacement)
            .accessibilityIdentifier("ReplaceField")
    }

    private var replacementButtons: some View {
        HStack(spacing: 8) {
            Button(String(localized: "replace")) { replaceCurrent() }
                .accessibilityIdentifier("ReplaceCurrentButton")
            Button(String(localized: "replace_all")) { replaceAll() }
                .accessibilityIdentifier("ReplaceAllButton")
        }
        .disabled(isWorking)
    }

    private func scheduleSummaryUpdate(immediately: Bool = false) {
        summaryTask?.cancel()
        let text = document.content
        let query = query
        let selectionLocation = document.selection.location
        let selectionLength = document.selection.length
        summaryTask = Task {
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(90)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let summaryWork = Task.detached(priority: .userInitiated) {
                MobileFindSummary.make(
                    text: text, query: query,
                    selectionLocation: selectionLocation, selectionLength: selectionLength,
                    shouldCancel: { Task.isCancelled }
                )
            }
            let summary = await withTaskCancellationHandler {
                await summaryWork.value
            } onCancel: {
                summaryWork.cancel()
            }
            guard !Task.isCancelled, document.content == text, self.query == query,
                  document.selection.location == selectionLocation,
                  document.selection.length == selectionLength else { return }
            resultSummary = summary.result
            errorMessage = summary.errorMessage
        }
    }

    private func move(_ direction: MobileFindDirection) {
        let text = document.content
        let query = query
        let selectionLocation = document.selection.location
        let selectionLength = document.selection.length
        runOperation(
            text: text, query: query,
            selectionLocation: selectionLocation, selectionLength: selectionLength
        ) { shouldCancel in
            do {
                let selection = NSRange(
                    location: selectionLocation, length: selectionLength
                )
                guard let match = try MobileFindCore.match(
                    in: text, query: query, selection: selection,
                    direction: direction, shouldCancel: shouldCancel
                ) else { return .none }
                return .selection(location: match.range.location, length: match.range.length)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    private func replaceCurrent() {
        let text = document.content
        let query = query
        let selectionLocation = document.selection.location
        let selectionLength = document.selection.length
        let maximumOutputUTF16Length = maximumReplacementUTF16UnitCount()
        runOperation(
            text: text, query: query,
            selectionLocation: selectionLocation, selectionLength: selectionLength
        ) { shouldCancel in
            do {
                let selection = NSRange(
                    location: selectionLocation, length: selectionLength
                )
                let scan = try MobileFindCore.scan(
                    text, query: query, shouldCancel: shouldCancel
                )
                let match = scan.matches.first { $0.range == selection }
                    ?? try MobileFindCore.match(
                        in: text, query: query, selection: selection,
                        direction: .next, shouldCancel: shouldCancel
                    )
                guard let match else { return .none }
                let result = try MobileFindCore.replacing(
                    match, in: text, query: query,
                    maximumOutputUTF16Length: maximumOutputUTF16Length
                )
                return .replacement(
                    text: result.text, location: result.selection.location,
                    length: result.selection.length
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    private func replaceAll() {
        let text = document.content
        let query = query
        let selectionLocation = document.selection.location
        let selectionLength = document.selection.length
        let maximumOutputUTF16Length = maximumReplacementUTF16UnitCount()
        runOperation(
            text: text, query: query,
            selectionLocation: selectionLocation, selectionLength: selectionLength
        ) { shouldCancel in
            do {
                let result = try MobileFindCore.replacingAll(
                    in: text, query: query,
                    maximumOutputUTF16Length: maximumOutputUTF16Length,
                    shouldCancel: shouldCancel
                )
                guard result.count > 0 else { return .none }
                return .replacement(text: result.text, location: 0, length: 0)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    private func runOperation(
        text: String,
        query: MobileFindQuery,
        selectionLocation: Int,
        selectionLength: Int,
        operation: @escaping @Sendable (
            @escaping @Sendable () -> Bool
        ) -> MobileFindOperationResult
    ) {
        operationTask?.cancel()
        let id = UUID()
        operationID = id
        isWorking = true
        errorMessage = nil
        operationTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                operation { Task.isCancelled }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard operationID == id else { return }
            isWorking = false
            guard !Task.isCancelled, document.content == text, self.query == query,
                  document.selection.location == selectionLocation,
                  document.selection.length == selectionLength else { return }
            switch result {
            case let .selection(location, length):
                let range = NSRange(location: location, length: length)
                document.selection = range
                commands.send(.select(range))
                scheduleSummaryUpdate(immediately: true)
            case let .replacement(text, location, length):
                commands.send(.replaceDocument(
                    text, selection: NSRange(location: location, length: length)
                ))
            case let .failure(message):
                errorMessage = message
            case .none:
                scheduleSummaryUpdate(immediately: true)
            case .cancelled:
                break
            }
        }
    }

    private func cancelOperation() {
        operationID = nil
        operationTask?.cancel()
        operationTask = nil
        isWorking = false
    }
}

private enum MobileFindOperationResult: Sendable {
    case selection(location: Int, length: Int)
    case replacement(text: String, location: Int, length: Int)
    case failure(String)
    case none
    case cancelled
}

private struct MobileFindSummary: Sendable {
    let result: String
    let errorMessage: String?

    static func make(
        text: String,
        query: MobileFindQuery,
        selectionLocation: Int,
        selectionLength: Int,
        shouldCancel: @escaping @Sendable () -> Bool
    ) -> MobileFindSummary {
        do {
            let matches = try MobileFindCore.scan(
                text, query: query, shouldCancel: shouldCancel
            )
            let selection = NSRange(location: selectionLocation, length: selectionLength)
            let index = matches.matches.firstIndex { $0.range == selection }
            let result = matches.matches.isEmpty
                ? "0" : "\((index ?? -1) + 1)/\(matches.matches.count)"
            return MobileFindSummary(
                result: result,
                errorMessage: matches.isTruncated ? String(localized: "find_truncated") : nil
            )
        } catch {
            return MobileFindSummary(result: "—", errorMessage: error.localizedDescription)
        }
    }
}
