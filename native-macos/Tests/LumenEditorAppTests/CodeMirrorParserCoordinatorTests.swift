import Foundation
import XCTest
@testable import LumenEditorApp

final class CodeMirrorParserCoordinatorTests: XCTestCase {
    func testCacheKeyIncludesRevisionTextLanguageAndIndentationSettings() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            return Self.unsupported(text: text, language: language)
        })

        _ = await coordinator.analyze(text: "x", language: "Swift", revision: 1)
        _ = await coordinator.analyze(text: "x", language: "Swift", revision: 1)
        _ = await coordinator.analyze(
            text: "x", language: "Swift", revision: 1, tabWidth: 8
        )
        _ = await coordinator.analyze(
            text: "x", language: "Swift", revision: 1, indentWidth: 2
        )
        _ = await coordinator.analyze(
            text: "x", language: "Swift", revision: 1, insertSpaces: false
        )
        _ = await coordinator.analyze(text: "y", language: "Swift", revision: 1)
        _ = await coordinator.analyze(text: "x", language: "JavaScript", revision: 1)
        _ = await coordinator.analyze(text: "x", language: "Swift", revision: 2)

        XCTAssertEqual(calls.value, 7)
    }

    func testUndoRedoSameTextStillRequestsExactRevisionAnalysis() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            return Self.unsupported(text: text, language: language)
        })

        _ = await coordinator.analyze(text: "before", language: "Swift", revision: 1)
        _ = await coordinator.analyze(text: "after", language: "Swift", revision: 2)
        _ = await coordinator.analyze(text: "before", language: "Swift", revision: 3)
        _ = await coordinator.analyze(text: "after", language: "Swift", revision: 4)

        XCTAssertEqual(calls.value, 4)
        XCTAssertNotNil(coordinator.cachedAnalysis(
            text: "before", language: "Swift", revision: 3
        ))
        XCTAssertNil(coordinator.cachedAnalysis(
            text: "before", language: "Swift", revision: 1_000
        ))
    }

    func testCacheKeyUsesExactUTF16CodeUnits() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            return Self.unsupported(text: text, language: language)
        })
        let first = "a\u{0301}\u{0327}"
        let canonicallyEquivalent = "a\u{0327}\u{0301}"
        XCTAssertEqual(first, canonicallyEquivalent)
        XCTAssertEqual(first.utf16.count, canonicallyEquivalent.utf16.count)

        _ = await coordinator.analyze(
            text: first, language: "Plain Text", revision: 1
        )
        _ = await coordinator.analyze(
            text: canonicallyEquivalent, language: "Plain Text", revision: 1
        )

        XCTAssertEqual(calls.value, 2)
    }

    func testSynchronousConsumersOnlyReadValidatedCache() async {
        let text = "let x = 1"
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.unsupported(text: text, language: language)
        })
        XCTAssertNil(coordinator.cachedAnalysis(
            text: text, language: "Swift", revision: 1
        ))
        _ = await coordinator.analyze(text: text, language: "Swift", revision: 1)
        XCTAssertNotNil(coordinator.cachedAnalysis(
            text: text, language: "Swift", revision: 1
        ))
        XCTAssertNil(coordinator.cachedAnalysis(
            text: text, language: "Swift", revision: 2
        ))
    }

    func testConcurrentRequestsForSameRevisionShareOneParse() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return Self.unsupported(text: text, language: language)
        })
        await withTaskGroup(of: CodeMirrorParserAnalysis?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await coordinator.analyze(
                        text: "same", language: "Swift", revision: 4
                    )
                }
            }
            for await result in group { XCTAssertNotNil(result) }
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testCancelledSelectionProbeDebouncesDoNotStartAnalysisOrRepeatBaseParse() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(
            analyzeWithNewlinePositions: { text, language, _, _, _, _ in
                calls.increment()
                return Self.unsupported(text: text, language: language)
            }
        )
        let text = "const value = 1"
        _ = await coordinator.analyze(
            text: text, language: "JavaScript", revision: 7
        )

        var probes: [Task<CodeMirrorParserAnalysis?, Never>] = []
        for position in 0..<6 {
            probes.append(Task {
                await coordinator.analyzeAfterProbeDebounce(
                    text: text, language: "JavaScript", revision: 7,
                    newlineIndentationPositions: [position],
                    debounceNanoseconds: 50_000_000
                )
            })
            if probes.count > 1 { probes[probes.count - 2].cancel() }
        }
        for probe in probes.dropLast() {
            let result = await probe.value
            XCTAssertNil(result)
        }
        let finalResult = await probes.last?.value
        XCTAssertNotNil(finalResult)

        // One immediate base parse plus only the final settled cursor probe.
        XCTAssertEqual(calls.value, 2)
        XCTAssertNotNil(coordinator.cachedAnalysis(
            text: text, language: "JavaScript", revision: 7
        ))
    }

    func testImmediateAnalysisCompletesAfterRegistrationAndPopulatesCache() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            return Self.unsupported(text: text, language: language)
        })

        let result = await coordinator.analyze(
            text: "immediate", language: "Swift", revision: 1
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertNotNil(coordinator.cachedAnalysis(
            text: "immediate", language: "Swift", revision: 1
        ))
    }

    func testDifferentKeyRevisionChurnCancelsOldestAtInFlightLimit() async {
        let gate = ParserAnalysisGate()
        let coordinator = CodeMirrorParserCoordinator(
            maximumInFlightAnalyses: 2,
            analyze: { text, _, _, _, _ in await gate.analyze(text: text) }
        )

        let first = Task {
            await coordinator.analyze(
                text: "first", language: "Swift", revision: 1
            )
        }
        await gate.waitUntilStarted(count: 1)
        let second = Task {
            await coordinator.analyze(
                text: "second", language: "Swift", revision: 2
            )
        }
        await gate.waitUntilStarted(count: 2)
        let third = Task {
            await coordinator.analyze(
                text: "third", language: "Swift", revision: 3
            )
        }

        await gate.waitUntilStarted(count: 3)
        await gate.waitUntilCancelled(text: "first")
        let startedTexts = await gate.startedTexts
        XCTAssertEqual(startedTexts, ["first", "second", "third"])

        second.cancel()
        third.cancel()
        _ = await first.value
        _ = await second.value
        _ = await third.value
    }

    func testCancellingOneSameKeyWaiterPreservesSharedResultForOther() async {
        let gate = ParserAnalysisGate()
        let coordinator = CodeMirrorParserCoordinator(
            analyze: { text, _, _, _, _ in await gate.analyze(text: text) }
        )
        let first = Task {
            await coordinator.analyze(
                text: "same", language: "Swift", revision: 1
            )
        }
        await gate.waitUntilStarted(count: 1)
        let second = Task {
            await coordinator.analyze(
                text: "same", language: "Swift", revision: 1
            )
        }
        for _ in 0..<10_000 {
            if coordinator.activeWaiterCount == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.activeWaiterCount, 2)
        // Cancelling one exact-key waiter must not terminate the shared parse
        // while another consumer still needs it.
        second.cancel()
        await gate.finish(text: "same")
        let firstResult = await first.value
        let secondResult = await second.value
        for _ in 0..<1_000 {
            if coordinator.cachedAnalysis(
                text: "same", language: "Swift", revision: 1
            ) != nil { break }
            await Task.yield()
        }
        let startedTexts = await gate.startedTexts
        let cancelledTexts = await gate.cancelledTexts
        XCTAssertNotNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertNotNil(coordinator.cachedAnalysis(
            text: "same", language: "Swift", revision: 1
        ))
        XCTAssertEqual(startedTexts, ["same"])
        XCTAssertEqual(cancelledTexts, [])
    }

    func testCancellingLastWaiterStopsSharedAnalysis() async {
        let gate = ParserAnalysisGate()
        let coordinator = CodeMirrorParserCoordinator(
            analyze: { text, _, _, _, _ in await gate.analyze(text: text) }
        )
        let request = Task {
            await coordinator.analyze(
                text: "last", language: "Swift", revision: 1
            )
        }
        await gate.waitUntilStarted(count: 1)

        request.cancel()
        await gate.waitUntilCancelled(text: "last")
        let result = await request.value
        XCTAssertNil(result)
    }

    func testRemoveAllReturnsTaskThatWaitsForWorkerReclamation() async {
        let analysisGate = ParserAnalysisGate()
        let reclamationGate = ParserReclamationGate()
        let coordinator = CodeMirrorParserCoordinator(
            analyze: { text, _, _, _, _ in await analysisGate.analyze(text: text) },
            cancelAll: { await reclamationGate.cancelAll() }
        )
        let analysis = Task {
            await coordinator.analyze(
                text: "active", language: "Swift", revision: 1
            )
        }
        await analysisGate.waitUntilStarted(count: 1)

        let reclamation = coordinator.removeAllCachedAnalyses()
        await reclamationGate.waitUntilStarted()
        await analysisGate.waitUntilCancelled(text: "active")
        let cancellationCalls = await reclamationGate.callCount
        XCTAssertEqual(cancellationCalls, 1)

        await reclamationGate.release()
        await reclamation.value
        _ = await analysis.value
    }

    func testNewAnalysisWaitsForRemoveAllReclamation() async {
        let reclamationGate = ParserReclamationGate()
        let analyzeCalls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(
            analyze: { text, language, _, _, _ in
                analyzeCalls.increment()
                return Self.unsupported(text: text, language: language)
            },
            cancelAll: { await reclamationGate.cancelAll() }
        )

        let reclamation = coordinator.removeAllCachedAnalyses()
        await reclamationGate.waitUntilStarted()
        let analysis = Task {
            await coordinator.analyze(
                text: "fresh", language: "Swift", revision: 2
            )
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(analyzeCalls.value, 0)

        await reclamationGate.release()
        await reclamation.value
        let result = await analysis.value
        XCTAssertNotNil(result)
        XCTAssertEqual(analyzeCalls.value, 1)
    }

    func testShutdownRejectsLateAnalysisAndWaitsForWorkerReclamation() async {
        let reclamationGate = ParserReclamationGate()
        let analyzeCalls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(
            analyze: { text, language, _, _, _ in
                analyzeCalls.increment()
                return Self.unsupported(text: text, language: language)
            },
            cancelAll: { await reclamationGate.cancelAll() }
        )

        let shutdown = Task { await coordinator.shutdown() }
        await reclamationGate.waitUntilStarted()
        let lateAnalysis = await coordinator.analyze(
            text: "late", language: "Swift", revision: 9
        )

        XCTAssertNil(lateAnalysis)
        XCTAssertEqual(analyzeCalls.value, 0)

        await reclamationGate.release()
        await shutdown.value
        XCTAssertNil(coordinator.cachedAnalysis(
            text: "late", language: "Swift", revision: 9
        ))
    }

    func testLineBudgetTreatsLFCRLFAndCRAsOneBoundaryEach() {
        XCTAssertTrue(CodeMirrorParserCoordinator.lineCountWithinBudget(
            "a\nb\r\nc\rd"
        ))
        XCTAssertFalse(CodeMirrorParserCoordinator.lineCountWithinBudget(
            String(repeating: "x\n", count: 50_000)
        ))
    }

    func testTransientFailureIsNotNegativeCached() async {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            calls.increment()
            guard calls.value > 1 else { return nil }
            return Self.unsupported(text: text, language: language)
        })
        let first = await coordinator.analyze(
            text: "retry", language: "Swift", revision: 1
        )
        let second = await coordinator.analyze(
            text: "retry", language: "Swift", revision: 1
        )
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(calls.value, 2)
    }

    func testCachedIndentationSnapshotRequiresExactCompleteAnalysis() async throws {
        let text = "{\n  child\n}"
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.supported(
                text: text, language: language,
                indentation: [
                    .init(lineFrom: 0, columns: 0),
                    .init(lineFrom: 2, columns: 2),
                    .init(lineFrom: 10, columns: 0)
                ]
            )
        })

        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        ))
        _ = await coordinator.analyze(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        )
        let snapshot = try XCTUnwrap(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        ))
        XCTAssertEqual(snapshot.newlineIndentationColumns(atExistingLineStart: 2), 2)
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 5,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        ))
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 4, indentWidth: 2, insertSpaces: true
        ))
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 4, insertSpaces: true
        ))
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: false
        ))
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "javascript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        ))
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: "{\n  other\n}", language: "JavaScript", revision: 4,
            tabWidth: 8, indentWidth: 2, insertSpaces: true
        ))
    }

    func testNewlineProbePositionsParticipateInCacheIdentity() async throws {
        let calls = LockedCounter()
        let coordinator = CodeMirrorParserCoordinator(
            analyzeWithNewlinePositions: { text, language, _, _, _, positions in
                calls.increment()
                return Self.supported(
                    text: text, language: language,
                    indentation: [.init(lineFrom: 0, columns: 0)],
                    newlineIndentation: positions.map {
                        .init(position: $0, columns: 2)
                    }
                )
            }
        )
        _ = await coordinator.analyze(
            text: "value", language: "JavaScript", revision: 3,
            newlineIndentationPositions: [5]
        )
        let snapshot = try XCTUnwrap(coordinator.cachedParsedIndentationSnapshot(
            text: "value", language: "JavaScript", revision: 3,
            newlineIndentationPositions: [5]
        ))
        XCTAssertEqual(snapshot.newlineIndentationColumns(
            atExistingLineStart: 5
        ), 2)
        XCTAssertNil(coordinator.cachedParsedIndentationSnapshot(
            text: "value", language: "JavaScript", revision: 3,
            newlineIndentationPositions: [4]
        ))
        XCTAssertNotNil(coordinator.cachedAnalysisForAnyNewlinePositions(
            text: "value", language: "JavaScript", revision: 3,
            tabWidth: 4, indentWidth: 4, insertSpaces: true
        ))
        XCTAssertEqual(calls.value, 1)
    }

    func testCachedIndentationSnapshotRejectsTruncatedAndIncompleteEntries() async {
        let text = "a\nb"
        let truncated = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.supported(
                text: text, language: language,
                indentation: [.init(lineFrom: 0, columns: 0)],
                indentationWasTruncated: true
            )
        })
        let incomplete = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.supported(
                text: text, language: language,
                indentation: [.init(lineFrom: 0, columns: 0)]
            )
        })

        _ = await truncated.analyze(
            text: text, language: "JavaScript", revision: 1
        )
        _ = await incomplete.analyze(
            text: text, language: "JavaScript", revision: 1
        )
        XCTAssertNil(truncated.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 1
        ))
        XCTAssertNil(incomplete.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 1
        ))
    }

    func testSnapshotStopsAfterCollectorOverrideDivergesFromSource() async throws {
        let text = "a\n b\n  c"
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.supported(
                text: text, language: language,
                indentation: [
                    .init(lineFrom: 0, columns: 0),
                    .init(lineFrom: 2, columns: 4),
                    .init(lineFrom: 5, columns: 6)
                ]
            )
        })
        _ = await coordinator.analyze(
            text: text, language: "JavaScript", revision: 1
        )

        let snapshot = try XCTUnwrap(coordinator.cachedParsedIndentationSnapshot(
            text: text, language: "JavaScript", revision: 1
        ))
        XCTAssertEqual(snapshot.newlineIndentationColumns(atExistingLineStart: 2), 4)
        XCTAssertNil(snapshot.newlineIndentationColumns(atExistingLineStart: 5))
    }

    func testStreamCacheKeepsBracketsIndentationAndOnlyForcesNodeFallback() async throws {
        let text = "func run() {\n  work()\n}"
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.stream(
                text: text, language: language,
                bracketPairs: [
                    .init(open: 8, close: 9),
                    .init(open: 11, close: 22),
                    .init(open: 19, close: 20)
                ],
                indentation: [
                    .init(lineFrom: 0, columns: 0),
                    .init(lineFrom: 13, columns: 2),
                    .init(lineFrom: 22, columns: 0)
                ]
            )
        })

        _ = await coordinator.analyze(
            text: text, language: "Swift", revision: 7,
            tabWidth: 4, indentWidth: 2, insertSpaces: true
        )

        let syntax = try XCTUnwrap(coordinator.cachedParsedSyntaxSnapshot(
            text: text, language: "Swift", revision: 7,
            tabWidth: 4, indentWidth: 2, insertSpaces: true
        ))
        XCTAssertEqual(syntax.nodes.map(\.type), ["Document"])
        XCTAssertTrue(syntax.nodesWereTruncated)
        XCTAssertEqual(syntax.bracketPairs, [
            .init(open: 8, close: 9),
            .init(open: 11, close: 22),
            .init(open: 19, close: 20)
        ])
        XCTAssertFalse(syntax.bracketPairsWereTruncated)
        XCTAssertFalse(syntax.indentationWasTruncated)
        XCTAssertEqual(syntax.indentation.map(\.columns), [0, 2, 0])

        let indentation = try XCTUnwrap(
            coordinator.cachedParsedIndentationSnapshot(
                text: text, language: "Swift", revision: 7,
                tabWidth: 4, indentWidth: 2, insertSpaces: true
            )
        )
        XCTAssertEqual(
            indentation.newlineIndentationColumns(atExistingLineStart: 13), 2
        )
    }

    func testStreamOutlineUsesLexicalFallbackInsteadOfParserOutline() async {
        let text = "func run() {\n  work()\n}"
        let coordinator = CodeMirrorParserCoordinator(analyze: {
            text, language, _, _, _ in
            Self.stream(text: text, language: language, indentation: [])
        })

        let outline = await coordinator.outlineDocumentModel(
            text: text, language: "Swift", revision: 3, limits: .default
        )

        XCTAssertEqual(outline.symbols.map(\.label), ["run"])
        XCTAssertEqual(outline.symbols.map(\.kind), [.function])
        XCTAssertEqual(outline.foldRegions.map(\.startLine), [1])
        XCTAssertEqual(outline.foldRegions.map(\.endLine), [3])
    }

    private static func unsupported(
        text: String, language: String
    ) -> CodeMirrorParserAnalysis {
        CodeMirrorParserAnalysis(
            supported: false, parserKind: .unsupported, requestedLanguage: language,
            resolvedLanguage: language, sourceUTF16Length: text.utf16.count,
            highlights: [], syntaxNodes: [], bracketPairs: [], folds: [], symbols: [],
            indentation: [], truncated: .init(
                source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false, indentation: false
            )
        )
    }

    private static func supported(
        text: String, language: String,
        indentation: [CodeMirrorParserAnalysis.LineIndentation],
        newlineIndentation: [CodeMirrorParserAnalysis.NewlineIndentation] = [],
        indentationWasTruncated: Bool = false
    ) -> CodeMirrorParserAnalysis {
        CodeMirrorParserAnalysis(
            supported: true, parserKind: .lezer, requestedLanguage: language,
            resolvedLanguage: language, sourceUTF16Length: text.utf16.count,
            highlights: [],
            syntaxNodes: [.init(
                from: 0, to: text.utf16.count, type: "Root", parent: -1
            )],
            bracketPairs: [], folds: [], symbols: [], indentation: indentation,
            newlineIndentation: newlineIndentation,
            truncated: .init(
                source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false,
                indentation: indentationWasTruncated
            )
        )
    }

    private static func stream(
        text: String, language: String,
        bracketPairs: [CodeMirrorParserAnalysis.BracketPair] = [],
        indentation: [CodeMirrorParserAnalysis.LineIndentation]
    ) -> CodeMirrorParserAnalysis {
        CodeMirrorParserAnalysis(
            supported: true, parserKind: .stream, requestedLanguage: language,
            resolvedLanguage: language, sourceUTF16Length: text.utf16.count,
            highlights: [],
            syntaxNodes: [.init(
                from: 0, to: text.utf16.count, type: "Document", parent: -1
            )],
            bracketPairs: bracketPairs, folds: [], symbols: [], indentation: indentation,
            truncated: .init(
                source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false,
                indentation: false
            )
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor ParserAnalysisGate {
    private(set) var startedTexts: [String] = []
    private(set) var cancelledTexts: [String] = []
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [
        (String, CheckedContinuation<Void, Never>)
    ] = []
    private typealias FinishContinuation = CheckedContinuation<Void, Never>
    private var finishContinuations: [String: FinishContinuation] = [:]
    private var finishedTexts: Set<String> = []

    func analyze(text: String) async -> CodeMirrorParserAnalysis? {
        startedTexts.append(text)
        resumeWaiters()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if finishedTexts.remove(text) != nil {
                    continuation.resume()
                } else if Task.isCancelled {
                    cancelledTexts.append(text)
                    resumeWaiters()
                    continuation.resume()
                } else {
                    finishContinuations[text] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancel(text: text) }
        })
        return CodeMirrorParserAnalysis(
            supported: false, parserKind: .unsupported,
            requestedLanguage: "Swift", resolvedLanguage: "Swift",
            sourceUTF16Length: text.utf16.count, highlights: [],
            syntaxNodes: [], bracketPairs: [], folds: [], symbols: [],
            indentation: [], truncated: .init(
                source: false, highlights: false, syntaxNodes: false,
                bracketPairs: false, folds: false, symbols: false,
                indentation: false
            )
        )
    }

    func waitUntilStarted(count: Int) async {
        guard startedTexts.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitUntilCancelled(text: String) async {
        guard !cancelledTexts.contains(text) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((text, continuation))
        }
    }

    func finish(text: String) {
        if let continuation = finishContinuations.removeValue(forKey: text) {
            continuation.resume()
        } else {
            finishedTexts.insert(text)
        }
    }

    private func cancel(text: String) {
        guard let continuation = finishContinuations.removeValue(forKey: text)
        else { return }
        cancelledTexts.append(text)
        resumeWaiters()
        continuation.resume()
    }

    private func resumeWaiters() {
        let readyStarts = startedWaiters.filter { startedTexts.count >= $0.0 }
        startedWaiters.removeAll { startedTexts.count >= $0.0 }
        readyStarts.forEach { $0.1.resume() }

        let readyCancellations = cancellationWaiters.filter {
            cancelledTexts.contains($0.0)
        }
        cancellationWaiters.removeAll { cancelledTexts.contains($0.0) }
        readyCancellations.forEach { $0.1.resume() }
    }
}

private actor ParserReclamationGate {
    private(set) var callCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func cancelAll() async {
        callCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
