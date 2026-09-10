import XCTest
@testable import LumenEditorCore

final class TextTransformsTests: XCTestCase {
    private func range(_ anchor: Int, _ head: Int) -> SessionSelection {
        SessionSelection(anchor: anchor, head: head)
    }

    private func edit(_ from: Int, _ to: Int, _ insert: String) -> TextTransformEdit {
        TextTransformEdit(from: from, to: to, insert: insert)
    }

    private func transformedText(_ source: String, using plan: TextTransformPlan) -> String {
        TextTransforms.applying(plan.changes, to: source)
    }

    // MARK: - Shared text helpers

    func testLineEndingHelpersPreserveElectronSemantics() {
        XCTAssertEqual(TextTransforms.detectLineEnding("a\nb\r\nc"), .crlf)
        XCTAssertEqual(TextTransforms.detectLineEnding("a\nb\rc"), .cr)
        XCTAssertEqual(TextTransforms.detectLineEnding("a\nb"), .lf)
        XCTAssertEqual(TextTransforms.detectLineEnding("plain"), .lf)
        XCTAssertEqual(TextTransforms.normalizeLineEndings("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(
            TextTransforms.applyLineEnding("a\nb\r\nc", lineEnding: .crlf),
            "a\r\nb\r\nc"
        )
    }

    func testJSONUTF8ByteLengthIncludesQuotesAndEscapes() {
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("abc"), 5)
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("quote\"slash\\"), 16)
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("line\nfeed"), 12)
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("中🙂"), 9)
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("\u{0}\u{1f}"), 14)
        XCTAssertEqual(TextTransforms.jsonStringUTF8ByteLength("", stopAfter: 0), 2)
        XCTAssertGreaterThan(TextTransforms.jsonStringUTF8ByteLength("abcdef", stopAfter: 3), 3)
    }

    func testUnicodeStatisticsMatchElectronFixtures() {
        XCTAssertEqual(
            TextTransforms.textStatistics("hello world\n你好世界"),
            TextStatistics(lines: 2, characters: 16, charactersExcludingWhitespace: 14, words: 4)
        )
        XCTAssertEqual(
            TextTransforms.textStatistics("e\u{301}🙂"),
            TextStatistics(lines: 1, characters: 2, charactersExcludingWhitespace: 2, words: 1)
        )
        XCTAssertEqual(
            TextTransforms.textStatistics(""),
            TextStatistics(lines: 0, characters: 0, charactersExcludingWhitespace: 0, words: 0)
        )
        // CRLF is one grapheme in both current segmenters, but it is not a
        // one-scalar whitespace grapheme for the non-whitespace statistic.
        XCTAssertEqual(
            TextTransforms.textStatistics("\r\n"),
            TextStatistics(lines: 2, characters: 1, charactersExcludingWhitespace: 1, words: 0)
        )
    }

    // MARK: - Case transforms

    func testUnicodeCaseTransforms() {
        XCTAssertEqual(TextTransforms.transformCase("aBc 123!", kind: .swap), "AbC 123!")
        XCTAssertEqual(TextTransforms.transformCase("Straße", kind: .swap), "sTRASSE")
        XCTAssertEqual(TextTransforms.transformCase("İIıi", kind: .swap), "i\u{307}iII")
        XCTAssertEqual(TextTransforms.transformCase("ǅ中🙂", kind: .swap), "ǆ中🙂")
        XCTAssertEqual(TextTransforms.transformCase("ΣΟΣ", kind: .swap), "σοσ")
        XCTAssertEqual(TextTransforms.transformCase("Straße ﬃ", kind: .upper), "STRASSE FFI")
        XCTAssertEqual(TextTransforms.transformCase("İ", kind: .lower), "i\u{307}")
    }

    func testTitleCaseMatchesJavaScriptASCIIWordBoundaries() {
        let fixtures: [(String, String)] = [
            ("hello world", "Hello World"),
            ("DON'T STOP", "Don'T Stop"),
            ("foo_bar", "Foo_bar"),
            ("123ABC", "123abc"),
            ("école", "éCole"),
            ("ÉCOLE TEST", "éCole Test"),
            ("中文 ABC", "中文 Abc"),
            ("abc中文def", "Abc中文Def"),
            ("ΣΟΣ", "σος")
        ]
        for (source, expected) in fixtures {
            XCTAssertEqual(TextTransforms.transformCase(source, kind: .title), expected, source)
        }
    }

    func testCasePlanPreservesDirectionAndMapsUTF16LengthChanges() throws {
        let source = "xStraße!"
        let plan = try XCTUnwrap(TextTransforms.planCaseTransform(
            source, ranges: [range(7, 1)], kind: .swap
        ))
        XCTAssertEqual(plan.changes, [edit(1, 7, "sTRASSE")])
        XCTAssertEqual(plan.ranges, [range(8, 1)])
        XCTAssertEqual(transformedText(source, using: plan), "xsTRASSE!")

        let adjacent = try XCTUnwrap(TextTransforms.planCaseTransform(
            "ßx", ranges: [range(0, 1), range(1, 2)], kind: .swap
        ))
        XCTAssertEqual(adjacent.changes, [edit(0, 1, "SS"), edit(1, 2, "X")])
        XCTAssertEqual(adjacent.ranges, [range(0, 2), range(2, 3)])
        XCTAssertEqual(transformedText("ßx", using: adjacent), "SSX")

        let unchangedBeforeExpansion = try XCTUnwrap(TextTransforms.planCaseTransform(
            "1ß", ranges: [range(0, 1), range(1, 2)], kind: .swap
        ))
        XCTAssertEqual(unchangedBeforeExpansion.changes, [edit(1, 2, "SS")])
        XCTAssertEqual(unchangedBeforeExpansion.ranges, [range(0, 1), range(1, 3)])
    }

    func testCasePlanHandlesMixedSelectionsAndWholeDocumentFallback() throws {
        let mixed = try XCTUnwrap(TextTransforms.planCaseTransform(
            "ab xx CD",
            ranges: [range(0, 2), range(4, 4), range(8, 6)],
            kind: .swap
        ))
        XCTAssertEqual(transformedText("ab xx CD", using: mixed), "AB xx cd")
        XCTAssertEqual(mixed.ranges, [range(0, 2), range(4, 4), range(8, 6)])

        let whole = try XCTUnwrap(TextTransforms.planCaseTransform(
            "aBß", ranges: [range(1, 1), range(2, 2)], kind: .swap
        ))
        XCTAssertEqual(transformedText("aBß", using: whole), "AbSS")
        XCTAssertEqual(whole.ranges, [range(0, 4)])
        XCTAssertNil(TextTransforms.planCaseTransform(
            "123🙂", ranges: [range(0, 0)], kind: .swap
        ))
    }

    // MARK: - Final newline

    func testSingleFinalNewlineNoOpsAndInsertion() throws {
        XCTAssertNil(TextTransforms.planSingleFinalNewline("", ranges: [range(0, 0)]))
        XCTAssertNil(TextTransforms.planSingleFinalNewline("abc\n", ranges: [range(2, 2)]))
        XCTAssertNil(TextTransforms.planSingleFinalNewline("\n", ranges: [range(1, 1)]))

        let plan = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "abc", ranges: [range(0, 0), range(3, 3)]
        ))
        XCTAssertEqual(plan.changes, [edit(3, 3, "\n")])
        XCTAssertEqual(plan.ranges, [range(0, 0), range(3, 3)])
        XCTAssertEqual(transformedText("abc", using: plan), "abc\n")

        let whitespace = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "abc\n \t", ranges: [range(6, 6)]
        ))
        XCTAssertEqual(whitespace.changes, [edit(6, 6, "\n")])
        XCTAssertNil(TextTransforms.planSingleFinalNewline("abc\n \t\n", ranges: [range(7, 7)]))
    }

    func testSingleFinalNewlineDeletesExtrasAndMapsDirectedRanges() throws {
        let source = "abc\n\n\n"
        let plan = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            source, ranges: [range(3, 6), range(6, 3), range(5, 5)]
        ))
        XCTAssertEqual(plan.changes, [edit(4, 6, "")])
        XCTAssertEqual(plan.ranges, [range(3, 4), range(4, 3), range(4, 4)])
        XCTAssertEqual(transformedText(source, using: plan), "abc\n")

        let whitespace = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "abc\n \t\n\n", ranges: [range(8, 3)]
        ))
        XCTAssertEqual(whitespace.changes, [edit(7, 8, "")])
        XCTAssertEqual(whitespace.ranges, [range(7, 3)])

        let newlines = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "\n\n", ranges: [range(2, 2)]
        ))
        XCTAssertEqual(newlines, TextTransformPlan(
            changes: [edit(1, 2, "")], ranges: [range(1, 1)]
        ))
    }

    func testSingleFinalNewlineUsesUTF16Offsets() throws {
        let inserted = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "🙂abc", ranges: [range(5, 5)]
        ))
        XCTAssertEqual(inserted.changes, [edit(5, 5, "\n")])
        XCTAssertEqual(inserted.ranges, [range(5, 5)])

        let trimmed = try XCTUnwrap(TextTransforms.planSingleFinalNewline(
            "🙂\n\n", ranges: [range(4, 4), range(-3, 99)]
        ))
        XCTAssertEqual(trimmed.changes, [edit(3, 4, "")])
        XCTAssertEqual(trimmed.ranges, [range(3, 3), range(0, 3)])
        XCTAssertEqual(transformedText("🙂\n\n", using: trimmed), "🙂\n")
    }

    // MARK: - Pure line transforms

    func testLineOrderingIsStableExactAndUTF16Based() {
        XCTAssertEqual(
            TextTransforms.sortLinesAscending("delta\nalpha\ncharlie\nbravo"),
            "alpha\nbravo\ncharlie\ndelta"
        )
        XCTAssertEqual(
            TextTransforms.sortLinesDescending("alpha\ndelta\nbravo\ncharlie"),
            "delta\ncharlie\nbravo\nalpha"
        )
        let unicode = "é\ne\u{301}\n中\n🙂\né"
        XCTAssertEqual(
            Array(TextTransforms.sortLinesAscending(unicode).utf16),
            Array("e\u{301}\né\né\n中\n🙂".utf16)
        )
        XCTAssertEqual(
            Array(TextTransforms.sortLinesDescending(unicode).utf16),
            Array("🙂\n中\né\né\ne\u{301}".utf16)
        )
        // JS compares UTF-16 code units, so an astral scalar can sort before
        // a lower-valued BMP scalar whose first code unit is larger.
        XCTAssertEqual(
            TextTransforms.sortLinesAscending("\u{e000}\n🙂"),
            "🙂\n\u{e000}"
        )
    }

    func testLineSetReverseAndBlankOperationsPreserveFinalLF() {
        XCTAssertEqual(
            Array(TextTransforms.uniqueLines("é\ne\u{301}\né\nÉ").utf16),
            Array("é\ne\u{301}\nÉ".utf16)
        )
        XCTAssertEqual(TextTransforms.uniqueLines("red\n\nblue\nred\n\nblue\n"), "red\n\nblue\n")
        XCTAssertEqual(TextTransforms.uniqueLines("\n\n"), "\n")
        XCTAssertEqual(TextTransforms.reverseLines("first\n\nlast\n"), "last\n\nfirst\n")
        XCTAssertEqual(TextTransforms.removeBlankLines("alpha\n\n \n\t\nbeta\n"), "alpha\nbeta\n")
        XCTAssertEqual(TextTransforms.removeBlankLines("alpha\n \nbeta"), "alpha\nbeta")
        XCTAssertEqual(TextTransforms.removeBlankLines(" \n\t\n"), "")
        XCTAssertEqual(TextTransforms.removeBlankLines("\u{a0}\nkeep\n"), "\u{a0}\nkeep\n")

        XCTAssertEqual(TextTransforms.sortLinesAscending("beta\nalpha\n"), "alpha\nbeta\n")
        XCTAssertEqual(TextTransforms.sortLinesAscending("beta\nalpha"), "alpha\nbeta")
        for mode in LineTransformMode.allCases {
            XCTAssertEqual(TextTransforms.transformLines("", mode: mode), "")
            XCTAssertFalse(TextTransforms.wouldTransformLines("", mode: mode))
            XCTAssertEqual(TextTransforms.transformLines("only line", mode: mode), "only line")
        }
    }

    // MARK: - Planned line transforms

    func testLinePlanProducesIndependentEditsAndPreservesDirections() {
        let source = "b\na\nkeep\nd\nc\n"
        let plan = TextTransforms.planLineTransform(
            source,
            ranges: [range(4, 0), range(7, 7), range(13, 9)],
            mode: .sortAscending
        )
        XCTAssertEqual(plan.changes, [
            edit(0, 4, "a\nb\n"),
            edit(9, 13, "c\nd\n")
        ])
        XCTAssertEqual(plan.ranges, [range(4, 0), range(7, 7), range(13, 9)])
        XCTAssertEqual(transformedText(source, using: plan), "a\nb\nkeep\nc\nd\n")

        // A selection ending at the next line's start excludes that line.
        XCTAssertEqual(
            TextTransforms.lineTransformEdits(
                "b\na\nkeep\n", ranges: [range(0, 3)], mode: .sortAscending
            ),
            [edit(0, 4, "a\nb\n")]
        )
        XCTAssertEqual(
            TextTransforms.lineTransformEdits(
                "b\na\nkeep\n", ranges: [range(0, 4)], mode: .sortDescending
            ),
            []
        )
        XCTAssertEqual(
            TextTransforms.lineTransformEdits(
                "\nb\na\n", ranges: [range(0, 3)], mode: .reverse
            ),
            [edit(0, 3, "b\n\n")]
        )
    }

    func testLinePlanExpandsSelectionsAndMapsCursorsByLineOccurrence() {
        let interior = TextTransforms.planLineTransform(
            "bax\nabc\n", ranges: [range(1, 6)], mode: .sortAscending
        )
        XCTAssertEqual(interior.changes, [edit(0, 8, "abc\nbax\n")])
        XCTAssertEqual(interior.ranges, [range(0, 8)])

        let reverse = TextTransforms.planLineTransform(
            "bax\nabc\n", ranges: [range(6, 1)], mode: .sortAscending
        )
        XCTAssertEqual(reverse.ranges, [range(8, 0)])

        let cursors = TextTransforms.planLineTransform(
            "b\na", ranges: [range(1, 1), range(2, 2)], mode: .sortAscending
        )
        XCTAssertEqual(cursors.ranges, [range(3, 3), range(0, 0)])

        let mixed = TextTransforms.planLineTransform(
            "bax\nabc\n", ranges: [range(0, 0), range(1, 5)], mode: .sortAscending
        )
        XCTAssertEqual(mixed.ranges, [range(4, 4), range(0, 8)])
        XCTAssertEqual(
            TextTransforms.planLineTransform("b\na", ranges: [range(3, 3)], mode: .sortAscending).ranges,
            [range(1, 1)]
        )
        XCTAssertEqual(
            TextTransforms.planLineTransform("b\na\n", ranges: [range(4, 4)], mode: .sortAscending).ranges,
            [range(4, 4)]
        )
    }

    func testUniqueLinePlanMapsDuplicatesToFirstOccurrence() {
        let plan = TextTransforms.planLineTransform(
            "keep\ndup\ndup\ntail\n",
            ranges: [range(6, 6), range(10, 10), range(14, 14), range(18, 18)],
            mode: .unique
        )
        XCTAssertEqual(plan.changes, [edit(0, 18, "keep\ndup\ntail\n")])
        XCTAssertEqual(plan.ranges, [range(6, 6), range(6, 6), range(10, 10), range(14, 14)])

        let disjoint = TextTransforms.planLineTransform(
            "b\nb\nkeep\nd\nd\n",
            ranges: [range(1, 4), range(7, 7), range(12, 9)],
            mode: .unique
        )
        XCTAssertEqual(disjoint.changes, [edit(0, 4, "b\n"), edit(9, 13, "d\n")])
        XCTAssertEqual(disjoint.ranges, [range(0, 2), range(5, 5), range(9, 7)])
    }

    func testNoOpAndChangedLineBlocksMapAsElectronDoes() {
        let noOp = TextTransforms.planLineTransform(
            "a\nb\n", ranges: [range(1, 3)], mode: .sortAscending
        )
        XCTAssertEqual(noOp, TextTransformPlan(changes: [], ranges: [range(1, 3)]))

        let mixed = TextTransforms.planLineTransform(
            "a\nb\nkeep\nd\nc\n",
            ranges: [range(1, 3), range(12, 10)],
            mode: .sortAscending
        )
        XCTAssertEqual(mixed.changes, [edit(9, 13, "c\nd\n")])
        XCTAssertEqual(mixed.ranges, [range(0, 4), range(13, 9)])
    }

    func testRemoveBlankLinePlanUsesDeletionEditsAndHandlesTerminalLine() {
        let source = "a\n \nkeep\nb\n\t\nend\n"
        let plan = TextTransforms.planLineTransform(
            source,
            ranges: [range(2, 3), range(6, 6), range(12, 11)],
            mode: .removeBlank
        )
        XCTAssertEqual(plan.changes, [edit(2, 4, ""), edit(11, 13, "")])
        XCTAssertEqual(plan.ranges, [range(2, 2), range(4, 4), range(9, 9)])
        XCTAssertEqual(transformedText(source, using: plan), "a\nkeep\nb\nend\n")

        let cursors = TextTransforms.planLineTransform(
            "a\n \nb", ranges: [range(2, 2), range(4, 4)], mode: .removeBlank
        )
        XCTAssertEqual(cursors.changes, [edit(2, 4, "")])
        XCTAssertEqual(cursors.ranges, [range(2, 2), range(2, 2)])

        XCTAssertEqual(
            TextTransforms.planLineTransform("a\n ", ranges: [range(2, 3)], mode: .removeBlank),
            TextTransformPlan(changes: [edit(1, 3, "")], ranges: [range(1, 1)])
        )
        XCTAssertEqual(
            TextTransforms.planLineTransform(
                "a\n \n ", ranges: [range(2, 3), range(4, 5)], mode: .removeBlank
            ).changes,
            [edit(1, 5, "")]
        )
    }

    // MARK: - Paragraph discovery and wrapping

    func testParagraphOptionsTokensAndClassification() {
        XCTAssertEqual(TextTransforms.measurePrefixColumns("\t# "), 10)
        XCTAssertEqual(TextTransforms.measurePrefixColumns("\t# ", tabWidth: 4), 6)
        XCTAssertEqual(
            TextTransforms.sanitizeParagraphTransformOptions(
                ParagraphTransformOptions(column: 0, tabWidth: -1)
            ),
            ResolvedParagraphTransformOptions(column: 80, tabWidth: 8)
        )
        XCTAssertEqual(
            TextTransforms.sanitizeParagraphTransformOptions(
                ParagraphTransformOptions(column: 72.9, tabWidth: 4.2)
            ),
            ResolvedParagraphTransformOptions(column: 72, tabWidth: 4)
        )
        XCTAssertEqual(
            TextTransforms.sanitizeParagraphTransformOptions(
                ParagraphTransformOptions(column: .infinity, tabWidth: .nan)
            ),
            ResolvedParagraphTransformOptions(column: 80, tabWidth: 8)
        )
        XCTAssertEqual(TextTransforms.splitParagraphTokens(" alpha\tbeta  gamma "), ["alpha", "beta", "gamma"])
        XCTAssertEqual(TextTransforms.classifyParagraphLine("  # heading").marker, .hash)
        XCTAssertEqual(TextTransforms.classifyParagraphLine("  #heading").marker, .none)
        XCTAssertTrue(TextTransforms.classifyParagraphLine("  //").isBoundary)
        XCTAssertEqual(TextTransforms.classifyParagraphLine("  /// note").marker, .tripleSlash)
    }

    func testParagraphDiscoveryUsesExactIndentAndMarkerBoundaries() {
        let source = "alpha beta\nstill same\n\n  indented block\n  stays grouped\n# title one\n# title two\n// note\n// more\n#invalid marker line\n"
        let blocks = TextTransforms.findParagraphBlocks(source)
        XCTAssertEqual(blocks.map(\.indent), ["", "  ", "", "", ""])
        XCTAssertEqual(
            blocks.map(\.marker),
            [ParagraphMarker.none, .none, .hash, .slash, .none]
        )
        XCTAssertEqual(blocks.map(\.text), [
            "alpha beta\nstill same",
            "  indented block\n  stays grouped",
            "# title one\n# title two",
            "// note\n// more",
            "#invalid marker line"
        ])
    }

    func testParagraphBlockWrapAndUnwrap() throws {
        let source = "// alpha beta gamma\nafter boundary\n// one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen\n// tail"
        let blocks = TextTransforms.findParagraphBlocks(source)
        XCTAssertEqual(blocks.count, 3)
        let block = try XCTUnwrap(blocks.last)
        XCTAssertEqual(block.marker, .slash)
        XCTAssertEqual(
            TextTransforms.unwrapParagraphBlock(block),
            "// one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen tail"
        )
        XCTAssertEqual(
            TextTransforms.wrapParagraphBlock(block),
            "// one two three four five six seven eight nine ten eleven twelve thirteen\n// fourteen fifteen sixteen tail"
        )
    }

    func testParagraphWrapUsesGraphemesPrefixesTabsAndLongTokens() {
        let plain = TextTransforms.planParagraphTransform(
            "alpha   beta\ngamma\ndelta\n\nkeep outside\n",
            ranges: [range(0, 0)],
            mode: .wrap
        )
        XCTAssertEqual(plain.changes, [edit(0, 24, "alpha beta gamma delta")])
        XCTAssertEqual(plain.ranges, [range(0, 0)])

        let boundary = String(repeating: "x", count: 78) + " y z\n"
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                boundary, ranges: [range(0, 0)], mode: .wrap
            ).changes,
            [edit(0, boundary.utf16.count - 1, String(repeating: "x", count: 78) + " y\nz")]
        )

        let longToken = String(repeating: "a", count: 90)
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                longToken + " tail\n", ranges: [range(0, 0)], mode: .wrap
            ).changes,
            [edit(0, longToken.utf16.count + 5, longToken + "\ntail")]
        )

        let emojiSource = String(repeating: "🙂", count: 78) + " aa bb\n"
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                emojiSource, ranges: [range(0, 0)], mode: .wrap
            ).changes,
            [edit(0, 162, String(repeating: "🙂", count: 78) + "\naa bb")]
        )

        let clusters = "👨‍👩‍👧‍👦 e\u{301} 🇨🇳 x\n"
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                clusters, ranges: [range(0, 0)], mode: .wrap,
                options: ParagraphTransformOptions(column: 5)
            ).changes,
            [edit(0, clusters.utf16.count - 1, "👨‍👩‍👧‍👦 e\u{301} 🇨🇳\nx")]
        )

        let comment = "# alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau\n"
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                comment, ranges: [range(2, 2)], mode: .wrap
            ).changes,
            [edit(0, 99, "# alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi\n# omicron pi rho sigma tau")]
        )

        let tabbed = "\talpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau\n"
        XCTAssertEqual(
            TextTransforms.planParagraphTransform(
                tabbed, ranges: [range(2, 2)], mode: .wrap,
                options: ParagraphTransformOptions(tabWidth: 4)
            ).changes,
            [edit(0, 98, "\talpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi\n\tomicron pi rho sigma tau")]
        )
    }

    // MARK: - Paragraph selection planning

    func testParagraphUnwrapAndCodeLikeText() {
        let unwrap = TextTransforms.planParagraphTransform(
            "# alpha beta\n# gamma   delta\n#\tepsilon\n\nkeep\n",
            ranges: [range(5, 5)], mode: .unwrap
        )
        XCTAssertEqual(unwrap.changes, [edit(0, 38, "# alpha beta gamma delta epsilon")])
        XCTAssertEqual(unwrap.ranges, [range(5, 5)])

        let code = TextTransforms.planParagraphTransform(
            "const x = 1;\nconst y = 2;\n", ranges: [range(0, 0)], mode: .unwrap
        )
        XCTAssertEqual(code.changes, [edit(0, 25, "const x = 1; const y = 2;")])
    }

    func testParagraphPlanTargetsRangesAndExcludesNextLineBoundary() {
        let across = TextTransforms.planParagraphTransform(
            "alpha beta\ngamma delta\n\n# one two\n# three four\n\nend\n",
            ranges: [range(1, 45)], mode: .unwrap
        )
        XCTAssertEqual(across.changes, [
            edit(0, 22, "alpha beta gamma delta"),
            edit(24, 46, "# one two three four")
        ])
        XCTAssertEqual(across.ranges, [range(1, 43)])

        let exclude = TextTransforms.planParagraphTransform(
            "alpha beta\ngamma delta\n\n# one two\n# three four\n",
            ranges: [range(1, 24)], mode: .unwrap
        )
        XCTAssertEqual(exclude.changes, [edit(0, 22, "alpha beta gamma delta")])
    }

    func testParagraphPlanDeduplicatesTargetsAndMapsCaretsLogically() {
        let deduplicated = TextTransforms.planParagraphTransform(
            "alpha beta\ngamma delta\n\nomega psi\n",
            ranges: [range(0, 0), range(2, 18), range(8, 8)],
            mode: .unwrap
        )
        XCTAssertEqual(deduplicated.changes, [edit(0, 22, "alpha beta gamma delta")])
        XCTAssertEqual(deduplicated.ranges, [range(0, 0), range(2, 18), range(8, 8)])

        let backwards = TextTransforms.planParagraphTransform(
            "# alpha beta\n# gamma delta\n", ranges: [range(20, 2)], mode: .unwrap
        )
        XCTAssertEqual(backwards.ranges, [range(18, 2)])

        let caret = TextTransforms.planParagraphTransform(
            "alpha\nbeta gamma\n", ranges: [range(8, 8)], mode: .unwrap
        )
        XCTAssertEqual(caret.changes, [edit(0, 16, "alpha beta gamma")])
        XCTAssertEqual(caret.ranges, [range(8, 8)])

        let prefix = TextTransforms.planParagraphTransform(
            "# alpha\n# beta\n", ranges: [range(1, 1)], mode: .unwrap
        )
        XCTAssertEqual(prefix.ranges, [range(1, 1)])
    }

    func testParagraphPlanMapsOutsideRangesAndLeavesPhysicalNoOpAlone() {
        let shifted = TextTransforms.planParagraphTransform(
            "alpha   beta\ngamma delta\n\none line\n",
            ranges: [range(0, 0), range(29, 37)], mode: .unwrap
        )
        XCTAssertEqual(shifted.changes, [edit(0, 24, "alpha beta gamma delta")])
        XCTAssertEqual(shifted.ranges, [range(0, 0), range(27, 33)])

        let physical = TextTransforms.planParagraphTransform(
            "single physical line only\n\nnext\n",
            ranges: [range(4, 4)], mode: .unwrap
        )
        XCTAssertTrue(physical.changes.isEmpty)

        let outside = TextTransforms.planParagraphTransform(
            "before\n\nalpha beta\ngamma delta\n\nafter\n",
            ranges: [range(8, 8)], mode: .unwrap
        )
        XCTAssertEqual(outside.changes, [edit(8, 30, "alpha beta gamma delta")])
    }
}
