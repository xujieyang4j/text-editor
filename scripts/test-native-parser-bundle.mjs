import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import vm from "node:vm"
import { languages } from "@codemirror/language-data"

const source = await readFile(new URL(
  "../native-macos/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js",
  import.meta.url
), "utf8")
const context = vm.createContext({})
new vm.Script(source, { filename: "CodeMirrorParserBundle.js" }).runInContext(context)
const parser = context.LumenCodeMirrorParser
assert.equal(parser.protocolVersion, 2)
const canonicalLanguages = languages.map(descriptor => descriptor.name).sort()
assert.equal(parser.supportedLanguages.length, 143)
assert.equal(new Set(parser.supportedLanguages).size, 143)
assert.deepEqual(Array.from(parser.supportedLanguages), canonicalLanguages)

function analyze(text, language, extra = {}) {
  return JSON.parse(parser.analyze(JSON.stringify({ text, language, ...extra }))).result
}

const MAX_NEWLINE_PROBES = 8

const sourceText = "😀 function demo(value) {\nreturn (value + 1)\n}\n"
const javascript = analyze(sourceText, "JavaScript", { tabWidth: 4, indentWidth: 4 })
assert.equal(javascript.supported, true)
assert.equal(javascript.sourceUTF16Length, sourceText.length)
assert.equal(javascript.syntaxNodes[0].from, 0)
assert.equal(javascript.syntaxNodes[0].to, sourceText.length)
assert.ok(javascript.highlights.some(span => span.kind === "keyword" && span.from === 3))
assert.ok(javascript.bracketPairs.some(pair => sourceText.slice(pair.open, pair.close + 1) === "(value)"))
assert.ok(javascript.folds.length > 0)
assert.equal(javascript.folds[0].from, 26)
assert.equal(javascript.folds[0].to, 45)
assert.equal(javascript.indentation.find(item => item.lineFrom === 26)?.columns, 4)
assert.ok(Object.values(javascript.truncated).every(value => value === false))

const newlineCases = [
  ["JSX", "const view = <div><span>text</span></div>", 18, 2],
  ["HTML", "<section><p>text</p></section>", 9, 2],
  ["Python", "result = call(value)", 14, 2],
  ["SQL", "SELECT id,name FROM users", 10, 2],
  ["Markdown", "- first", 7, null]
]
for (const [language, text, position, expected] of newlineCases) {
  const result = analyze(text, language, {
    tabWidth: 4, indentWidth: 2, newlineIndentationPositions: [position]
  })
  assert.deepEqual(plain(result.newlineIndentation), [{
    position, columns: expected, doubleColumns: expected, explode: false
  }], `${language} exact newline indentation`)
  assert.equal(result.newlineIndentationTransitions.length, 6, language)
}

const pythonTransition = analyze("if ready", "Python", {
  tabWidth: 4, indentWidth: 2, newlineIndentationPositions: [8]
}).newlineIndentationTransitions.find(entry => entry.insert === ":")
assert.deepEqual(plain(pythonTransition), {
  position: 8, insert: ":", columns: 2, doubleColumns: 0, explode: false
})
const jsxTransition = analyze("const view = <div", "JSX", {
  tabWidth: 4, indentWidth: 2, newlineIndentationPositions: [17]
}).newlineIndentationTransitions.find(entry => entry.insert === ">")
assert.equal(jsxTransition.columns, 2)
const htmlPair = analyze("<section></section>", "HTML", {
  tabWidth: 4, indentWidth: 2, newlineIndentationPositions: [9]
}).newlineIndentation[0]
assert.deepEqual(plain(htmlPair), {
  position: 9, columns: 0, doubleColumns: 2, explode: true
})
assert.equal(analyze("x()y", "JavaScript", {
  newlineIndentationPositions: [1]
}).newlineIndentation[0].explode, false)
const boundedProbeRequest = analyze("value", "JavaScript", {
  newlineIndentationPositions: Array.from(
    { length: MAX_NEWLINE_PROBES + 1 }, (_, index) => index
  )
})
assert.deepEqual(plain(boundedProbeRequest.newlineIndentation), [])
assert.deepEqual(plain(boundedProbeRequest.newlineIndentationTransitions), [])
const complexProbeSource = Array.from(
  { length: 250 }, (_, index) => `function f${index}(value) { return [value, ${index}] }`
).join("\n")
const complexProbePositions = Array.from(
  { length: MAX_NEWLINE_PROBES },
  (_, index) => Math.floor(complexProbeSource.length * (index + 1)
    / (MAX_NEWLINE_PROBES + 1))
)
const complexStartedAt = performance.now()
const complexProbes = analyze(complexProbeSource, "JavaScript", {
  tabWidth: 4, indentWidth: 2,
  newlineIndentationPositions: complexProbePositions
})
assert.equal(complexProbes.newlineIndentation.length, MAX_NEWLINE_PROBES)
assert.equal(
  complexProbes.newlineIndentationTransitions.length,
  MAX_NEWLINE_PROBES * 6
)
assert.ok(
  performance.now() - complexStartedAt < 900,
  "bounded newline probes must stay below the production worker deadline"
)
const kindCases = [
  ["JavaScript", "const s = \"x\"; // note\nclass Type {}", ["keyword", "string", "comment", "type"]],
  ["JSON", '{"enabled": true, "count": 2}', ["constant", "number"]],
  ["Markdown", "# **Heading**", ["markup"]]
]
for (const [language, text, expectedKinds] of kindCases) {
  const kinds = new Set(analyze(text, language).highlights.map(span => span.kind))
  for (const kind of expectedKinds) assert.ok(kinds.has(kind), `${language}: ${kind}`)
}

const stringBrackets = analyze("const value = '(]';", "JavaScript")
assert.equal(stringBrackets.bracketPairs.length, 0)
const malformedBrackets = analyze("([)]", "JavaScript")
assert.deepEqual(Array.from(malformedBrackets.bracketPairs), [])
const recoveredBrackets = analyze("([)]()", "JavaScript")
assert.deepEqual(
  Array.from(recoveredBrackets.bracketPairs, pair => [pair.open, pair.close]), [[4, 5]]
)
const incomplete = analyze("(", "JavaScript")
assert.equal(incomplete.supported, true)
assert.equal(incomplete.syntaxNodes[0].to, 1)
assert.ok(incomplete.syntaxNodes.some(node => node.from === 1 && node.to === 1))
const tabHeading = analyze("# A\tB", "Markdown")
assert.equal(tabHeading.symbols[0].label, "A B")
const controlHeading = analyze("# A\u0007B\u007fC\u0085D\u2028E\u2029F", "Markdown")
assert.equal(controlHeading.symbols[0].label, "A B C D E F")
assert.equal(analyze("# A\u0007#", "Markdown").symbols[0].label, "A")
assert.deepEqual(Array.from(analyze("# #", "Markdown").symbols), [])
for (const text of [
  "function first() {\r\n  return 1\r\n}\r\nfunction second() {}",
  "# First\r# Second"
]) {
  const language = text.startsWith("#") ? "Markdown" : "JavaScript"
  const result = analyze(text, language)
  assert.equal(result.sourceUTF16Length, text.length)
  assert.equal(result.syntaxNodes[0].to, text.length)
  assert.equal(result.truncated.source, false)
  assert.ok(result.symbols.some(symbol => symbol.line === 2 || symbol.line === 4))
}
const mixedLineEndings = analyze(
  "function a() {}\rfunction b() {}\nfunction c() {}", "JavaScript"
)
assert.equal(mixedLineEndings.supported, false)
const canonicalResults = new Map()
for (const language of canonicalLanguages) {
  const result = analyze("value", language)
  assert.equal(result.supported, true, `${language} must load synchronously`)
  assert.equal(result.schemaVersion, 2)
  assert.equal(result.sourceUTF16Length, 5)
  assert.equal(result.resolvedLanguage, language)
  canonicalResults.set(language, result)
}
assert.equal(
  Array.from(canonicalResults.values()).filter(result => result.parserKind === "stream").length,
  110
)
assert.equal(
  Array.from(canonicalResults.values()).filter(result => result.parserKind === "lezer").length,
  33
)

const aliases = languages.flatMap(descriptor => descriptor.alias)
assert.equal(aliases.length, 184)
assert.equal(new Set(aliases).size, 182)
const aliasCounts = new Map()
for (const alias of aliases) aliasCounts.set(alias, (aliasCounts.get(alias) || 0) + 1)
assert.deepEqual(
  Array.from(aliasCounts).filter(([, count]) => count > 1),
  [["objective-c", 2], ["objective-c++", 2]]
)
for (const descriptor of languages) {
  for (const alias of new Set(descriptor.alias)) {
    const result = analyze("value", alias)
    assert.equal(result.supported, true, `${alias} alias must be supported`)
    assert.equal(result.resolvedLanguage, descriptor.name, `${alias} alias resolution`)
    assert.equal(result.parserKind, canonicalResults.get(descriptor.name).parserKind)
  }
}
const rubyAlias = analyze("value", "  RB  ")
assert.equal(rubyAlias.resolvedLanguage, "Ruby")
assert.equal(rubyAlias.parserKind, "stream")

function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

function assertStreamShape(result, text, language, expectedBracketPairs = []) {
  assert.equal(result.supported, true, language)
  assert.equal(result.parserKind, "stream", language)
  assert.equal(result.resolvedLanguage, language)
  assert.deepEqual(plain(result.syntaxNodes), [
    { from: 0, to: text.length, type: "Document", parent: -1 }
  ])
  assert.deepEqual(plain(result.bracketPairs), expectedBracketPairs)
  assert.deepEqual(plain(result.folds), [])
  assert.deepEqual(plain(result.symbols), [])
  assert.ok(Object.values(result.truncated).every(value => value === false))
}

for (const language of [
  "C#", "Dart", "Kotlin", "Objective-C", "Objective-C++", "Scala", "Squirrel",
  "F#", "OCaml", "SML", "Haxe", "HXML", "RPM Changes", "RPM Spec",
  "MscGen", "Xù", "MsGenny", "Clojure", "ClojureScript", "sTeX", "LaTeX",
  "Verilog", "SystemVerilog"
]) {
  assertStreamShape(analyze("value", language), "value", language)
}

const swiftText = "😀\nlet value = 1 // note\n"
const swift = analyze(swiftText, "Swift")
assertStreamShape(swift, swiftText, "Swift")
assert.equal(swift.sourceUTF16Length, 25)
for (const expected of [
  { from: 3, to: 6, kind: "keyword" },
  { from: 15, to: 16, kind: "number" },
  { from: 17, to: 24, kind: "comment" }
]) assert.ok(swift.highlights.some(span => span.from === expected.from
  && span.to === expected.to && span.kind === expected.kind))
assert.deepEqual(plain(swift.indentation), [
  { lineFrom: 0, columns: 0 }, { lineFrom: 3, columns: 0 },
  { lineFrom: 25, columns: 0 }
])

const streamBracketCases = [
  ["Swift",
    "😀 func run(_ x: Int) {\n"
      + "  let ignored = \"([)]\" // {]\n"
      + "  /* ( [ { } ] ) */\n"
      + "  if (x > 0) { print(x) }\n}",
    [[11, 20], [22, 99], [78, 84], [86, 97], [93, 95]]],
  ["Ruby",
    "def f(x)\n  s = \"([)]\" # {}\n  [x, {a: (1)}]\nend",
    [[5, 7], [29, 41], [33, 40], [37, 39]]],
  ["Shell",
    "f() { echo \"([)]\" # {}\n  (echo ok)\n}",
    [[1, 2], [4, 35], [25, 33]]]
]
for (const [language, text, expected] of streamBracketCases) {
  const result = analyze(text, language)
  assertStreamShape(
    result, text, language, expected.map(([open, close]) => ({ open, close }))
  )
}
assert.deepEqual(
  plain(analyze("([)]()", "Swift").bracketPairs),
  [{ open: 4, close: 5 }]
)
const alternateStringStyles = [
  ["Ruby", "value = /()/; call()", [{ open: 18, close: 19 }]],
  ["Perl", "my $value = qr/()/; call()", [{ open: 24, close: 25 }]],
  ["Shell", "echo `printf ()`", []],
  ["Scala", "F('('); G()", [
    { open: 1, close: 5 }, { open: 9, close: 10 }
  ]],
  ["Mathematica", "\\[Alpha] ()", [{ open: 9, close: 10 }]]
]
for (const [language, text, expected] of alternateStringStyles) {
  assert.deepEqual(plain(analyze(text, language).bracketPairs), expected, language)
}
const cappedStreamBrackets = analyze("()".repeat(10_001), "Swift")
assert.equal(cappedStreamBrackets.bracketPairs.length, 10_000)
assert.equal(cappedStreamBrackets.truncated.bracketPairs, true)
const longStreamLine = `let value = ${"x".repeat(10_100)} \"()\"; run()`
assert.deepEqual(
  plain(analyze(longStreamLine, "Swift").bracketPairs),
  [{ open: longStreamLine.lastIndexOf("("), close: longStreamLine.lastIndexOf(")") }]
)

const quotedTokenCases = [
  ["EBNF", "rule = \"()\"; call(arg);", [{ open: 17, close: 21 }]],
  ["EBNF", "rule = \"escaped \\\"()\\\"\"; call()",
    [{ open: 29, close: 30 }]],
  ["EBNF", "rule = \"first\n()\nlast\"; call()",
    [{ open: 28, close: 29 }]],
  ["TOML", "\"()\" = 1\nbare() = 2\nvalue = \"[]\"",
    [{ open: 13, close: 14 }]],
  ["TOML", "\"escaped \\\"()\\\"\" = 1\nbare() = 2",
    [{ open: 25, close: 26 }]],
  ["TOML", "\"\"\"quoted\n()\nkey\"\"\" = 1\nbare() = 2",
    [{ open: 28, close: 29 }]],
  ["Swift",
    "let escaped = \"ignore \\\"()\\\"\"\n"
      + "let multiline = \"\"\"\n[]\n\"\"\"\nrun()",
    [{ open: 60, close: 61 }]],
  ["Ruby", "value = \"literal () #{call()}\"\nrun()",
    [{ open: 26, close: 27 }, { open: 34, close: 35 }]],
  ["Shell", "echo \"literal () $name\"\necho `printf []`\nrun()",
    [{ open: 44, close: 45 }]]
]
for (const [language, text, expected] of quotedTokenCases) {
  assert.deepEqual(plain(analyze(text, language).bracketPairs), expected, language)
}
for (const [language, text] of [
  ["EBNF", "rule = \"("], ["TOML", "\"key("]
]) {
  assert.deepEqual(
    plain(analyze(text, language).bracketPairs), [],
    `${language} unterminated quoted token must fail closed`
  )
}
for (const separator of ["\n", "\r\n", "\r"]) {
  const text = `-----BEGIN PGP MESSAGE-----${separator}${separator}X: ()`
  const open = text.lastIndexOf("(")
  assert.deepEqual(plain(analyze(text, "PGP").bracketPairs), [
    { open, close: open + 1 }
  ], `PGP blankLine state with ${JSON.stringify(separator)}`)
}

const legacyCases = [
  ["Ruby", "class Demo\n  def greet(name)\n    puts \"Hi #{name}\" # note\n  end\nend\n",
    ["keyword", "type", "string", "comment"], [0, 2, 4, 2, 0, 0],
    { indentWidth: 2 }, [{ open: 22, close: 27 }]],
  ["Shell", "if true; then\n  echo \"hi\" # note\nfi\n",
    ["keyword", "constant", "string", "comment"], [null, null, null, null],
    {}, []],
  ["TOML", "[server]\nenabled = true\nport = 8080 # note\n",
    ["constant", "number", "comment"], [null, null, null, null],
    {}, [{ open: 0, close: 7 }]],
  ["diff", "@@ -1 +1 @@\n-old\n+new\n context\n", [], [null, null, null, null, null],
    {}, []]
]
for (const [
  language, text, expectedKinds, expectedIndentation, extra = {}, expectedBrackets = []
] of legacyCases) {
  const result = analyze(text, language, extra)
  assertStreamShape(result, text, language, expectedBrackets)
  const kinds = new Set(result.highlights.map(span => span.kind))
  for (const kind of expectedKinds) assert.ok(kinds.has(kind), `${language}: ${kind}`)
  assert.deepEqual(
    Array.from(result.indentation, entry => entry.columns), expectedIndentation,
    `${language} indentation`
  )
}
assert.deepEqual(plain(analyze(legacyCases[3][1], "diff").highlights), [])

for (const [separator, expectedLineFrom] of [
  ["\n", [0, 3, 18]], ["\r\n", [0, 4, 20]], ["\r", [0, 3, 18]]
]) {
  const text = `😀${separator}let x = 1 // c${separator}`
  const result = analyze(text, "Swift")
  assertStreamShape(result, text, "Swift")
  assert.equal(result.sourceUTF16Length, text.length)
  assert.deepEqual(Array.from(result.indentation, entry => entry.lineFrom), expectedLineFrom)
  assert.deepEqual(Array.from(result.indentation, entry => entry.columns), [0, 0, 0])
  const from = text.indexOf("let")
  assert.ok(result.highlights.some(span =>
    span.kind === "keyword" && span.from === from && span.to === from + 3
  ))
}
const mixedLegacyLineEndings = analyze("let a = 1\rlet b = 2\n", "Swift")
assert.equal(mixedLegacyLineEndings.supported, false)
assert.equal(mixedLegacyLineEndings.parserKind, "unsupported")
for (const key of [
  "highlights", "syntaxNodes", "bracketPairs", "folds", "symbols", "indentation"
]) assert.deepEqual(plain(mixedLegacyLineEndings[key]), [])
const symbolCases = [
  ["Java", "class C { void m() {} }", ["C", "m"]],
  ["Go", "type T struct {}\nfunc f() {}", ["T", "f"]],
  ["Rust", "struct S {}\nimpl S { fn m() {} }", ["S", "m"]],
  ["C++", "void f() {}", ["f"]]
]
for (const [language, text, expected] of symbolCases) {
  const labels = analyze(text, language).symbols.map(symbol => symbol.label)
  assert.deepEqual(Array.from(labels), expected, `${language} symbol extraction`)
}
assert.deepEqual(
  Array.from(analyze(
    "# Hello#\n# Hello ###   \nTitle #\n=====\nTitle\u0007X\n-----", "Markdown"
  ).symbols, item => [item.label, item.level]),
  [["Hello#", 0], ["Hello", 0], ["Title #", 0], ["Title X", 1]]
)
process.stdout.write("Native parser bundle smoke tests passed.\n")
