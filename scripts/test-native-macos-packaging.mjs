import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { access, mkdtemp, readFile, readdir, rm } from "node:fs/promises"
import { constants } from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

if (process.platform === "win32") {
  process.stdout.write(
    "Native macOS packaging contract tests are exercised on Linux and macOS.\n"
  )
  process.exit(0)
}

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..")
const nativeRoot = join(repoRoot, "native-macos")
const scriptRoot = join(nativeRoot, "scripts")
const scriptNames = [
  "build-app.sh",
  "package-release.sh",
  "verify.sh",
  "copy-bundle-localization-resources.sh"
]
const packagedParserSmoke = join(scriptRoot, "run-packaged-parser-smoke.py")
const packagedWindowSmoke = join(scriptRoot, "run-packaged-window-smoke.py")
const scripts = Object.fromEntries(
  scriptNames.map(name => [name, join(scriptRoot, name)])
)
const packageSource = await readFile(join(nativeRoot, "Package.swift"), "utf8")
const ptyHeader = await readFile(
  join(nativeRoot, "Sources/LumenPTYSupport/include/LumenPTYSupport.h"), "utf8"
)
const ptySource = await readFile(
  join(nativeRoot, "Sources/LumenPTYSupport/LumenPTYSupport.c"), "utf8"
)
const terminalSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/TerminalController.swift"), "utf8"
)
const appLocalizationSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/AppLocalization.swift"), "utf8"
)
const workspaceSearchSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/WorkspaceSearchController.swift"), "utf8"
)
const projectSettingsSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/ProjectSettingsController.swift"), "utf8"
)
const settingsSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/SettingsController.swift"), "utf8"
)
const buildSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/BuildController.swift"), "utf8"
)
const languageToolsSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/LanguageToolsController.swift"), "utf8"
)
const editorConfigSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/EditorConfigController.swift"), "utf8"
)
const gitSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/GitController.swift"), "utf8"
)
const appModelSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/AppModel.swift"), "utf8"
)
const commandRouterSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/CommandRouter.swift"), "utf8"
)
const editorActionsSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/EditorActionController.swift"), "utf8"
)
assert.match(packageSource, /name: "LumenPTYSupport"/u)
assert.ok(
  packageSource.includes('dependencies: ["LumenPTYSupport"]'),
  "LumenEditorCore must link the PTY support target"
)
for (const contract of [
  "lumen_pty_spawn", "lumen_pty_resize",
  "lumen_pty_foreground_process_group", "lumen_pty_signal_process_group"
]) {
  assert.ok(ptyHeader.includes(contract), `PTY public contract: ${contract}`)
  assert.ok(ptySource.includes(contract), `PTY implementation: ${contract}`)
}
for (const boundary of ["forkpty", "execve", "_SC_OPEN_MAX", "TIOCSWINSZ", "FD_CLOEXEC"]) {
  assert.ok(ptySource.includes(boundary), `PTY process boundary: ${boundary}`)
}
assert.ok(terminalSource.includes("PseudoTerminalProcessRunner"), "Terminal production PTY adapter")
assert.ok(!terminalSource.includes("extension ToolProcessSession: TerminalProcessSessioning"),
  "Terminal must not fall back to the pipe session adapter")
for (const [label, source, contracts] of [
  ["workspace search", workspaceSearchSource, ["let titleContent: Title", "case searchError(WorkspaceSearchError)"]],
  ["project settings", projectSettingsSource, ["case store(ProjectSettingsStoreError)", "case verbatim(String)"]],
  ["global settings", settingsSource, ["case sessionOnly(cause: Cause, destinationPath: String)", "case store(SettingsStoreError)"]],
  ["build", buildSource, ["let titleContent: Title", "case persistence(BuildCommandPersistenceError)"]],
  ["language tools", languageToolsSource, ["let titleContent: Title", "case languageServer(LanguageServerClientError)", "case verbatim(String)"]],
  ["editor config", editorConfigSource, ["let titleContent: Title", "case resolution(EditorConfigResolutionError)", "case verbatim(String)"]],
  ["git", gitSource, ["let titleContent: Title", "case discardPreflight(GitDiscardPreflightError)", "case verbatim(String)"]],
  ["app model", appModelSource, ["public let titleContent: Title", "case textFileCodec(TextFileCodecError, context: String?)", "case verbatim(context: String?, message: String)"]]
]) {
  for (const contract of contracts) {
    assert.ok(source.includes(contract), `${label} typed localization contract: ${contract}`)
  }
}
for (const removedStringMatcher of [
  "localizedWorkspaceSearchIssueTitle(_ title: String)",
  "localizedProjectSettingsMessage(_ message: String)",
  "localizedSettingsPersistenceMessage(_ message: String)",
  "localizedLanguageToolIssueTitle(_ title: String)",
  "localizedEditorConfigIssueTitle(_ title: String)",
  "localizedGitIssueTitle(_ title: String)",
  "localizedAppModelIssueTitle(_ title: String)"
]) {
  assert.ok(
    !appLocalizationSource.includes(removedStringMatcher),
    `runtime localization must not restore English reverse matching: ${removedStringMatcher}`
  )
}
for (const contract of [
  "case appModel(AppModelIssue)",
  "case navigation(NavigationPresentationIssue)",
  "case languageTool(LanguageToolPresentationIssue)",
  "case languageServer(LanguageServerPresentationIssue)",
  "case securityScope(SecurityScopedAccessError, context: String?)"
]) {
  assert.ok(
    commandRouterSource.includes(contract),
    `command routing typed presentation contract: ${contract}`
  )
}
for (const contract of [
  "case failedPresentation(CommandPresentation)",
  "return .failedPresentation(.appModel(issue))"
]) {
  assert.ok(
    editorActionsSource.includes(contract),
    `editor action typed presentation contract: ${contract}`
  )
}
for (const flattenedFailure of [
  "CommandHandlerSignal.failed(issue.message)"
]) {
  assert.ok(
    !languageToolsSource.includes(flattenedFailure),
    `language-tool command routing must not flatten typed issues: ${flattenedFailure}`
  )
}

function run(command, arguments_, options = {}) {
  return spawnSync(command, arguments_, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 10_000,
    ...options
  })
}

function assertFailure(result, expectedStatus) {
  assert.equal(result.error, undefined, result.error?.message)
  assert.equal(result.status, expectedStatus, `${result.stdout}${result.stderr}`)
  assert.equal(result.signal, null, `invocation was terminated by ${result.signal}`)
}

function parsePropertyList(source, label) {
  const text = source.toString("utf8")
  assert.match(text, /^<\?xml[^>]*>\s*<!DOCTYPE plist[^>]*>\s*<plist version="1\.0">/u, label)
  assert.match(text, /<\/plist>\s*$/u, label)
  const values = {}
  const scalar = /<key>([^<]+)<\/key>\s*(?:<string>([^<]*)<\/string>|<(true|false)\/>)/gu
  for (const match of text.matchAll(scalar)) {
    assert.equal(Object.hasOwn(values, match[1]), false, `${label}: duplicate key ${match[1]}`)
    values[match[1]] = match[3] === undefined ? match[2] : match[3] === "true"
  }
  assert.ok(Object.keys(values).length > 0, `${label}: no scalar plist values`)
  return values
}

function parseStrings(source, label) {
  let offset = 0
  const entries = new Map()

  function skipTrivia() {
    while (offset < source.length) {
      if (/\s/u.test(source[offset])) {
        offset += 1
      } else if (source.startsWith("//", offset)) {
        const newline = source.indexOf("\n", offset + 2)
        offset = newline === -1 ? source.length : newline + 1
      } else if (source.startsWith("/*", offset)) {
        const end = source.indexOf("*/", offset + 2)
        assert.notEqual(end, -1, `${label}: unterminated comment`)
        offset = end + 2
      } else {
        break
      }
    }
  }

  function quotedString() {
    assert.equal(source[offset], '"', `${label}: expected quoted string at ${offset}`)
    offset += 1
    let result = ""
    while (offset < source.length && source[offset] !== '"') {
      if (source[offset] !== "\\") {
        result += source[offset]
        offset += 1
        continue
      }
      offset += 1
      assert.ok(offset < source.length, `${label}: unterminated escape`)
      const escape = source[offset++]
      const simple = { n: "\n", r: "\r", t: "\t", '"': '"', "\\": "\\" }
      if (Object.hasOwn(simple, escape)) {
        result += simple[escape]
      } else if (escape === "U") {
        const hex = source.slice(offset, offset + 4)
        assert.match(hex, /^[0-9a-f]{4}$/iu, `${label}: invalid Unicode escape`)
        result += String.fromCodePoint(Number.parseInt(hex, 16))
        offset += 4
      } else {
        result += escape
      }
    }
    assert.equal(source[offset], '"', `${label}: unterminated quoted string`)
    offset += 1
    return result
  }

  skipTrivia()
  while (offset < source.length) {
    const key = quotedString()
    skipTrivia()
    assert.equal(source[offset++], "=", `${label}: expected =`)
    skipTrivia()
    const value = quotedString()
    skipTrivia()
    assert.equal(source[offset++], ";", `${label}: expected ;`)
    assert.equal(entries.has(key), false, `${label}: duplicate key ${key}`)
    entries.set(key, value)
    skipTrivia()
  }
  return entries
}

for (const path of Object.values(scripts)) {
  await access(path, constants.X_OK)
  const syntax = run("bash", ["-n", path])
  assert.equal(syntax.status, 0, `${basename(path)}: ${syntax.stderr}`)
}
await access(packagedParserSmoke, constants.X_OK)
const smokeSource = await readFile(packagedParserSmoke, "utf8")
const windowSmokeSource = await readFile(packagedWindowSmoke, "utf8")
assert.equal(
  run("python3", ["-c", "import ast,sys; ast.parse(sys.stdin.read())"], {
    input: smokeSource
  }).status,
  0
)
assertFailure(run("python3", [packagedParserSmoke]), 2)
assertFailure(run("python3", [packagedParserSmoke, "/does/not/exist"]), 1)
assert.equal(
  run("python3", ["-c", "import ast,sys; ast.parse(sys.stdin.read())"], {
    input: windowSmokeSource
  }).status,
  0
)
assertFailure(run("python3", [packagedWindowSmoke]), 2)
assertFailure(run("python3", [packagedWindowSmoke, "/does/not/exist"]), 1)

// The localization helper is intentionally a directly executable public build
// step. Its no-argument contract must fail before it writes anything.
assertFailure(
  run(scripts["copy-bundle-localization-resources.sh"], []),
  1
)

// A regression that reaches Swift, signing, or filesystem setup would fail
// with a different diagnostic, so these also enforce validation ordering.
assertFailure(
  run(scripts["build-app.sh"], [], {
    env: { ...process.env, CONFIGURATION: "profile" }
  }),
  2
)
const releaseBaseEnvironment = {
  ...process.env,
  VERSION: "0.1.0",
  BUILD_NUMBER: "1",
  ARCHITECTURE: "arm64"
}
assertFailure(
  run(scripts["package-release.sh"], [], {
    env: { ...releaseBaseEnvironment, ARCHITECTURE: "universal" }
  }),
  2
)
assertFailure(
  run(scripts["package-release.sh"], [], {
    env: { ...releaseBaseEnvironment, BUILD_NUMBER: "" }
  }),
  1
)
for (const buildNumber of ["1.5", "+1", " 1"]) {
  assertFailure(
    run(scripts["package-release.sh"], [], {
      env: { ...releaseBaseEnvironment, BUILD_NUMBER: buildNumber }
    }),
    2
  )
}

const scriptSources = new Map(await Promise.all(Object.entries(scripts).map(async ([name, path]) => [
  name, await readFile(path, "utf8")
])))
for (const name of ["build-app.sh", "package-release.sh"]) {
  const source = scriptSources.get(name)
  for (const resource of [
    "AppIcon.icns",
    "CodeMirrorParserBundle.js",
    "en.lproj",
    "zh_CN.lproj",
    "InfoPlist.strings"
  ]) assert.ok(source.includes(resource), `${name}: ${resource}`)
  assert.ok(
    source.includes("run-packaged-parser-smoke.py"),
    `${name}: bounded parser smoke helper`
  )
  const freshnessGate = source.indexOf('npm run check:native-parser')
  const firstSwiftBuild = source.indexOf('swift build')
  const firstParserCopy = source.indexOf('cp "$parser_bundle"')
  assert.ok(freshnessGate >= 0, `${name}: parser freshness gate`)
  assert.ok(
    freshnessGate < firstSwiftBuild && freshnessGate < firstParserCopy,
    `${name}: parser freshness gate must precede build and copy`
  )
}
{
  const source = scriptSources.get("verify.sh")
  const freshnessGate = source.indexOf('npm run check:native-parser')
  const firstSwiftCommand = source.indexOf('swift package describe')
  assert.ok(freshnessGate >= 0, "verify.sh: parser freshness gate")
  assert.ok(
    freshnessGate < firstSwiftCommand,
    "verify.sh: parser freshness gate must precede Swift verification"
  )
}
assert.ok(smokeSource.includes("--lumen-parser-smoke"), "packaged parser smoke argument")
for (const contract of [
  "--lumen-window-smoke", "native-macos-packaged-window",
  "editorSessionCount", "mainActorRoundTrips", "gracefulExit",
  '"/usr/bin/open", "-W", "-n"'
]) {
  assert.ok(windowSmokeSource.includes(contract), `packaged window smoke: ${contract}`)
}
const applicationDelegateSource = await readFile(
  join(nativeRoot, "Sources/LumenEditorApp/LumenApplicationDelegate.swift"), "utf8"
)
const nativeMacWorkflowSource = await readFile(
  join(repoRoot, ".github/workflows/native-macos.yml"), "utf8"
)
const releaseWorkflowSource = await readFile(
  join(repoRoot, ".github/workflows/release.yml"), "utf8"
)
for (const contract of [
  "PackagedWindowSmoke", "NSApplication.shared.windows", "window.isVisible",
  "window.canBecomeKey", "window.contentView != nil",
  "NSApplication.shared.terminate(nil)", "applicationWillTerminate",
  "pendingPackagedWindowSmokeEvidence"
]) {
  assert.ok(applicationDelegateSource.includes(contract), `packaged app lifecycle: ${contract}`)
}
for (const [label, source] of [
  ["native macOS CI", nativeMacWorkflowSource],
  ["tag release", releaseWorkflowSource]
]) {
  assert.ok(source.includes("run-packaged-window-smoke.py"),
    `${label}: packaged window smoke gate`)
  assert.ok(source.includes("window-smoke.json"),
    `${label}: structured window smoke evidence`)
  assert.ok(source.includes("upload-artifact@"),
    `${label}: retained runtime evidence`)
}
assert.ok(
  scriptSources.get("copy-bundle-localization-resources.sh").includes("plutil -lint"),
  "localization copying must lint .strings on macOS"
)

const infoSource = await readFile(join(nativeRoot, "Packaging/Info.plist"))
const info = parsePropertyList(infoSource, "Info.plist")
assert.equal(info.CFBundleExecutable, "LumenEditor")
assert.equal(info.CFBundleIconFile, "AppIcon")
assert.equal(info.CFBundlePackageType, "APPL")
assert.equal(info.CFBundleDevelopmentRegion, "zh_CN")
assert.equal(info.LSMultipleInstancesProhibited, true)

// Finder uses LaunchServices document metadata, not the app's open-panel
// configuration. Keep a concrete Alternate declaration for common plain-text
// and source extensions so a clean macOS install offers the native editor in
// Open With without taking over another app's default association.
const infoText = infoSource.toString("utf8")
assert.match(
  infoText,
  /<key>CFBundleTypeRole<\/key>\s*<string>Editor<\/string>/u,
  "Info.plist: Finder document editor role"
)
assert.match(
  infoText,
  /<key>LSHandlerRank<\/key>\s*<string>Alternate<\/string>/u,
  "Info.plist: Finder document handler must remain Alternate"
)
for (const requiredType of [
  "com.lumen.editor.native.text-document", "public.plain-text",
  "public.text", "public.source-code", "public.json",
  "net.daringfireball.markdown"
]) {
  assert.ok(infoText.includes(`<string>${requiredType}</string>`),
    `Info.plist: document UTI ${requiredType}`)
}
for (const extension of [
  "txt", "md", "json", "swift", "py", "js", "ts",
  "tsx", "html", "css", "java", "c", "cpp", "rs",
  "go", "sh", "sql", "yaml", "toml"
]) {
  const token = `<string>${extension}</string>`
  assert.ok(
    infoText.indexOf(token) !== -1,
    `Info.plist: Finder document extension ${extension}`
  )
}
assert.match(
  infoText,
  /<key>UTExportedTypeDeclarations<\/key>[\s\S]*?<string>com\.lumen\.editor\.native\.text-document<\/string>/u,
  "Info.plist: custom Finder text UTI declaration"
)

const entitlementContracts = new Map([
  ["LumenEditor.entitlements", [
    "com.apple.security.app-sandbox",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.network.client"
  ]],
  ["LumenPluginWorker.entitlements", [
    "com.apple.security.app-sandbox", "com.apple.security.inherit"
  ]],
  ["LumenParserWorker.entitlements", [
    "com.apple.security.app-sandbox", "com.apple.security.inherit"
  ]]
])
for (const [name, expectedKeys] of entitlementContracts) {
  const document = parsePropertyList(
    await readFile(join(nativeRoot, "Packaging", name)), name
  )
  assert.deepEqual(Object.keys(document).sort(), expectedKeys.sort(), name)
  for (const key of expectedKeys) assert.equal(document[key], true, `${name}: ${key}`)
}

const temporaryRoot = await mkdtemp(join(tmpdir(), "lumen-native-packaging-test-"))
try {
  const destination = join(temporaryRoot, "Bundle Resources")
  const copied = run(scripts["copy-bundle-localization-resources.sh"], [destination])
  assert.equal(copied.status, 0, copied.stderr)
  assert.deepEqual((await readdir(destination)).sort(), ["en.lproj", "zh_CN.lproj"])
  for (const locale of ["en", "zh_CN"]) {
    const resourceName = join(`${locale}.lproj`, "InfoPlist.strings")
    const source = await readFile(join(nativeRoot, "Packaging", resourceName))
    const output = await readFile(join(destination, resourceName))
    assert.deepEqual(output, source, resourceName)
    assert.deepEqual(await readdir(join(destination, `${locale}.lproj`)), ["InfoPlist.strings"])
    const strings = parseStrings(source.toString("utf8"), resourceName)
    assert.deepEqual(
      [...strings.keys()].sort(),
      ["CFBundleDisplayName", "CFBundleName", "CFBundleTypeName"]
    )
    for (const value of strings.values()) assert.notEqual(value.length, 0, resourceName)
  }
} finally {
  await rm(temporaryRoot, { recursive: true, force: true })
}

await access(
  join(nativeRoot, "Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"),
  constants.R_OK
)
await access(join(repoRoot, "build/icon.icns"), constants.R_OK)
process.stdout.write("Native macOS packaging contract tests passed.\n")
