using LumenEditor.Windows.Core.Editing;
using LumenEditor.Windows.Core.Find;
using Xunit;

namespace LumenEditor.Windows.Core.Tests;

public sealed class EditingTests
{
    [Fact]
    public void Buffer_ReplacesAndUndoRedoesAsSingleTransaction()
    {
        var buffer = new EditorBuffer("one two", new TextSelection(4, 7));
        Assert.True(buffer.Replace(buffer.Selection, "three"));
        Assert.Equal("one three", buffer.Text);
        Assert.True(buffer.Undo());
        Assert.Equal("one two", buffer.Text);
        Assert.True(buffer.Redo());
        Assert.Equal("one three", buffer.Text);
    }

    [Fact]
    public void Buffer_RejectsSurrogatePairSplit()
    {
        var buffer = new EditorBuffer("a😀b");
        Assert.False(buffer.Replace(new TextSelection(2, 2), "x"));
        Assert.Equal("a😀b", buffer.Text);
    }

    [Fact]
    public void Find_UsesWholeWordAndRejectsZeroWidthReplacement()
    {
        var buffer = new EditorBuffer("Cat cat catalog CAT");
        Assert.Equal(3, FindEngine.Find(buffer.Text, new FindQuery("cat", WholeWord: true)).Count);
        Assert.True(FindEngine.ReplaceAll(buffer, new FindQuery("cat", WholeWord: true), "dog"));
        Assert.Equal("dog dog catalog dog", buffer.Text);
        Assert.False(FindEngine.ReplaceAll(buffer, new FindQuery("(?=dog)", UseRegex: true), "x"));
    }

    [Fact]
    public void Find_NavigatesBothDirectionsWithoutMutatingText()
    {
        var buffer = new EditorBuffer("one two one", new TextSelection(0, 0));
        var query = new FindQuery("one");

        var first = Assert.IsType<FindMatch>(FindEngine.FindNext(buffer.Text, query, buffer.Selection));
        Assert.Equal(new FindMatch(0, 3), first);
        buffer.SetSelection(new TextSelection(first.Start, first.Start + first.Length));
        Assert.Equal(new FindMatch(8, 3), FindEngine.FindNext(buffer.Text, query, buffer.Selection));
        Assert.Equal(new FindMatch(8, 3), FindEngine.FindNext(buffer.Text, query, new TextSelection(0, 0), reverse: true));
        Assert.Equal("one two one", buffer.Text);
    }

    [Fact]
    public void ReplaceNext_SelectsFirstThenReplacesWithRegexCapturesAsOneUndoStep()
    {
        var buffer = new EditorBuffer("a1 a2", new TextSelection(0, 0));
        var query = new FindQuery(@"a(\d)", UseRegex: true);

        Assert.Equal(ReplaceNextOutcome.Selected, FindEngine.ReplaceNextOrSelect(buffer, query, "x$1"));
        Assert.Equal(new TextSelection(0, 2), buffer.Selection);
        Assert.Equal(ReplaceNextOutcome.Replaced, FindEngine.ReplaceNextOrSelect(buffer, query, "x$1"));
        Assert.Equal("x1 a2", buffer.Text);
        Assert.Equal(new TextSelection(3, 5), buffer.Selection);
        Assert.True(buffer.Undo());
        Assert.Equal("a1 a2", buffer.Text);
    }

    [Fact]
    public void ReplaceAll_ExpandsRegexCapturesAndUnquotesLiteralEscapes()
    {
        var regex = new EditorBuffer("a1 a2");
        Assert.True(FindEngine.ReplaceAll(regex, new FindQuery(@"a(\d)", UseRegex: true), "x$1"));
        Assert.Equal("x1 x2", regex.Text);

        var literal = new EditorBuffer("one\ntwo");
        Assert.True(FindEngine.ReplaceAll(literal, new FindQuery(@"one\ntwo"), @"left\nright"));
        Assert.Equal("left\nright", literal.Text);
    }

    [Fact]
    public void LineTransforms_AreSingleUndoableTransactions()
    {
        var buffer = new EditorBuffer("b  \na\na\n", new TextSelection(0, 7));
        Assert.True(buffer.TrimTrailingWhitespace());
        Assert.Equal("b\na\na\n", buffer.Text);
        Assert.True(buffer.TransformSelectedLines(lines => lines.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList()));
        Assert.Equal("a\nb\n", buffer.Text);
        Assert.True(buffer.Undo());
        Assert.Equal("b\na\na\n", buffer.Text);
    }

    [Fact]
    public void LineEditing_IndentsOutdentsAndDeletesWholeLines()
    {
        var buffer = new EditorBuffer("one\ntwo\nthree", new TextSelection(4, 7));
        Assert.True(buffer.IndentSelectedLines("  "));
        Assert.Equal("one\n  two\nthree", buffer.Text);
        Assert.True(buffer.IndentSelectedLines("  ", outdent: true));
        Assert.Equal("one\ntwo\nthree", buffer.Text);
        Assert.True(buffer.DeleteSelectedLines());
        Assert.Equal("one\nthree", buffer.Text);
    }

    [Fact]
    public void CommentMoveCopyAndDuplicate_AreUndoableLineTransactions()
    {
        var comment = new EditorBuffer("  one\n  two\nthree", new TextSelection(0, 12));
        Assert.True(comment.ToggleLineComment());
        Assert.Equal("  // one\n  // two\nthree", comment.Text);
        Assert.True(comment.ToggleLineComment());
        Assert.Equal("  one\n  two\nthree", comment.Text);

        var move = new EditorBuffer("a\nb\nc\n", new TextSelection(2, 3));
        Assert.True(move.MoveSelectedLines(down: false));
        Assert.Equal("b\na\nc\n", move.Text);
        Assert.True(move.CopySelectedLines(down: true));
        Assert.Equal("b\nb\na\nc\n", move.Text);
        Assert.True(move.Undo());
        Assert.Equal("b\na\nc\n", move.Text);

        var duplicate = new EditorBuffer("alpha beta", new TextSelection(0, 5));
        Assert.True(duplicate.DuplicateSelectionOrLine());
        Assert.Equal("alphaalpha beta", duplicate.Text);
    }

    [Fact]
    public void DeleteTransposeAndCaseTransforms_PreserveUtf16Boundaries()
    {
        var words = new EditorBuffer("one  two", new TextSelection(8, 8));
        Assert.True(words.DeleteWord(backward: true));
        Assert.Equal("one  ", words.Text);
        Assert.True(words.DeleteWord(backward: true));
        Assert.Equal("", words.Text);

        var emoji = new EditorBuffer("a😀b", new TextSelection(3, 3));
        Assert.True(emoji.TransposeCharacters());
        Assert.Equal("ab😀", emoji.Text);

        var casing = new EditorBuffer("Hello 世界", new TextSelection(0, 5));
        Assert.True(casing.SwapCase());
        Assert.Equal("hELLO 世界", casing.Text);
        Assert.True(casing.ToTitleCase());
        Assert.Equal("Hello 世界", casing.Text);
    }

    [Fact]
    public void BlockCommentJoinAndIndentConversion_WorkOnSelectedBlock()
    {
        var block = new EditorBuffer("one\ntwo", new TextSelection(0, 7));
        Assert.True(block.ToggleBlockComment());
        Assert.Equal("/*one\ntwo*/", block.Text);
        Assert.True(block.ToggleBlockComment());
        Assert.Equal("one\ntwo", block.Text);
        Assert.True(block.JoinSelectedLines());
        Assert.Equal("one two", block.Text);

        var indentation = new EditorBuffer("\tfoo\n    bar", new TextSelection(0, 12));
        Assert.True(indentation.ConvertIndentation(4, toSpaces: true));
        Assert.Equal("    foo\n    bar", indentation.Text);
        Assert.True(indentation.ConvertIndentation(4, toSpaces: false));
        Assert.Equal("\tfoo\n\tbar", indentation.Text);
    }

    [Fact]
    public void SelectionCommands_SelectLineAndMatchingBrackets()
    {
        var line = new EditorBuffer("one\ntwo\nthree", new TextSelection(5, 5));
        Assert.True(line.SelectLine());
        Assert.Equal(new TextSelection(4, 7), line.Selection);

        var brackets = new EditorBuffer("call(a[0])", new TextSelection(5, 5));
        Assert.True(brackets.SelectMatchingBracket(includeBrackets: false));
        Assert.Equal("a[0]", brackets.Text[brackets.Selection.Start..brackets.Selection.End]);
        brackets.SetSelection(new TextSelection(4, 4));
        Assert.True(brackets.GoToMatchingBracket());
        Assert.Equal(9, brackets.Selection.Start);
    }

    [Fact]
    public void ParagraphTransforms_PreserveCommentPrefixesAndAreUndoable()
    {
        var buffer = new EditorBuffer("// alpha beta gamma delta epsilon\n// zeta eta", new TextSelection(4, 4));
        Assert.True(buffer.WrapParagraph(24));
        Assert.Equal("// alpha beta gamma\n// delta epsilon zeta\n// eta", buffer.Text);
        Assert.True(buffer.UnwrapParagraph());
        Assert.Equal("// alpha beta gamma delta epsilon zeta eta", buffer.Text);
        Assert.True(buffer.Undo());
        Assert.Contains("\n// delta", buffer.Text);
    }

    [Fact]
    public void ReindentSelection_UsesBraceDepthAndIgnoresBracesInStringsAndComments()
    {
        var text = "if (ready) {\nvalue = \"{\"; // }\nif (nested) {\nwork();\n}\n}";
        var buffer = new EditorBuffer(text, new TextSelection(0, text.Length));
        Assert.True(buffer.ReindentSelectedLines(2, insertSpaces: true));
        Assert.Equal("if (ready) {\n  value = \"{\"; // }\n  if (nested) {\n    work();\n  }\n}", buffer.Text);
        Assert.True(buffer.Undo());
        Assert.Equal(text, buffer.Text);
    }

    [Fact]
    public void ReindentSelection_DoesNotFlattenNonBraceLanguages()
    {
        var buffer = new EditorBuffer("if ready:\n  work()", new TextSelection(0, 18));
        Assert.False(buffer.ReindentSelectedLines(2, insertSpaces: true));
        Assert.Equal("if ready:\n  work()", buffer.Text);
    }

    [Fact]
    public void IncrementalDiff_FindsNavigableHunksAndRevertsOne()
    {
        var baseline = "one\ntwo\nthree\nfour";
        var current = "one\nTWO\nthree\nadded\nfour";
        var changes = IncrementalDiff.Compute(baseline, current);
        Assert.Equal(2, changes.Count);
        Assert.Equal(IncrementalChangeKind.Modified, changes[0].Kind);
        Assert.Equal(2, changes[0].Line);
        Assert.Equal(IncrementalChangeKind.Added, changes[1].Kind);
        var firstRevert = IncrementalDiff.Revert(current, changes[0]);
        Assert.Equal("one\ntwo\nthree\nadded\nfour", firstRevert);
        Assert.Equal(baseline, IncrementalDiff.Revert(
            firstRevert, Assert.Single(IncrementalDiff.Compute(baseline, firstRevert))));
    }

    [Fact]
    public void IncrementalDiff_IsBoundedAndRepresentsDeletionAtInsertionPoint()
    {
        Assert.Empty(IncrementalDiff.Compute(String.Join('\n', Enumerable.Repeat("x", 4)), "x", maximumLines: 2));
        var deleted = Assert.Single(IncrementalDiff.Compute("one\ntwo", "one"));
        Assert.Equal(IncrementalChangeKind.Deleted, deleted.Kind);
        Assert.Equal(0, deleted.LineCount);
        Assert.Equal("one\ntwo", IncrementalDiff.Revert("one", deleted));
    }

    [Fact]
    public void SelectionHistory_UndoesAndRedoesWithoutChangingText()
    {
        var history = new SelectionHistory();
        var cursor = new TextSelection(1, 1);
        var word = new TextSelection(0, 3);
        history.Observe(cursor, word);
        Assert.Equal(cursor, history.Undo(word));
        Assert.Equal(word, history.Redo(cursor));
        Assert.Null(history.Redo(word));
    }

    [Fact]
    public void SelectionHistory_RestoresTheEntireMultiSelectionSet()
    {
        var history = new SelectionHistory();
        var first = MultiSelectionSet.Single(new TextSelection(1, 1));
        var second = new MultiSelectionSet([new TextSelection(1, 1), new TextSelection(4, 4)], 1);
        history.Observe(first, second);

        Assert.Equal(first, history.Undo(second));
        Assert.Equal(second, history.Redo(first));
    }

    [Fact]
    public void SyntaxSelection_ExpandsWordBracketLineAndDocument()
    {
        var buffer = new EditorBuffer("call(alpha)\nnext", new TextSelection(7, 7));
        Assert.True(buffer.ExpandSelection());
        Assert.Equal("alpha", buffer.Text[buffer.Selection.Start..buffer.Selection.End]);
        Assert.True(buffer.ExpandSelection());
        Assert.Equal("(alpha)", buffer.Text[buffer.Selection.Start..buffer.Selection.End]);
        Assert.True(buffer.ExpandSelection());
        Assert.Equal("call(alpha)", buffer.Text[buffer.Selection.Start..buffer.Selection.End]);
        Assert.True(buffer.ExpandSelection());
        Assert.Equal(buffer.Text, buffer.Text[buffer.Selection.Start..buffer.Selection.End]);
    }

    [Fact]
    public void SyntaxSelection_IgnoresBracketsInsideStringsAndComments()
    {
        var buffer = new EditorBuffer("call(\"}\") // ]\n", new TextSelection(6, 6));
        Assert.True(buffer.SelectParentSyntax());
        Assert.Equal("\"}\"", buffer.Text[buffer.Selection.Start..buffer.Selection.End]);
    }

    [Fact]
    public void MultiSelection_AddsVerticalCursorsAndPreservesThemAcrossUndoRedo()
    {
        var buffer = new EditorBuffer("one\ntwo\nx", new TextSelection(2, 2));
        Assert.True(MultiSelectionCommands.AddVertical(buffer, below: true));
        Assert.True(MultiSelectionCommands.AddVertical(buffer, below: true));
        Assert.Equal([2, 6, 9], buffer.Selections.Ranges.Select(range => range.Head));

        Assert.True(MultiSelectionCommands.ApplyPrimaryEdit(buffer, "one\ntwo\nx!", new TextSelection(10, 10)));
        Assert.Equal("on!e\ntw!o\nx!", buffer.Text);
        Assert.Equal([3, 8, 12], buffer.Selections.Ranges.Select(range => range.Head));
        Assert.True(buffer.Undo());
        Assert.Equal("one\ntwo\nx", buffer.Text);
        Assert.Equal([2, 6, 9], buffer.Selections.Ranges.Select(range => range.Head));
        Assert.True(buffer.Redo());
        Assert.Equal("on!e\ntw!o\nx!", buffer.Text);
    }

    [Fact]
    public void MultiSelection_SelectsSkipsRemovesAndFindsAllOccurrences()
    {
        var buffer = new EditorBuffer("one two one tone", new TextSelection(1, 1));
        Assert.True(MultiSelectionCommands.SelectNextOccurrence(buffer, skip: false));
        Assert.Equal([new TextSelection(0, 3)], buffer.Selections.Ranges);
        Assert.True(MultiSelectionCommands.SelectNextOccurrence(buffer, skip: false));
        Assert.Equal([new TextSelection(0, 3), new TextSelection(8, 11)], buffer.Selections.Ranges);
        Assert.True(MultiSelectionCommands.RemoveMain(buffer));
        Assert.Single(buffer.Selections.Ranges);
        Assert.True(MultiSelectionCommands.SelectAllOccurrences(buffer));
        Assert.Equal(3, buffer.Selections.Ranges.Count);

        var skip = new EditorBuffer("x x x", new TextSelection(0, 1));
        Assert.True(MultiSelectionCommands.SelectNextOccurrence(skip, skip: true));
        Assert.Equal(new TextSelection(2, 3), skip.Selection);
    }

    [Fact]
    public void MultiSelection_AddsLineBoundariesAndSplitsSelectedLines()
    {
        var starts = new EditorBuffer("one\ntwo\nthree", new TextSelection(1, 8));
        Assert.True(MultiSelectionCommands.AddLineBoundaries(starts, atEnd: false));
        Assert.Equal([0, 4], starts.Selections.Ranges.Select(range => range.Head));

        var ends = new EditorBuffer("one\ntwo\nthree", new TextSelection(1, 8));
        Assert.True(MultiSelectionCommands.AddLineBoundaries(ends, atEnd: true));
        Assert.Equal([3, 7], ends.Selections.Ranges.Select(range => range.Head));

        var empty = new EditorBuffer("one\ntwo", new TextSelection(1, 1));
        Assert.False(MultiSelectionCommands.AddLineBoundaries(empty, atEnd: false, requireNonEmpty: true));
    }

    [Fact]
    public void MultiSelection_ReplicatesReplacementAndBackspaceAsAtomicEdits()
    {
        var replacement = new EditorBuffer("cat cat");
        replacement.SetSelections(new MultiSelectionSet(
            [new TextSelection(0, 3), new TextSelection(4, 7)], mainIndex: 1));
        Assert.True(MultiSelectionCommands.ApplyPrimaryEdit(replacement, "cat dog", new TextSelection(7, 7)));
        Assert.Equal("dog dog", replacement.Text);
        Assert.Equal([3, 7], replacement.Selections.Ranges.Select(range => range.Head));

        var deletion = new EditorBuffer("ab ab");
        deletion.SetSelections(new MultiSelectionSet(
            [new TextSelection(2, 2), new TextSelection(5, 5)], mainIndex: 1));
        Assert.True(MultiSelectionCommands.ApplyPrimaryEdit(deletion, "ab a", new TextSelection(4, 4)));
        Assert.Equal("a a", deletion.Text);
        Assert.True(deletion.Undo());
        Assert.Equal("ab ab", deletion.Text);

        var forward = new EditorBuffer("aa aa");
        forward.SetSelections(new MultiSelectionSet(
            [new TextSelection(0, 0), new TextSelection(3, 3)], mainIndex: 0));
        Assert.True(MultiSelectionCommands.ApplyPrimaryEdit(forward, "a aa", new TextSelection(0, 0)));
        Assert.Equal("a a", forward.Text);
    }

    [Fact]
    public void StructuralInput_InsertsIndentedNewlinesAcrossSelectionsAsOneTransaction()
    {
        var text = "if (a) {}\nif (b) {}";
        var buffer = new EditorBuffer(text);
        buffer.SetSelections(new MultiSelectionSet([new(8, 8), new(18, 18)]));

        Assert.True(EditorInputPlanner.InsertNewline(buffer, 2, insertSpaces: true,
            [new(8, 0, 2, true), new(18, 0, 2, true)]));
        Assert.Equal("if (a) {\n  \n}\nif (b) {\n  \n}", buffer.Text);
        Assert.Equal([11, 25], buffer.Selections.Ranges.Select(value => value.Head));
        Assert.True(buffer.Undo());
        Assert.Equal(text, buffer.Text);
    }

    [Fact]
    public void StructuralInput_SurroundsSelectionsWithPairsAtomically()
    {
        var buffer = new EditorBuffer("one two");
        buffer.SetSelections(new MultiSelectionSet([new(0, 3), new(4, 7)], mainIndex: 1));

        Assert.True(EditorInputPlanner.InsertPair(buffer, '('));
        Assert.Equal("(one) (two)", buffer.Text);
        Assert.Equal([4, 10], buffer.Selections.Ranges.Select(value => value.Head));
        Assert.True(buffer.Undo());
        Assert.Equal("one two", buffer.Text);
    }

    [Fact]
    public void StructuralInput_UsesLexicalIndentFallbackAndGuardsQuotes()
    {
        var python = new EditorBuffer("if ready:", new(9, 9));
        Assert.True(EditorInputPlanner.InsertNewline(
            python, 4, insertSpaces: true, language: "python"));
        Assert.Equal("if ready:\n    ", python.Text);

        var word = new EditorBuffer("alpha", new(2, 2));
        Assert.False(EditorInputPlanner.InsertPair(word, '"'));
        Assert.Equal("alpha", word.Text);
    }

    [Fact]
    public void StructuralInput_SkipsAndDeletesEmptyPairsAcrossCursors()
    {
        var skip = new EditorBuffer("() []");
        skip.SetSelections(new MultiSelectionSet([new(1, 1), new(4, 4)]));
        Assert.False(EditorInputPlanner.SkipClosing(skip, ')'));
        skip.SetSelection(new(1, 1));
        Assert.True(EditorInputPlanner.SkipClosing(skip, ')'));
        Assert.Equal(new TextSelection(2, 2), skip.Selection);
        var quote = new EditorBuffer("\"\"", new(1, 1));
        Assert.True(EditorInputPlanner.SkipClosing(quote, '"'));
        Assert.Equal(new TextSelection(2, 2), quote.Selection);

        var deletion = new EditorBuffer("() []");
        deletion.SetSelections(new MultiSelectionSet([new(1, 1), new(4, 4)]));
        Assert.True(EditorInputPlanner.DeleteEmptyPairs(deletion));
        Assert.Equal(" ", deletion.Text);
        Assert.Equal([0, 1], deletion.Selections.Ranges.Select(value => value.Head));
        Assert.True(deletion.Undo());
        Assert.Equal("() []", deletion.Text);
    }
}
