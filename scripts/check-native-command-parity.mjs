import { readFile, readdir } from "node:fs/promises"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import ts from "typescript"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const paths = {
  commands: join(root, "src/renderer/src/commands.ts"),
  ipc: join(root, "src/shared/ipc.ts"),
  menu: join(root, "src/main/menu.ts"),
  main: join(root, "src/renderer/src/main.ts"),
  i18n: join(root, "src/shared/i18n.ts"),
  native: join(root, "native-macos/Sources/LumenEditorCore/CommandCatalog.swift"),
  nativeLocalization: join(root, "native-macos/Sources/LumenEditorCore/Localization.swift"),
  nativeSettings: join(root, "native-macos/Sources/LumenEditorCore/EditorSettings.swift"),
  nativeActions: join(root, "native-macos/Sources/LumenEditorApp/EditorActionController.swift"),
  electronBuilder: join(root, "electron-builder.yml"),
  nativeInfoPlist: join(root, "native-macos/Packaging/Info.plist"),
  electronFiles: join(root, "src/main/files.ts"),
  nativeMenu: join(root, "native-macos/Sources/LumenEditorApp/EditorCommands.swift"),
  matrix: join(root, "docs/NATIVE_MACOS_PARITY.md"),
  tests: join(root, "native-macos/Tests")
}
const expectedCounts = {
  commands: 167,
  menuEventDeclarations: 172,
  menuEventUnique: 171,
  native: 169,
  menuItemDeclarations: 164,
  menuItemUnique: 162,
  runCases: 171,
  matrix: 319,
  sharedLocalizationKeys: 108,
  fileAssociationExtensions: 81,
  defaultMaximumFileSizeMB: 200,
  settingsFormatVersion: 2,
  // Keep this inventory explicit: additions to the native XCTest suite must
  // deliberately update the cross-platform parity baseline instead of being
  // silently invisible on non-macOS runners.
  swiftTestFiles: 105,
  swiftTests: 1718
}
const expectedDomains = new Map([
  ["F", 23], ["T", 11], ["WN", 4], ["SP", 11], ["E", 43],
  ["S", 19], ["Q", 13], ["N", 20], ["V", 30], ["W", 19],
  ["G", 15], ["TM", 4], ["B", 8], ["L", 13], ["P", 10],
  ["M", 4], ["C", 15], ["H", 15], ["I", 5], ["A", 10],
  ["SEC", 13], ["R", 14]
])
const menuOnlyCommands = new Set(["command-palette", "select-build-system"])
const internalMenuEvents = new Set(["encoding-actions", "persist-session"])
const commandsWithoutItemHelper = new Set([
  "convert-indent-spaces", "convert-indent-tabs", "convert-eol-lf",
  "convert-eol-crlf", "convert-eol-cr", "set-ui-language-zh", "set-ui-language-en"
])
// These remain reachable through the command palette/keyboard but are not
// intentionally duplicated in the native menu surface. Standard AppKit roles
// such as cut/copy/paste/undo/redo are also outside the public catalog.
const nativeCommandsWithoutMenuEntry = new Set([
  "convert-eol-lf", "convert-eol-crlf", "convert-eol-cr", "set-ui-language-zh",
  "set-ui-language-en", "select-encoding", "select-line-ending",
  "reopen-with-encoding", "toggle-full-screen"
])
const expectedMenuItemDuplicates = new Map([
  ["duplicate-selection", 2],
  ["open-recent-project", 2]
])
const expectedNativeMenuDuplicates = new Map([
  ["find-in-files", 2],
  ["replace-in-files", 2]
])
const modifierOrder = ["control", "option", "shift", "command"]
const allowedRequirements = new Set([
  "document", "savedDocument", "workspace", "selection", "findResults",
  "navigationHistory", "closedTab", "gitRepository", "languageService"
])

function fail(message) {
  throw new Error("[native-command-parity] " + message)
}

function check(condition, message) {
  if (!condition) fail(message)
}

function exactlyOne(items, label) {
  check(items.length === 1, "expected exactly one " + label + ", found " + items.length)
  return items[0]
}

function countValues(values) {
  const counts = new Map()
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1)
  return counts
}

function duplicateCounts(values) {
  return new Map([...countValues(values)].filter(([, count]) => count > 1))
}

function formatMap(map) {
  return [...map].sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => key + "=" + value).join(", ") || "(none)"
}

function assertMapEqual(actual, expected, label) {
  const actualEntries = [...actual].sort(([left], [right]) => left.localeCompare(right))
  const expectedEntries = [...expected].sort(([left], [right]) => left.localeCompare(right))
  const same = actualEntries.length === expectedEntries.length
    && actualEntries.every(([key, value], index) => {
      const expectedEntry = expectedEntries[index]
      return expectedEntry?.[0] === key && expectedEntry[1] === value
    })
  check(same, label + ": expected " + formatMap(expected) + ", found " + formatMap(actual))
}

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter(value => !actual.has(value)).sort()
  const extra = [...actual].filter(value => !expected.has(value)).sort()
  check(
    missing.length === 0 && extra.length === 0,
    label + ": missing [" + missing.join(", ") + "], extra [" + extra.join(", ") + "]"
  )
}

function parseTypeScript(path, source) {
  const sourceFile = ts.createSourceFile(
    path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS
  )
  if (sourceFile.parseDiagnostics.length > 0) {
    const diagnostics = sourceFile.parseDiagnostics.map(diagnostic => {
      const position = diagnostic.start === undefined
        ? ""
        : ":" + (sourceFile.getLineAndCharacterOfPosition(diagnostic.start).line + 1)
      return relative(root, path) + position + ": "
        + ts.flattenDiagnosticMessageText(diagnostic.messageText, " ")
    })
    fail("TypeScript parse failed:\n" + diagnostics.join("\n"))
  }
  return sourceFile
}

function isExported(node) {
  return node.modifiers?.some(modifier => modifier.kind === ts.SyntaxKind.ExportKeyword) ?? false
}

function stringLiteral(node, label) {
  check(ts.isStringLiteral(node), label + " must be a plain string literal")
  check(node.text.length > 0, label + " must not be empty")
  return node.text
}

function parseCommands(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const matches = []
  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) continue
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.name.text === "COMMANDS") {
        matches.push({ statement, declaration })
      }
    }
  }
  const { statement, declaration } = exactlyOne(matches, "top-level COMMANDS declaration")
  check(isExported(statement), "COMMANDS must remain exported")
  check(
    (statement.declarationList.flags & ts.NodeFlags.Const) !== 0,
    "COMMANDS must remain a const declaration"
  )
  check(
    declaration.type && ts.isArrayTypeNode(declaration.type)
      && ts.isTypeReferenceNode(declaration.type.elementType)
      && ts.isIdentifier(declaration.type.elementType.typeName)
      && declaration.type.elementType.typeName.text === "Command",
    "COMMANDS must retain the explicit Command[] type"
  )
  check(
    declaration.initializer && ts.isArrayLiteralExpression(declaration.initializer),
    "COMMANDS must be initialized by an explicit array literal"
  )

  const ids = declaration.initializer.elements.map((element, index) => {
    const label = "COMMANDS entry " + (index + 1)
    check(ts.isObjectLiteralExpression(element), label + " must be an object literal")
    const properties = new Map()
    for (const property of element.properties) {
      check(ts.isPropertyAssignment(property), label + " may only contain property assignments")
      check(ts.isIdentifier(property.name), label + " property names must be identifiers")
      const name = property.name.text
      check(["id", "title", "hint"].includes(name), label + " has unexpected property " + name)
      check(!properties.has(name), label + " repeats property " + name)
      properties.set(name, stringLiteral(property.initializer, label + "." + name))
    }
    check(properties.has("id") && properties.has("title"), label + " must contain id and title")
    const id = properties.get("id")
    check(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id), label + " has invalid id " + id)
    return id
  })
  check(
    ids.length === expectedCounts.commands,
    "COMMANDS declaration count must be " + expectedCounts.commands + ", found " + ids.length
  )
  const duplicates = duplicateCounts(ids)
  check(duplicates.size === 0, "COMMANDS IDs must be unique; duplicates: " + formatMap(duplicates))
  return ids
}

function parseMenuEvents(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const declaration = exactlyOne(
    sourceFile.statements.filter(statement =>
      ts.isTypeAliasDeclaration(statement) && statement.name.text === "MenuEvent"),
    "top-level MenuEvent type alias"
  )
  check(isExported(declaration), "MenuEvent must remain exported")
  check(declaration.typeParameters === undefined, "MenuEvent must not have type parameters")
  check(ts.isUnionTypeNode(declaration.type), "MenuEvent must remain an explicit union")
  const ids = declaration.type.types.map((member, index) => {
    check(
      ts.isLiteralTypeNode(member) && ts.isStringLiteral(member.literal),
      "MenuEvent member " + (index + 1) + " must be a string literal"
    )
    const id = member.literal.text
    check(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id), "MenuEvent has invalid ID " + id)
    return id
  })
  check(
    ids.length === expectedCounts.menuEventDeclarations,
    "MenuEvent must have " + expectedCounts.menuEventDeclarations
      + " declarations, found " + ids.length
  )
  check(
    new Set(ids).size === expectedCounts.menuEventUnique,
    "MenuEvent must have " + expectedCounts.menuEventUnique
      + " unique IDs, found " + new Set(ids).size
  )
  assertMapEqual(
    duplicateCounts(ids), new Map([["import-sublime-build", 2]]),
    "MenuEvent duplicate declarations"
  )
  return ids
}

function unwrapTypeScriptExpression(expression) {
  let current = expression
  while (ts.isAsExpression(current)
    || ts.isTypeAssertionExpression(current)
    || ts.isParenthesizedExpression(current)
    || ts.isSatisfiesExpression(current)) {
    current = current.expression
  }
  return current
}

function topLevelTypeScriptVariables(sourceFile) {
  const variables = new Map()
  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) continue
    for (const declaration of statement.declarationList.declarations) {
      if (!ts.isIdentifier(declaration.name) || !declaration.initializer) continue
      check(!variables.has(declaration.name.text),
        "duplicate top-level TypeScript variable " + declaration.name.text)
      variables.set(declaration.name.text, declaration.initializer)
    }
  }
  return variables
}

function parseTypeScriptTranslationCatalog(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const variables = topLevelTypeScriptVariables(sourceFile)
  const appName = variables.get("APP_NAME")
  check(appName && ts.isStringLiteral(appName), "i18n APP_NAME must be a string literal")

  function parseCatalog(name) {
    const initializer = variables.get(name)
    check(initializer, "i18n catalog " + name + " is missing")
    const object = unwrapTypeScriptExpression(initializer)
    check(ts.isObjectLiteralExpression(object),
      "i18n catalog " + name + " must be an object literal")
    const values = new Map()
    for (const property of object.properties) {
      check(ts.isPropertyAssignment(property),
        "i18n catalog " + name + " may only use property assignments")
      check(ts.isIdentifier(property.name),
        "i18n catalog " + name + " keys must be identifiers")
      const key = property.name.text
      check(!values.has(key), "i18n catalog " + name + " repeats key " + key)
      const value = unwrapTypeScriptExpression(property.initializer)
      if (ts.isStringLiteral(value)) {
        values.set(key, value.text)
      } else if (ts.isIdentifier(value) && value.text === "APP_NAME") {
        values.set(key, appName.text)
      } else {
        fail("i18n catalog " + name + " value for " + key
          + " must be a string literal or APP_NAME")
      }
    }
    return values
  }

  const zhCN = parseCatalog("ZH")
  const enUS = parseCatalog("EN")
  check(
    zhCN.size === expectedCounts.sharedLocalizationKeys,
    "i18n ZH must contain " + expectedCounts.sharedLocalizationKeys
      + " keys, found " + zhCN.size
  )
  assertSetEqual(new Set(enUS.keys()), new Set(zhCN.keys()),
    "i18n English and Chinese catalog keys")
  return { zhCN, enUS }
}

function parseAppRunCases(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const appClass = exactlyOne(
    sourceFile.statements.filter(statement =>
      ts.isClassDeclaration(statement) && statement.name?.text === "App"),
    "top-level App class"
  )
  const runMethod = exactlyOne(
    appClass.members.filter(member =>
      ts.isMethodDeclaration(member)
        && ts.isIdentifier(member.name) && member.name.text === "run"),
    "App.run method"
  )
  check(runMethod.body, "App.run must have a method body")
  check(runMethod.parameters.length === 1, "App.run must have exactly one parameter")
  const parameter = runMethod.parameters[0]
  check(
    ts.isIdentifier(parameter.name) && parameter.name.text === "event",
    "App.run parameter must be named event"
  )
  check(
    parameter.type && ts.isTypeReferenceNode(parameter.type)
      && ts.isIdentifier(parameter.type.typeName) && parameter.type.typeName.text === "MenuEvent",
    "App.run event parameter must retain the MenuEvent type"
  )
  check(
    runMethod.type && runMethod.type.kind === ts.SyntaxKind.VoidKeyword,
    "App.run must retain its explicit void return type"
  )

  const switches = runMethod.body.statements.filter(statement => ts.isSwitchStatement(statement))
  const switchStatement = exactlyOne(switches, "direct App.run switch statement")
  check(
    ts.isIdentifier(switchStatement.expression) && switchStatement.expression.text === "event",
    "App.run switch must dispatch directly on event"
  )
  const caseIDs = switchStatement.caseBlock.clauses.map((clause, index) => {
    check(ts.isCaseClause(clause), "App.run switch must not contain a default clause")
    const id = stringLiteral(clause.expression, "App.run case label " + (index + 1))
    check(
      clause.statements.length > 0,
      "App.run case " + id + " must contain an executable statement"
    )
    const finalStatement = clause.statements.at(-1)
    check(
      ts.isBreakStatement(finalStatement)
        || ts.isReturnStatement(finalStatement)
        || ts.isThrowStatement(finalStatement),
      "App.run case " + id + " must terminate explicitly"
    )
    return id
  })
  check(
    caseIDs.length === expectedCounts.runCases,
    "App.run must have " + expectedCounts.runCases + " case labels, found " + caseIDs.length
  )
  const duplicates = duplicateCounts(caseIDs)
  check(duplicates.size === 0, "App.run case labels must be unique; duplicates: " + formatMap(duplicates))
  return caseIDs
}

function walk(node, visit) {
  visit(node)
  node.forEachChild(child => walk(child, visit))
}

function parseMacAcceleratorExpression(node, label) {
  if (ts.isStringLiteral(node)) return node.text
  check(
    ts.isConditionalExpression(node),
    label + " must be a string literal or the explicit isMac conditional"
  )
  check(
    ts.isIdentifier(node.condition) && node.condition.text === "isMac",
    label + " conditional must test isMac directly"
  )
  stringLiteral(node.whenFalse, label + " non-mac branch")
  return stringLiteral(node.whenTrue, label + " macOS branch")
}

function parseMenuItems(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const itemHelper = exactlyOne(
    sourceFile.statements.filter(statement =>
      ts.isFunctionDeclaration(statement) && statement.name?.text === "item"),
    "top-level item helper"
  )
  const parameterNames = itemHelper.parameters.map(parameter =>
    ts.isIdentifier(parameter.name) ? parameter.name.text : "(non-identifier)"
  )
  check(
    parameterNames.join(",") === "label,event,accelerator",
    "item helper parameters must remain label, event, accelerator"
  )
  check(
    itemHelper.parameters[2].questionToken !== undefined,
    "item helper accelerator must remain optional"
  )
  const buildMenu = exactlyOne(
    sourceFile.statements.filter(statement =>
      ts.isFunctionDeclaration(statement) && statement.name?.text === "buildMenu"),
    "top-level buildMenu function"
  )
  check(isExported(buildMenu), "buildMenu must remain exported")
  check(buildMenu.body, "buildMenu must have a body")
  const templateMatches = []
  for (const statement of buildMenu.body.statements) {
    if (!ts.isVariableStatement(statement)) continue
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.name.text === "template") {
        templateMatches.push({ statement, declaration })
      }
    }
  }
  const { statement, declaration } = exactlyOne(
    templateMatches, "buildMenu template declaration"
  )
  check(
    (statement.declarationList.flags & ts.NodeFlags.Const) !== 0,
    "buildMenu template must remain const"
  )
  check(
    declaration.initializer && ts.isArrayLiteralExpression(declaration.initializer),
    "buildMenu template must be an explicit array literal"
  )

  const templateCalls = []
  walk(declaration.initializer, node => {
    if (ts.isCallExpression(node)
        && ts.isIdentifier(node.expression) && node.expression.text === "item") {
      templateCalls.push(node)
    }
  })
  const allItemCalls = []
  walk(sourceFile, node => {
    if (ts.isCallExpression(node)
        && ts.isIdentifier(node.expression) && node.expression.text === "item") {
      allItemCalls.push(node)
    }
  })
  check(
    allItemCalls.length === templateCalls.length
      && allItemCalls.every((call, index) => call === templateCalls[index]),
    "all item calls must remain inside the explicit buildMenu template block"
  )

  const items = templateCalls.map((call, index) => {
    const label = "menu item call " + (index + 1)
    check(
      call.arguments.length === 2 || call.arguments.length === 3,
      label + " must have label, event, and optional accelerator arguments"
    )
    const title = stringLiteral(call.arguments[0], label + " label")
    const id = stringLiteral(call.arguments[1], label + " event")
    check(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id), label + " has invalid event " + id)
    const accelerator = call.arguments.length === 3
      ? parseMacAcceleratorExpression(call.arguments[2], label + " accelerator")
      : null
    return { id, title, accelerator }
  })
  check(
    items.length === expectedCounts.menuItemDeclarations,
    "menu item call count must be " + expectedCounts.menuItemDeclarations
      + ", found " + items.length
  )
  check(
    new Set(items.map(item => item.id)).size === expectedCounts.menuItemUnique,
    "menu item unique ID count must be " + expectedCounts.menuItemUnique
      + ", found " + new Set(items.map(item => item.id)).size
  )
  assertMapEqual(
    duplicateCounts(items.map(item => item.id)), expectedMenuItemDuplicates,
    "duplicate menu item IDs"
  )
  return items
}

function uniqueIndexOf(source, needle, label) {
  const first = source.indexOf(needle)
  check(first !== -1, "could not find " + label)
  check(
    source.indexOf(needle, first + needle.length) === -1,
    "found multiple " + label + " anchors"
  )
  return first
}

function matchingDelimiter(source, openIndex, open, close, label) {
  check(source[openIndex] === open, label + " does not start with " + open)
  let depth = 0
  let blockCommentDepth = 0
  let state = "code"
  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index]
    const next = source[index + 1]
    if (state === "string") {
      if (character === "\\") index += 1
      else if (character === "\"") state = "code"
      continue
    }
    if (state === "line-comment") {
      if (character === "\n") state = "code"
      continue
    }
    if (state === "block-comment") {
      if (character === "/" && next === "*") {
        blockCommentDepth += 1
        index += 1
      } else if (character === "*" && next === "/") {
        blockCommentDepth -= 1
        index += 1
        if (blockCommentDepth === 0) state = "code"
      }
      continue
    }
    if (character === "\"") {
      check(
        source.slice(index, index + 3) !== "\"\"\"",
        label + " contains an unsupported multiline Swift string"
      )
      state = "string"
    } else if (character === "/" && next === "/") {
      state = "line-comment"
      index += 1
    } else if (character === "/" && next === "*") {
      state = "block-comment"
      blockCommentDepth = 1
      index += 1
    } else if (character === open) {
      depth += 1
    } else if (character === close) {
      depth -= 1
      if (depth === 0) return index
      check(depth >= 0, label + " has an unexpected " + close)
    }
  }
  fail(label + " has no matching " + close)
}

function skipSwiftTrivia(source, start) {
  let index = start
  while (index < source.length) {
    if (/\s/.test(source[index])) {
      index += 1
      continue
    }
    if (source.startsWith("//", index)) {
      const newline = source.indexOf("\n", index + 2)
      index = newline === -1 ? source.length : newline + 1
      continue
    }
    if (source.startsWith("/*", index)) {
      let depth = 1
      index += 2
      while (index < source.length && depth > 0) {
        if (source.startsWith("/*", index)) {
          depth += 1
          index += 2
        } else if (source.startsWith("*/", index)) {
          depth -= 1
          index += 2
        } else {
          index += 1
        }
      }
      check(depth === 0, "unterminated Swift block comment in CommandCatalog.all")
      continue
    }
    break
  }
  return index
}

function splitSwiftArguments(source, label) {
  const segments = []
  let start = 0
  let state = "code"
  let blockCommentDepth = 0
  const depth = { "(": 0, "[": 0, "{": 0 }
  const closing = { ")": "(", "]": "[", "}": "{" }
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    const next = source[index + 1]
    if (state === "string") {
      if (character === "\\") index += 1
      else if (character === "\"") state = "code"
      continue
    }
    if (state === "line-comment") {
      if (character === "\n") state = "code"
      continue
    }
    if (state === "block-comment") {
      if (character === "/" && next === "*") {
        blockCommentDepth += 1
        index += 1
      } else if (character === "*" && next === "/") {
        blockCommentDepth -= 1
        index += 1
        if (blockCommentDepth === 0) state = "code"
      }
      continue
    }
    if (character === "\"") state = "string"
    else if (character === "/" && next === "/") {
      state = "line-comment"
      index += 1
    } else if (character === "/" && next === "*") {
      state = "block-comment"
      blockCommentDepth = 1
      index += 1
    } else if (Object.hasOwn(depth, character)) {
      depth[character] += 1
    } else if (Object.hasOwn(closing, character)) {
      const opener = closing[character]
      depth[opener] -= 1
      check(depth[opener] >= 0, label + " has an unexpected " + character)
    } else if (character === "," && Object.values(depth).every(value => value === 0)) {
      segments.push(source.slice(start, index).trim())
      start = index + 1
    }
  }
  check(
    state === "code" && Object.values(depth).every(value => value === 0),
    label + " has unbalanced syntax"
  )
  segments.push(source.slice(start).trim())
  check(segments.every(Boolean), label + " contains an empty argument")
  return segments
}

function swiftString(source, label) {
  check(
    /^"(?:[^"\\]|\\["\\/bfnrt])*"$/u.test(source),
    label + " must be a plain Swift string literal"
  )
  try {
    return JSON.parse(source)
  } catch {
    fail(label + " is not a supported Swift string literal")
  }
}

function parseSwiftOptionSet(source, allowed, label) {
  const members = source.startsWith("[") && source.endsWith("]")
    ? source.slice(1, -1).split(",").map(value => value.trim())
    : [source]
  check(members.length > 0 && members.every(Boolean), label + " must not be empty")
  const values = members.map(member => {
    const match = /^\.([A-Za-z][A-Za-z0-9]*)$/.exec(member)
    check(match, label + " contains unsupported expression " + member)
    check(allowed.has(match[1]), label + " contains unknown value " + match[1])
    return match[1]
  })
  check(new Set(values).size === values.length, label + " contains duplicate values")
  return values
}

function normalizeKey(key, label) {
  const normalized = key.toLowerCase() === "enter" ? "return" : key.toLowerCase()
  const named = new Set([
    "up", "down", "left", "right", "backspace", "delete", "return", "space"
  ])
  check(
    named.has(normalized) || /^f(?:[1-9]|1[0-9]|2[0-4])$/.test(normalized)
      || [...normalized].length === 1,
    label + " has unsupported key " + key
  )
  return normalized
}

function canonicalShortcut(key, modifiers, label) {
  const uniqueModifiers = new Set(modifiers)
  check(uniqueModifiers.size === modifiers.length, label + " repeats a modifier")
  const ordered = modifierOrder.filter(modifier => uniqueModifiers.has(modifier))
  check(ordered.length === uniqueModifiers.size, label + " has an unknown modifier")
  return [...ordered, normalizeKey(key, label)].join("+")
}

function normalizeElectronAccelerator(accelerator, label) {
  const tokens = accelerator.split("+")
  check(tokens.length > 0 && tokens.every(Boolean), label + " is malformed: " + accelerator)
  const modifiers = []
  const keys = []
  for (const token of tokens) {
    const lower = token.toLowerCase()
    if (["cmdorctrl", "commandorcontrol", "cmd", "command"].includes(lower)) {
      modifiers.push("command")
    } else if (["ctrl", "control"].includes(lower)) {
      modifiers.push("control")
    } else if (["alt", "option"].includes(lower)) {
      modifiers.push("option")
    } else if (lower === "shift") {
      modifiers.push("shift")
    } else {
      keys.push(token)
    }
  }
  check(keys.length === 1, label + " must contain exactly one key: " + accelerator)
  return canonicalShortcut(keys[0], modifiers, label)
}

function parseSwiftCommand(argumentsSource, index) {
  const label = "CommandCatalog.all entry " + (index + 1)
  const arguments_ = splitSwiftArguments(argumentsSource, label)
  check(arguments_.length >= 4, label + " must have four positional arguments")
  const id = swiftString(arguments_[0], label + " ID")
  check(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id), label + " has invalid ID " + id)
  check(
    /^\.[A-Za-z][A-Za-z0-9]*$/.test(arguments_[1]),
    label + " category must be an enum case"
  )
  swiftString(arguments_[2], label + " English name")
  swiftString(arguments_[3], label + " Chinese name")

  const options = new Map()
  for (const argument of arguments_.slice(4)) {
    const match = /^([A-Za-z][A-Za-z0-9]*):\s*([\s\S]+)$/.exec(argument)
    check(match, label + " optional arguments must be named: " + argument)
    const [, name, value] = match
    check(
      ["shortcut", "key", "modifiers", "requires"].includes(name),
      label + " has unsupported argument " + name
    )
    check(!options.has(name), label + " repeats argument " + name)
    options.set(name, value)
  }
  if (options.has("shortcut")) swiftString(options.get("shortcut"), label + " shortcut")
  if (options.has("requires")) {
    parseSwiftOptionSet(options.get("requires"), allowedRequirements, label + " requirements")
  }
  check(
    options.has("key") || !options.has("modifiers"),
    label + " cannot declare executable modifiers without a key"
  )

  let shortcut = null
  if (options.has("key")) {
    const key = swiftString(options.get("key"), label + " key")
    const modifiers = options.has("modifiers")
      ? parseSwiftOptionSet(options.get("modifiers"), new Set(modifierOrder), label + " modifiers")
      : []
    shortcut = canonicalShortcut(key, modifiers, label + " key equivalent")
  }
  return { id, shortcut }
}

function verifySwiftCommandHelper(commandCatalogSource) {
  const anchor = "    private static func command("
  const start = uniqueIndexOf(commandCatalogSource, anchor, "CommandCatalog.command helper")
  const parametersOpen = start + anchor.length - 1
  const parametersClose = matchingDelimiter(
    commandCatalogSource, parametersOpen, "(", ")", "CommandCatalog.command parameters"
  )
  const bodyOpen = commandCatalogSource.indexOf("{", parametersClose + 1)
  check(bodyOpen !== -1, "CommandCatalog.command helper has no body")
  const bodyClose = matchingDelimiter(
    commandCatalogSource, bodyOpen, "{", "}", "CommandCatalog.command body"
  )
  const signature = commandCatalogSource.slice(parametersOpen + 1, parametersClose)
  const body = commandCatalogSource.slice(bodyOpen + 1, bodyClose)
  check(
    /key:\s*String\?\s*=\s*nil\s*,/.test(signature),
    "CommandCatalog.command key parameter must default to nil"
  )
  check(
    /modifiers:\s*CommandKeyModifiers\s*=\s*\[\]\s*,/.test(signature),
    "CommandCatalog.command modifiers parameter must default to []"
  )
  check(
    /let\s+keyEquivalent\s*=\s*key\.map\s*\{\s*CommandKeyEquivalent\(key:\s*\$0,\s*modifiers:\s*modifiers\)\s*\}/.test(body),
    "CommandCatalog.command must derive its executable key equivalent from key and modifiers"
  )
  check(
    /defaultKeyEquivalent:\s*keyEquivalent/.test(body),
    "CommandCatalog.command must pass the derived key equivalent to the descriptor"
  )
}

function parseNativeCatalog(source) {
  const enumAnchor = "public enum CommandCatalog {"
  const enumStart = uniqueIndexOf(source, enumAnchor, "CommandCatalog enum")
  const enumOpen = enumStart + enumAnchor.length - 1
  const enumClose = matchingDelimiter(source, enumOpen, "{", "}", "CommandCatalog enum")
  const enumSource = source.slice(enumOpen + 1, enumClose)
  const allAnchor = "    public static let all: [CommandDescriptor] = ["
  const allStart = uniqueIndexOf(enumSource, allAnchor, "CommandCatalog.all declaration")
  const allOpen = allStart + allAnchor.length - 1
  const allClose = matchingDelimiter(
    enumSource, allOpen, "[", "]", "CommandCatalog.all array"
  )
  const arraySource = enumSource.slice(allOpen + 1, allClose)
  const commands = []
  let offset = skipSwiftTrivia(arraySource, 0)
  while (offset < arraySource.length) {
    check(
      arraySource.startsWith("command", offset)
        && !/[A-Za-z0-9_]/.test(arraySource[offset + "command".length] ?? ""),
      "CommandCatalog.all contains a non-command entry near "
        + JSON.stringify(arraySource.slice(offset, offset + 40))
    )
    offset += "command".length
    offset = skipSwiftTrivia(arraySource, offset)
    check(arraySource[offset] === "(", "CommandCatalog.all command entry must use parentheses")
    const close = matchingDelimiter(
      arraySource, offset, "(", ")", "CommandCatalog.all entry " + (commands.length + 1)
    )
    commands.push(parseSwiftCommand(arraySource.slice(offset + 1, close), commands.length))
    offset = skipSwiftTrivia(arraySource, close + 1)
    if (offset === arraySource.length) break
    check(
      arraySource[offset] === ",",
      "CommandCatalog.all entries must be comma-separated near entry " + commands.length
    )
    offset = skipSwiftTrivia(arraySource, offset + 1)
  }
  check(
    commands.length === expectedCounts.native,
    "CommandCatalog.all must have " + expectedCounts.native + " entries, found " + commands.length
  )
  const duplicates = duplicateCounts(commands.map(command => command.id))
  check(
    duplicates.size === 0,
    "CommandCatalog.all IDs must be unique; duplicates: " + formatMap(duplicates)
  )
  verifySwiftCommandHelper(enumSource)
  return commands
}

function parseSwiftLocalizationCatalog(source) {
  const enumAnchor = "public enum Localization {"
  const enumStart = uniqueIndexOf(source, enumAnchor, "Localization enum")
  const enumOpen = enumStart + enumAnchor.length - 1
  const enumClose = matchingDelimiter(source, enumOpen, "{", "}", "Localization enum")
  const enumSource = source.slice(enumOpen + 1, enumClose)
  const valuesAnchor = "    private static func values(for key: Key) -> (zhCN: String, enUS: String) {"
  const valuesStart = uniqueIndexOf(enumSource, valuesAnchor, "Localization.values helper")
  const valuesOpen = valuesStart + valuesAnchor.length - 1
  const valuesClose = matchingDelimiter(
    enumSource, valuesOpen, "{", "}", "Localization.values helper"
  )
  const body = enumSource.slice(valuesOpen + 1, valuesClose)
  const codeMask = swiftCodeMask(body, "Localization.values helper")
  const casePattern = /case\s+\.([A-Za-z][A-Za-z0-9]*):\s*return\s*\(([^\n]+)\)/g
  const zhCN = new Map()
  const enUS = new Map()
  for (const match of body.matchAll(casePattern)) {
    if (!codeMask[match.index]) continue
    const [, key, argumentsSource] = match
    check(!zhCN.has(key), "Localization.values repeats key " + key)
    const values = splitSwiftArguments(argumentsSource, "Localization.values." + key)
    check(values.length === 2, "Localization.values." + key + " must return two strings")
    zhCN.set(key, swiftString(values[0], "Localization.values." + key + " Chinese value"))
    enUS.set(key, swiftString(values[1], "Localization.values." + key + " English value"))
  }
  check(
    zhCN.size === expectedCounts.sharedLocalizationKeys,
    "Localization.values must contain " + expectedCounts.sharedLocalizationKeys
      + " keys, found " + zhCN.size
  )
  assertSetEqual(new Set(enUS.keys()), new Set(zhCN.keys()),
    "Swift Localization English and Chinese catalog keys")
  return { zhCN, enUS }
}

function verifySharedLocalizationParity(typeScriptCatalog, swiftCatalog) {
  assertSetEqual(
    new Set(swiftCatalog.zhCN.keys()), new Set(typeScriptCatalog.zhCN.keys()),
    "Swift Localization keys must equal src/shared/i18n.ts"
  )
  for (const [locale, typeScriptValues, swiftValues] of [
    ["zh-CN", typeScriptCatalog.zhCN, swiftCatalog.zhCN],
    ["en-US", typeScriptCatalog.enUS, swiftCatalog.enUS]
  ]) {
    const mismatches = []
    for (const [key, expected] of typeScriptValues) {
      const actual = swiftValues.get(key)
      if (actual !== expected) {
        mismatches.push(key + ": TypeScript=" + JSON.stringify(expected)
          + ", Swift=" + JSON.stringify(actual))
      }
    }
    check(
      mismatches.length === 0,
      "shared " + locale + " localization values differ between TypeScript and Swift:\n"
        + mismatches.join("\n")
    )
  }
}

function parseElectronFileAssociationExtensions(source) {
  const start = uniqueIndexOf(source, "fileAssociations:\n", "electron fileAssociations")
  const end = source.indexOf("\nwin:", start)
  check(end !== -1, "electron fileAssociations must precede win config")
  const values = []
  for (const match of source.slice(start, end).matchAll(
    /^\s*-\s*\{\s*ext:\s*([A-Za-z0-9.+-]+),\s*name:\s*[^,]+,\s*role:\s*Editor\s*\}\s*$/gm
  )) values.push(match[1])
  check(values.length === expectedCounts.fileAssociationExtensions,
    "electron file association count must be " + expectedCounts.fileAssociationExtensions
      + ", found " + values.length)
  check(new Set(values).size === values.length,
    "electron file associations must not repeat extensions")
  return new Set(values)
}

function parseNativeFileAssociationExtensions(source) {
  const anchor = "<key>CFBundleTypeExtensions</key>"
  const start = uniqueIndexOf(source, anchor, "native CFBundleTypeExtensions")
  const arrayStart = source.indexOf("<array>", start + anchor.length)
  check(arrayStart !== -1, "native CFBundleTypeExtensions has no array")
  const arrayEnd = source.indexOf("</array>", arrayStart)
  check(arrayEnd !== -1, "native CFBundleTypeExtensions has no closing array")
  const values = [...source.slice(arrayStart, arrayEnd).matchAll(
    /<string>([^<]+)<\/string>/g
  )].map(match => match[1])
  check(values.length === expectedCounts.fileAssociationExtensions,
    "native file association count must be " + expectedCounts.fileAssociationExtensions
      + ", found " + values.length)
  check(new Set(values).size === values.length,
    "native file associations must not repeat extensions")
  return new Set(values)
}

function verifyFileAssociationParity(electronBuilderSource, nativeInfoPlistSource) {
  assertSetEqual(
    parseElectronFileAssociationExtensions(electronBuilderSource),
    parseNativeFileAssociationExtensions(nativeInfoPlistSource),
    "Electron and native file association extensions"
  )
}

function parseTypeScriptFileSizeSettings(path, source) {
  const sourceFile = parseTypeScript(path, source)
  const variables = topLevelTypeScriptVariables(sourceFile)
  const initializer = variables.get("DEFAULT_SETTINGS")
  check(initializer, "DEFAULT_SETTINGS declaration is missing")
  const object = unwrapTypeScriptExpression(initializer)
  check(ts.isObjectLiteralExpression(object), "DEFAULT_SETTINGS must be an object literal")
  const property = object.properties.find(candidate =>
    ts.isPropertyAssignment(candidate)
      && ts.isIdentifier(candidate.name)
      && candidate.name.text === "maxFileSizeMB"
  )
  check(property && ts.isPropertyAssignment(property),
    "DEFAULT_SETTINGS.maxFileSizeMB is missing")
  const value = unwrapTypeScriptExpression(property.initializer)
  check(ts.isNumericLiteral(value),
    "DEFAULT_SETTINGS.maxFileSizeMB must be a numeric literal")
  const versionProperty = object.properties.find(candidate =>
    ts.isPropertyAssignment(candidate)
      && ts.isIdentifier(candidate.name)
      && candidate.name.text === "formatVersion"
  )
  check(versionProperty && ts.isPropertyAssignment(versionProperty),
    "DEFAULT_SETTINGS.formatVersion is missing")
  const version = unwrapTypeScriptExpression(versionProperty.initializer)
  check(ts.isNumericLiteral(version),
    "DEFAULT_SETTINGS.formatVersion must be a numeric literal")
  return { maximumFileSizeMB: Number(value.text), formatVersion: Number(version.text) }
}

function parseSwiftFileSizeSettings(source) {
  const match = /public\s+static\s+let\s+defaultMaximumFileSizeMB\s*=\s*(\d+)/.exec(source)
  check(match, "EditorSettings.defaultMaximumFileSizeMB is missing")
  const version = /public\s+static\s+let\s+currentFormatVersion\s*=\s*(\d+)/.exec(source)
  check(version, "EditorSettings.currentFormatVersion is missing")
  return { maximumFileSizeMB: Number(match[1]), formatVersion: Number(version[1]) }
}

function verifyDefaultMaximumFileSizeParity(typeScriptSource, swiftSource) {
  const electron = parseTypeScriptFileSizeSettings(paths.ipc, typeScriptSource)
  const native = parseSwiftFileSizeSettings(swiftSource)
  check(
    electron.maximumFileSizeMB === expectedCounts.defaultMaximumFileSizeMB
      && native.maximumFileSizeMB === expectedCounts.defaultMaximumFileSizeMB
      && electron.formatVersion === expectedCounts.settingsFormatVersion
      && native.formatVersion === expectedCounts.settingsFormatVersion,
    "Electron and native default file-size limits must both be "
      + expectedCounts.defaultMaximumFileSizeMB + " MB; found Electron="
      + electron.maximumFileSizeMB + ", native=" + native.maximumFileSizeMB
      + ". Both settings formats must be v" + expectedCounts.settingsFormatVersion
      + "; found Electron=v" + electron.formatVersion + ", native=v" + native.formatVersion
  )
}

function verifyMultiFileOpenFlow(filesSource, rendererSource, nativeActionsSource) {
  const handlerAnchor = "ipcMain.handle(IPC.fileOpen,"
  const start = uniqueIndexOf(filesSource, handlerAnchor, "Electron file-open handler")
  const end = filesSource.indexOf("ipcMain.handle(IPC.fileOpenPath", start)
  check(end !== -1, "Electron file-open handler must precede file-open-path handler")
  const handler = filesSource.slice(start, end)
  check(
    handler.includes("properties: ['openFile', 'multiSelections']"),
    "Electron file-open dialog must allow multiSelections"
  )
  check(
    handler.includes("planFileOpenBatch(") && handler.includes("batch.accepted"),
    "Electron file-open handler must use the bounded batch plan"
  )
  check(
    handler.includes("files: [], failures: []")
      && handler.includes("const failures: OpenFilesResult['failures']"),
    "Electron file-open handler must return an explicit batch result"
  )
  const rendererStart = uniqueIndexOf(
    rendererSource, "private async openViaDialog", "renderer openViaDialog"
  )
  const rendererEnd = rendererSource.indexOf("private pickOpenEncoding", rendererStart)
  check(rendererEnd !== -1, "renderer openViaDialog must precede encoding picker")
  const renderer = rendererSource.slice(rendererStart, rendererEnd)
  check(
    renderer.includes("for (const file of result.files)")
      && renderer.includes("result.failures.length"),
    "renderer openViaDialog must load every success and report per-file failures"
  )
  const nativeAnchor = "static let documentOpen = EditorOpenPanelConfiguration("
  const nativeStart = uniqueIndexOf(
    nativeActionsSource, nativeAnchor, "native document open panel configuration"
  )
  const nativeOpen = nativeStart + nativeAnchor.length - 1
  const nativeClose = matchingDelimiter(
    nativeActionsSource, nativeOpen, "(", ")", "native document open panel configuration"
  )
  const nativePanel = nativeActionsSource.slice(nativeOpen + 1, nativeClose)
  check(
    /canChooseFiles:\s*true/.test(nativePanel)
      && /canChooseDirectories:\s*false/.test(nativePanel)
      && /allowsMultipleSelection:\s*true/.test(nativePanel)
      && /resolvesAliases:\s*true/.test(nativePanel),
    "native document open panel must allow multiple file selections"
  )
}

function parseNativeMenu(source) {
  const bodyAnchor = "    var body: some Commands {"
  const bodyStart = uniqueIndexOf(source, bodyAnchor, "EditorCommands body")
  const bodyOpen = bodyStart + bodyAnchor.length - 1
  const bodyClose = matchingDelimiter(
    source, bodyOpen, "{", "}", "EditorCommands body"
  )
  const body = source.slice(bodyOpen + 1, bodyClose)
  const codeMask = swiftCodeMask(body, "EditorCommands body")
  const ids = []
  for (const call of swiftCalls(
    body, codeMask,
    new Set(["routedButton", "layoutButton", "routedToggleBinding"]),
    "EditorCommands body"
  )) {
    const argumentMask = swiftCodeMask(
      call.argumentsSource, "EditorCommands " + call.name + " arguments"
    )
    const commandMatches = [...call.argumentsSource.matchAll(
      /\bcommandID\s*:\s*"([a-z0-9]+(?:-[a-z0-9]+)*)"/g
    )].filter(match => argumentMask[match.index])
    check(
      commandMatches.length === 1,
      "EditorCommands " + call.name + " must use exactly one literal commandID"
    )
    ids.push(commandMatches[0][1])
  }
  const newWindowCalls = swiftCalls(
    body, codeMask, new Set(["Button"]), "EditorCommands body"
  ).filter(call => {
    const buttonArguments = splitSwiftArguments(
      call.argumentsSource, "EditorCommands New Window Button"
    )
    return buttonArguments.length === 2
      && /^text\(\s*"New Window"\s*,\s*zh:\s*"新建窗口"\s*\)$/.test(buttonArguments[0])
      && /^action\s*:\s*newWindow$/.test(buttonArguments[1])
  })
  check(
    newWindowCalls.length === 1,
    "EditorCommands must retain exactly one direct New Window menu action"
  )
  ids.push("new-window")

  const literalArrays = ["fileRecentCommandIDs", "selectionCommandIDs", "textCommandIDs"]
  for (const name of literalArrays) {
    const loop = swiftForEachCalls(body, codeMask, "EditorCommands body")
      .filter(call => new RegExp(
        "^\\s*(?:Self\\.)?" + name + "\\s*,\\s*id:\\s*\\\\\\.self\\s*$"
      ).test(call.argumentsSource))
    check(loop.length === 1, "EditorCommands body must consume " + name + " once")
    const closure = loop[0].closureSource
    const closureMask = swiftCodeMask(closure, "EditorCommands." + name + " closure")
    const catalogCalls = swiftCalls(
      closure, closureMask, new Set(["routedCatalogButton"]),
      "EditorCommands." + name + " closure"
    )
    check(
      catalogCalls.length === 1
        && /^\s*commandID\s*$/.test(catalogCalls[0].argumentsSource),
      "EditorCommands body must render " + name
        + " through exactly one routedCatalogButton(commandID)"
    )
    const declarationAnchors = [
      "static let " + name + " =",
      "private var " + name + ": [String] {"
    ]
    const matches = declarationAnchors.map(anchor => ({
      anchor, index: source.indexOf(anchor)
    })).filter(match => match.index !== -1)
    check(matches.length === 1, "could not uniquely find EditorCommands." + name)
    const declaration = matches[0]
    const open = source.indexOf("[", declaration.index + declaration.anchor.length)
    const close = matchingDelimiter(
      source, open, "[", "]", "EditorCommands." + name
    )
    const arraySource = source.slice(open + 1, close)
    const arrayMask = swiftCodeMask(arraySource, "EditorCommands." + name)
    for (const entry of arraySource.matchAll(
      /"([a-z0-9]+(?:-[a-z0-9]+)*)"/g
    )) {
      // The opening quote itself is masked as string content. Its preceding
      // delimiter/whitespace remains code, while quotes inside comments have
      // a masked predecessor too.
      if (entry.index === 0 || arrayMask[entry.index - 1]) ids.push(entry[1])
    }
  }
  const counts = countValues(ids)
  const duplicates = new Map(
    [...counts].filter(([, count]) => count > 1)
  )
  assertMapEqual(
    duplicates, expectedNativeMenuDuplicates,
    "native SwiftUI menu command duplicates"
  )
  return new Set(ids)
}

function swiftCalls(source, codeMask, names, label) {
  const result = []
  const pattern = /\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g
  for (const match of source.matchAll(pattern)) {
    if (!names.has(match[1]) || !codeMask[match.index]) continue
    const open = match.index + match[0].lastIndexOf("(")
    const close = matchingDelimiter(
      source, open, "(", ")", label + " " + match[1]
    )
    result.push({
      name: match[1], index: match.index,
      argumentsSource: source.slice(open + 1, close), close
    })
  }
  return result
}

function swiftForEachCalls(source, codeMask, label) {
  return swiftCalls(source, codeMask, new Set(["ForEach"]), label).map(call => {
    const closureOpen = skipSwiftTrivia(source, call.close + 1)
    check(
      source[closureOpen] === "{",
      label + " ForEach must have an explicit trailing closure"
    )
    const closureClose = matchingDelimiter(
      source, closureOpen, "{", "}", label + " ForEach closure"
    )
    return {
      ...call,
      closureSource: source.slice(closureOpen + 1, closureClose)
    }
  })
}

function swiftCodeMask(source, label) {
  const mask = Array(source.length).fill(true)
  let state = "code"
  let blockDepth = 0
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    const next = source[index + 1]
    if (state === "string") {
      mask[index] = false
      if (character === "\\") {
        if (index + 1 < source.length) mask[++index] = false
      } else if (character === "\"") {
        state = "code"
      }
      continue
    }
    if (state === "line-comment") {
      mask[index] = false
      if (character === "\n") state = "code"
      continue
    }
    if (state === "block-comment") {
      mask[index] = false
      if (character === "/" && next === "*") {
        mask[++index] = false
        blockDepth += 1
      } else if (character === "*" && next === "/") {
        mask[++index] = false
        blockDepth -= 1
        if (blockDepth === 0) state = "code"
      }
      continue
    }
    if (character === "\"") {
      mask[index] = false
      state = "string"
    } else if (character === "/" && next === "/") {
      mask[index] = false
      mask[++index] = false
      state = "line-comment"
    } else if (character === "/" && next === "*") {
      mask[index] = false
      mask[++index] = false
      state = "block-comment"
      blockDepth = 1
    }
  }
  check(state !== "block-comment", label + " has an unterminated block comment")
  return mask
}

function parseMatrix(source, nativeSet) {
  const summaryAnchor = "清单覆盖统计（不含说明/风险表）："
  const summaryStart = uniqueIndexOf(source, summaryAnchor, "matrix coverage summary")
  const summaryEnd = uniqueIndexOf(source, "命令覆盖审计：", "command coverage audit")
  check(summaryEnd > summaryStart, "matrix coverage summary is out of order")
  const summaryLines = source.slice(summaryStart + summaryAnchor.length, summaryEnd)
    .split(/\r?\n/).filter(line => line.startsWith("|"))
  check(
    summaryLines[0] === "| 领域 | 条目数 | 领域 | 条目数 |",
    "matrix coverage summary must retain its four-column header"
  )
  check(
    /^\| -+ \| -+: \| -+ \| -+: \|$/.test(summaryLines[1] ?? ""),
    "matrix coverage summary separator has drifted"
  )
  const declared = new Map()
  let declaredTotal = null
  for (const line of summaryLines.slice(2)) {
    const cells = line.slice(1, -1).split("|").map(cell => cell.trim())
    if (cells[0].replaceAll("**", "") === "合计") {
      check(
        cells.length === 4 && /^\*\*\d+\*\*$/.test(cells[1]),
        "matrix total row has drifted"
      )
      declaredTotal = Number(cells[1].replaceAll("**", ""))
      continue
    }
    check(cells.length === 4, "invalid matrix coverage row: " + line)
    for (const [name, count] of [[cells[0], cells[1]], [cells[2], cells[3]]]) {
      const domainMatch = /(?:^|\s)([A-Z]+)$/.exec(name)
      const domain = domainMatch && domainMatch[1]
      check(
        domain && /^\d+$/.test(count),
        "invalid matrix coverage pair: " + name + " / " + count
      )
      check(!declared.has(domain), "matrix coverage repeats domain " + domain)
      declared.set(domain, Number(count))
    }
  }
  check(declaredTotal !== null, "matrix coverage summary has no total row")
  assertMapEqual(declared, expectedDomains, "declared matrix domain counts")

  const rowsStartAnchor = "## 2. 文件生命周期与磁盘格式"
  const rowsEndAnchor = "## 18. 命令与入口一致性债务"
  const rowsStart = uniqueIndexOf(source, rowsStartAnchor, "matrix feature rows start")
  const rowsEnd = uniqueIndexOf(source, rowsEndAnchor, "matrix feature rows end")
  check(rowsEnd > rowsStart, "matrix feature row bounds are out of order")
  const stageRows = source.slice(0, rowsStart).split(/\r?\n/)
    .map(line => {
      const match = /^\| (P[0-5]) \|/.exec(line)
      return match && match[1]
    }).filter(Boolean)
  check(
    stageRows.join(",") === "P0,P1,P2,P3,P4,P5",
    "expected the excluded phase table P0-P5, found " + stageRows.join(",")
  )

  const featureRows = []
  for (const line of source.slice(rowsStart, rowsEnd).split(/\r?\n/)) {
    const match = /^\| ([A-Z]+[0-9]{2}[a-z]?)\s+[^|]+\|/.exec(line)
    if (!match) continue
    const cells = line.slice(1, -1).split("|").map(cell => cell.trim())
    check(cells.length === 6, "matrix feature row must have six columns: " + match[1])
    featureRows.push({ id: match[1], commandCell: cells[1] })
  }
  const rowIDs = featureRows.map(row => row.id)
  check(
    rowIDs.length === expectedCounts.matrix,
    "matrix must contain " + expectedCounts.matrix + " feature rows, found " + rowIDs.length
  )
  check(new Set(rowIDs).size === rowIDs.length, "matrix feature row IDs must be unique")
  check(rowIDs.includes("N01a"), "matrix feature rows must include N01a")
  const actualDomains = new Map()
  for (const id of rowIDs) {
    const domain = /^([A-Z]+)/.exec(id)[1]
    actualDomains.set(domain, (actualDomains.get(domain) ?? 0) + 1)
  }
  assertMapEqual(actualDomains, declared, "matrix rows versus declared domain counts")
  const summed = [...declared.values()].reduce((sum, count) => sum + count, 0)
  check(
    declaredTotal === expectedCounts.matrix,
    "matrix declared total must be " + expectedCounts.matrix + ", found " + declaredTotal
  )
  check(summed === declaredTotal, "matrix domain counts sum to " + summed + ", not " + declaredTotal)

  const mentionedCommands = new Set()
  for (const row of featureRows) {
    const idPattern = new RegExp("\x60([a-z0-9]+(?:-[a-z0-9]+)*)\x60", "g")
    for (const match of row.commandCell.matchAll(idPattern)) {
      if (nativeSet.has(match[1])) mentionedCommands.add(match[1])
    }
  }
  const missingCommands = [...nativeSet].filter(id => !mentionedCommands.has(id)).sort()
  check(
    missingCommands.length === 0,
    "public native commands absent from matrix command cells: " + missingCommands.join(", ")
  )
  return rowIDs
}

async function swiftTestInventory(directory) {
  const files = []
  async function visit(current) {
    const entries = await readdir(current, { withFileTypes: true })
    for (const entry of entries) {
      const path = join(current, entry.name)
      if (entry.isDirectory()) await visit(path)
      else if (entry.isFile() && entry.name.endsWith(".swift")) files.push(path)
    }
  }
  await visit(directory)
  let tests = 0
  for (const file of files) {
    const source = await readFile(file, "utf8")
    tests += (source.match(/^[ \t]*func test[A-Za-z0-9_]*[ \t]*\(/gm) ?? []).length
  }
  return { files: files.length, tests }
}

export function checkNativeCommandParity({
  commandsSource, ipcSource, menuSource, mainSource, nativeSource,
  nativeMenuSource, matrixSource, i18nSource, nativeLocalizationSource,
  electronBuilderSource, nativeInfoPlistSource, nativeSettingsSource,
  electronFilesSource, nativeActionsSource
}) {
  const commandIDs = parseCommands(paths.commands, commandsSource)
  const menuEventIDs = parseMenuEvents(paths.ipc, ipcSource)
  const runCaseIDs = parseAppRunCases(paths.main, mainSource)
  const menuItems = parseMenuItems(paths.menu, menuSource)
  const nativeCommands = parseNativeCatalog(nativeSource)
  const nativeMenuIDs = parseNativeMenu(nativeMenuSource)
  verifySharedLocalizationParity(
    parseTypeScriptTranslationCatalog(paths.i18n, i18nSource),
    parseSwiftLocalizationCatalog(nativeLocalizationSource)
  )
  verifyFileAssociationParity(electronBuilderSource, nativeInfoPlistSource)
  verifyDefaultMaximumFileSizeParity(ipcSource, nativeSettingsSource)
  verifyMultiFileOpenFlow(electronFilesSource, mainSource, nativeActionsSource)

  const commandSet = new Set(commandIDs)
  const nativeSet = new Set(nativeCommands.map(command => command.id))
  assertSetEqual(
    nativeSet, new Set([...commandSet, ...menuOnlyCommands]),
    "native catalog must equal COMMANDS plus the two menu-only commands"
  )
  const menuEventSet = new Set(menuEventIDs)
  assertSetEqual(
    new Set(runCaseIDs), menuEventSet,
    "App.run case labels must equal the unique MenuEvent IDs"
  )
  const publicMenuEventSet = new Set(
    [...menuEventSet].filter(id => !internalMenuEvents.has(id))
  )
  assertSetEqual(publicMenuEventSet, nativeSet, "public MenuEvent IDs must equal the native catalog")
  assertSetEqual(
    nativeMenuIDs,
    new Set([...nativeSet].filter(id => !nativeCommandsWithoutMenuEntry.has(id))),
    "native SwiftUI menu surface"
  )
  assertSetEqual(
    new Set([...menuEventSet].filter(id => !commandSet.has(id))),
    new Set([...menuOnlyCommands, ...internalMenuEvents]),
    "MenuEvent IDs outside COMMANDS"
  )

  const menuItemSet = new Set(menuItems.map(item => item.id))
  assertSetEqual(
    menuItemSet,
    new Set([...nativeSet].filter(id => !commandsWithoutItemHelper.has(id))),
    "item helper command surface"
  )
  const menuShortcuts = new Map()
  for (const item of menuItems) {
    const shortcut = item.accelerator === null
      ? null
      : normalizeElectronAccelerator(item.accelerator, "menu item " + item.id)
    if (menuShortcuts.has(item.id)) {
      check(
        menuShortcuts.get(item.id) === shortcut,
        "duplicate menu item " + item.id + " has conflicting macOS accelerators"
      )
    } else {
      menuShortcuts.set(item.id, shortcut)
    }
  }
  const shortcutMismatches = []
  for (const command of nativeCommands) {
    const electronShortcut = menuShortcuts.get(command.id) ?? null
    if (electronShortcut !== command.shortcut) {
      shortcutMismatches.push(
        command.id + ": Electron=" + (electronShortcut ?? "nil")
          + ", native=" + (command.shortcut ?? "nil")
      )
    }
  }
  check(
    shortcutMismatches.length === 0,
    "macOS executable shortcut mismatches:\n" + shortcutMismatches.join("\n")
  )

  const matrix = parseMatrix(matrixSource, nativeSet)
  const executableShortcutCount = nativeCommands.filter(command => command.shortcut !== null).length
  return {
    commandCount: commandIDs.length,
    menuEventDeclarationCount: menuEventIDs.length,
    menuEventUniqueCount: menuEventSet.size,
    runCaseCount: runCaseIDs.length,
    nativeCommandCount: nativeCommands.length,
    menuItemDeclarationCount: menuItems.length,
    menuItemUniqueCount: menuShortcuts.size,
    executableShortcutCount,
    matrixRowCount: matrix.length
  }
}

async function main() {
  const [
    commandsSource, ipcSource, menuSource, mainSource, nativeSource,
    nativeMenuSource, matrixSource, i18nSource, nativeLocalizationSource,
    electronBuilderSource, nativeInfoPlistSource, nativeSettingsSource,
  electronFilesSource, nativeActionsSource
  ] =
    await Promise.all([
      paths.commands, paths.ipc, paths.menu, paths.main, paths.native,
      paths.nativeMenu, paths.matrix, paths.i18n, paths.nativeLocalization,
      paths.electronBuilder, paths.nativeInfoPlist, paths.nativeSettings,
      paths.electronFiles, paths.nativeActions
    ].map(path => readFile(path, "utf8")))
  const result = checkNativeCommandParity({
    commandsSource, ipcSource, menuSource, mainSource, nativeSource,
    nativeMenuSource, matrixSource, i18nSource, nativeLocalizationSource,
    electronBuilderSource, nativeInfoPlistSource, nativeSettingsSource,
    electronFilesSource, nativeActionsSource
  })
  const inventory = await swiftTestInventory(paths.tests)
  check(
    inventory.files === expectedCounts.swiftTestFiles,
    "expected " + expectedCounts.swiftTestFiles
      + " Swift test files, but the tree contains " + inventory.files
  )
  check(
    inventory.tests === expectedCounts.swiftTests,
    "expected " + expectedCounts.swiftTests
      + " Swift tests, but the tree contains " + inventory.tests
  )
  process.stdout.write(
    "Native command parity passed: " + result.commandCount + " COMMANDS, "
      + result.menuEventDeclarationCount + "/" + result.menuEventUniqueCount
      + " MenuEvent declarations/unique IDs, " + result.runCaseCount + " App.run cases, "
      + result.nativeCommandCount
      + " native commands, " + result.menuItemDeclarationCount + "/"
      + result.menuItemUniqueCount + " menu item calls/unique IDs, "
      + result.executableShortcutCount + " executable shortcuts, "
      + result.matrixRowCount
      + " matrix rows (P0-P5 excluded; N01a included), "
      + expectedCounts.sharedLocalizationKeys + " shared i18n keys verified, "
      + inventory.files + " Swift test files / " + inventory.tests
      + " test method declarations (execution is enforced by native macOS CI).\n"
  )
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch(error => {
    process.stderr.write((error instanceof Error ? error.message : String(error)) + "\n")
    process.exitCode = 1
  })
}
