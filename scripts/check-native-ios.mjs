import { access, readFile, readdir } from "node:fs/promises"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const iosRoot = join(root, "native-ios")
const projectPath = join(iosRoot, "LumenEditorIOS.xcodeproj/project.pbxproj")

function fail(message) { throw new Error(`[native-ios] ${message}`) }
function expect(source, pattern, message) { if (!pattern.test(source)) fail(message) }

async function filesUnder(directory, extension) {
  const output = []
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isDirectory()) output.push(...await filesUnder(path, extension))
    else if (entry.name.endsWith(extension)) output.push(path)
  }
  return output.sort()
}

const requiredFiles = [
  "Info.plist",
  "Resources/PrivacyInfo.xcprivacy",
  "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
  "Resources/en.lproj/Localizable.strings",
  "Resources/en.lproj/InfoPlist.strings",
  "Resources/zh-Hans.lproj/Localizable.strings",
  "Resources/zh-Hans.lproj/InfoPlist.strings",
  "LumenEditorIOS.xcodeproj/project.pbxproj",
  "LumenEditorIOS.xcodeproj/xcshareddata/xcschemes/LumenEditorIOS.xcscheme",
  "Sources/LumenEditorMobileCore/MobileTextCodec.swift",
  "Sources/LumenEditorMobileCore/DraftStore.swift",
  "Sources/LumenEditorMobileCore/MobileFindCore.swift",
  "Sources/LumenEditorMobileCore/MobileEditingCore.swift",
  "Sources/LumenEditorIOSApp/MobileFileAccess.swift",
  "Sources/LumenEditorIOSApp/MobileFilePresenter.swift",
  "Sources/LumenEditorIOSApp/SystemShareSheet.swift",
  "Sources/LumenEditorIOSApp/NativeTextEditor.swift",
  "Sources/LumenEditorIOSApp/RootView.swift",
  "Tests/LumenEditorMobileCoreTests/MobileEditingCoreTests.swift",
  "Tests/LumenEditorMobileCoreTests/MobileTextCodecTests.swift",
  "Tests/LumenEditorIOSUITests/LumenEditorIOSUITests.swift"
]
await Promise.all(requiredFiles.map((path) => access(join(iosRoot, path))))

const [project, scheme, info, privacy, codec, drafts, persistence, findCore, documentSession, appEntry, fileAccess, filePresenter, workspace, editor, editorScreen, findBar, rootView, documentSwitcher, codecTests, uiTests, packageJson] =
  await Promise.all([
    readFile(projectPath, "utf8"),
    readFile(join(iosRoot, "LumenEditorIOS.xcodeproj/xcshareddata/xcschemes/LumenEditorIOS.xcscheme"), "utf8"),
    readFile(join(iosRoot, "Info.plist"), "utf8"),
    readFile(join(iosRoot, "Resources/PrivacyInfo.xcprivacy"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorMobileCore/MobileTextCodec.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorMobileCore/DraftStore.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorMobileCore/DocumentTypes.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorMobileCore/MobileFindCore.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/MobileDocumentSession.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/LumenEditorIOSApp.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/MobileFileAccess.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/MobileFilePresenter.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/MobileWorkspaceModel.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/NativeTextEditor.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/EditorScreen.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/FindBar.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/RootView.swift"), "utf8"),
    readFile(join(iosRoot, "Sources/LumenEditorIOSApp/DocumentSwitcherView.swift"), "utf8"),
    readFile(join(iosRoot, "Tests/LumenEditorMobileCoreTests/MobileTextCodecTests.swift"), "utf8"),
    readFile(join(iosRoot, "Tests/LumenEditorIOSUITests/LumenEditorIOSUITests.swift"), "utf8"),
    readFile(join(root, "package.json"), "utf8")
  ])
const workflow = await readFile(join(root, ".github/workflows/native-ios.yml"), "utf8")

for (const sourcePath of await filesUnder(join(iosRoot, "Sources"), ".swift")) {
  const name = sourcePath.split("/").at(-1)
  if (!project.includes(`/* ${name} in Sources */`)) {
    fail(`${relative(root, sourcePath)} is not compiled by the Xcode project`)
  }
}
for (const testPath of await filesUnder(join(iosRoot, "Tests"), ".swift")) {
  const name = testPath.split("/").at(-1)
  if (!project.includes(`/* ${name} in Sources */`)) {
    fail(`${relative(root, testPath)} is not compiled by the test target`)
  }
}
const projectObjectIDs = [...project.matchAll(
  /^\s*([A-F0-9]{24})(?: \/\*.*\*\/)? = \{/gm
)].map((match) => match[1])
const duplicateProjectObjectIDs = projectObjectIDs.filter(
  (id, index) => projectObjectIDs.indexOf(id) !== index
)
if (duplicateProjectObjectIDs.length > 0) {
  fail(`Xcode project has duplicate object IDs: ${[
    ...new Set(duplicateProjectObjectIDs)
  ].join(", ")}`)
}

expect(project, /IPHONEOS_DEPLOYMENT_TARGET = 17.0/g, "deployment target must be iOS 17")
expect(project, /PRODUCT_BUNDLE_IDENTIFIER = com.lumen.editor.native-preview.ios;/,
  "the iOS preview needs an isolated bundle identifier")
expect(project, /productType = "com.apple.product-type.application";/,
  "application target is missing")
expect(project, /productType = "com.apple.product-type.bundle.unit-test";/,
  "Core unit-test target is missing")
expect(project, /productType = "com.apple.product-type.bundle.ui-testing";/,
  "UI smoke-test target is missing")
expect(scheme, /BlueprintName="LumenEditorMobileCoreTests"/,
  "shared scheme must include Core tests")
expect(scheme, /BlueprintName="LumenEditorIOSUITests"/,
  "shared scheme must include UI smoke tests")
expect(appEntry, /#if DEBUG[\s\S]*LUMEN_UI_TEST_SESSION[\s\S]*#else[\s\S]*nil[\s\S]*#endif/,
  "UI-test storage isolation must be unavailable to Release builds")
expect(rootView, /LumenEditorUITests[\s\S]*MobileDraftStore[\s\S]*MobileRecentStore/,
  "UI tests must use isolated recovery and recent-file stores")
expect(uiTests, /launchEnvironment\["LUMEN_UI_TEST_SESSION"\] = UUID\(\)\.uuidString/,
  "every UI test launch must receive a fresh isolated storage session")
expect(uiTests, /waitUntilHittable[\s\S]*exists == true AND hittable == true/,
  "UI tests must wait for startup recovery to release interactive controls")
expect(uiTests, /launchedApp = app[\s\S]*app\.launch\(\)/,
  "UI tests must retain the application handle before a launch can fail")
expect(uiTests, /XCTAttachment\(screenshot: XCUIScreen\.main\.screenshot\(\)\)[\s\S]*lifetime = \.keepAlways/,
  "UI test result bundles must retain final simulator evidence after app crashes")
for (const testName of [
  "testLaunchCreateAndEditDocument",
  "testReplaceAllThenUndoAndRedo",
  "testCreateAndSwitchBetweenTwoDrafts",
  "testChineseLaunchUsesLocalizedGeneratedDocumentName"
]) {
  expect(uiTests, new RegExp(`func ${testName}\\(`), `UI test ${testName} is missing`)
}
expect(codecTests, /testEverySupportedEncodingAndLineEndingRoundTripsStrictly[\s\S]*MobileTextEncoding\.allCases[\s\S]*MobileLineEnding\.allCases/,
  "codec tests must exercise every declared encoding and line-ending pair")
expect(codecTests, /testEastAsianEncodingFixturesMatchStandardBytes[\s\S]*0x94, 0x39, 0xfc, 0x36[\s\S]*testWesternEncodingFixturesMatchStandardBytes/,
  "legacy codec tests must include known external byte fixtures")
for (const identifier of [
  "FindMenuButton", "ToggleReplaceButton", "ReplaceAllButton",
  "CloseFindButton", "UndoMenuButton", "RedoMenuButton",
  "AddDocumentButton", "NewDocumentMenuButton", "DocumentRow-"
]) {
  if (![editorScreen, findBar, rootView, documentSwitcher].some(
    (source) => source.includes(identifier)
  )) {
    fail(`UI flow identifier ${identifier} is missing from the app`)
  }
}
expect(project, /ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;/, "an iOS app icon is required")
expect(project, /InfoPlist.strings in Resources/,
  "the system-visible app name must be localized")
expect(info, /<key>LSSupportsOpeningDocumentsInPlace<\/key>\s*<true\/>/,
  "open-in-place document support is required")
expect(info, /<string>public.source-code<\/string>/, "source-code document activation is required")
expect(privacy, /<key>NSPrivacyTracking<\/key>\s*<false\/>/,
  "privacy manifest must explicitly disable tracking")

expect(codec, /defaultMaximumByteCount: Int64 = 20 \* 1_024 \* 1_024/,
  "mobile editing limit must remain 20 MiB")
expect(codec, /SHA256\.hash/, "exact-byte revisions are required")
expect(codec, /case \.gb18030, \.gbk, \.big5, \.shiftJIS/,
  "legacy encoding support must remain explicit")
expect(codec, /if let forcedEncoding/,
  "explicit encoding reopen must use strict decoding")
expect(codec, /encodingRecoveryData: issue == nil \? nil : data/,
  "uncertain decoding must retain original bytes for recovery")
expect(drafts, /FileProtectionType\.completeUntilFirstUserAuthentication/,
  "recovery drafts must use data protection")
expect(drafts, /\[\.atomic, \.completeFileProtectionUntilFirstUserAuthentication\]/,
  "recovery checkpoints must be atomic and protected")
expect(drafts, /MobileDraftRestoreReport/,
  "damaged recovery files must be reported instead of silently discarded")
expect(drafts, /snapshot\.id\.uuidString\.lowercased\(\)/,
  "recovery filenames must agree with their embedded document identity")
expect(drafts, /checkpointGeneration/,
  "recovery ordering must use a monotonic document generation")
expect(drafts, /encodingRecoveryData/,
  "ambiguous source bytes must survive app termination for safe encoding selection")
expect(persistence, /maximumEstimatedPayloadByteCount\s*=\s*96 \* 1_024 \* 1_024/,
  "the shared mobile workspace budget must remain 96 MiB")
expect(drafts, /maximumRestoredMemoryByteCount\s*=\s*\n?\s*MobileWorkspaceCapacity\.maximumEstimatedPayloadByteCount/,
  "startup recovery must use the shared workspace memory budget")
expect(drafts, /fileSizeKey[\s\S]*contentModificationDateKey[\s\S]*maximumRestoreCandidateSerializedByteCount/,
  "startup recovery must preflight and order files before bounded decoding")
expect(drafts, /readBoundedData/,
  "recovery files must be bounded while reading, not after allocating them")
expect(drafts, /serializedByteCount = data\.count[\s\S]*addingWithoutOverflow\(\s*serializedByteCount, candidateMemoryByteCount/,
  "recovery memory accounting must use bytes actually read after the metadata preflight")
expect(persistence, /retainAfterUnverifiedCopy/,
  "an unverified Save As copy must not replace the existing source baseline")
expect(project, /MobileRecentStore\.swift in Sources/,
  "the recent-file store must be compiled into Mobile Core")
expect(fileAccess, /NSFileCoordinator/, "File Provider I/O must be coordinated")
expect(fileAccess, /startAccessingSecurityScopedResource/, "security-scoped access is required")
expect(fileAccess, /MobileSavePreflight\.validate/, "writes must reject stale source revisions")
expect(fileAccess, /func writeVerified\([\s\S]*guard Int64\(data\.count\)[\s\S]*return try withSecurityScope\(reference\.url\)/,
  "verified writes must return the security-scoped operation result")
expect(fileAccess, /guard installed == data/, "writes must be read-back verified")
expect(fileAccess, /handle\.read\(upToCount: requested\)/,
  "provider reads must enforce the mobile byte limit before loading a whole file")
expect(fileAccess, /defaultMaximumByteCount else/,
  "encoded saves and exports must enforce the mobile byte limit")
if (/write\(to: writeURL, options: \[\.atomic\]\)/.test(fileAccess)) {
  fail("File Provider writes must not assume path-level atomic rename semantics")
}
expect(filePresenter, /NSFilePresenter/, "external File Provider changes need NSFilePresenter")
expect(filePresenter, /startAccessingSecurityScopedResource/,
  "the file presenter must retain security scope while monitoring")
expect(filePresenter, /stopAccessingSecurityScopedResource/,
  "the file presenter must release security scope when monitoring ends")
expect(filePresenter, /presentedItemDidChange/, "external file modifications must be observed")
expect(filePresenter, /accommodatePresentedItemDeletion/, "external deletions must be observed")
expect(filePresenter, /presentedItemDidMove/, "external moves must refresh the document reference")
expect(workspace, /catch is SavePreflightError/,
  "save preflight conflicts must enter the external-change resolution flow")
expect(workspace, /presenterTokens\[documentID\] == presenterToken/,
  "stale File Provider callbacks must not affect a newly bound source")
expect(workspace, /standardizedFileURL == expectedURL/,
  "stale asynchronous reads must not replace a document after its source changes")
expect(workspace, /if document.externalChange != nil/,
  "a conflict arriving during a save must keep the document dirty")
expect(workspace, /try await drafts\.checkpoint\(recoverySnapshot\)/,
  "the private recovery draft must be durable before a provider write begins")
expect(workspace, /func exportData\([\s\S]{0,240}try await drafts\.checkpoint\(document\.draftSnapshot\(\)\)[\s\S]{0,120}return try await files\.encode\(/,
  "exports must return the encoded data after checkpointing recovery")
expect(workspace, /preserveLocalCopyAndReload/,
  "conflicts must support preserving local work before reload")
expect(workspace, /try await drafts\.checkpoint\(localCopy\.draftSnapshot\(\)\)/,
  "a preserved conflict copy must be durable before the source is reloaded")
expect(workspace, /keepDeletedSourceAsDraft/,
  "deleted sources must be detachable as recovery drafts")
expect(workspace, /scheduleExternalInspection\(document, delay: \.zero\)/,
  "dirty recovered drafts must revalidate their source revision before saving")
expect(workspace, /beginBackgroundTask\(/,
  "background transitions must request time to finish recovery checkpoints")
expect(workspace, /try await drafts\.remove\(id: document\.id\)/,
  "a document must remain open until its recovery draft is removed")
expect(workspace, /externalInspectionTokens\[document\.id\] == inspectionToken/,
  "cancelled provider inspections must not publish stale failures")
expect(workspace, /pendingMovedURLs/,
  "provider moves must remain retryable until the new bookmark is installed")
expect(workspace, /openingURLs\.insert\(normalizedURL\)\.inserted/,
  "concurrent open requests must not create duplicate source sessions")
expect(workspace, /isBusy = true[\s\S]*busyOperationCount = 1[\s\S]*await waitForStartup\(\)/,
  "user operations must wait until startup recovery has completed")
expect(workspace, /foregroundRevalidationPending[\s\S]*initializeWorkspace\(\)[\s\S]*inspectOpenSourcesAfterActivation/,
  "foreground source validation must not be lost during startup recovery")
expect(workspace, /MobileWorkspaceCapacity\.rejection/,
  "new, opened, and conflict-copy documents must enforce workspace capacity")
expect(editor, /shouldChangeTextIn[\s\S]*MobileWorkspaceCapacity\.utf16UnitCount[\s\S]*canReplaceContent/,
  "TextKit edits must be rejected before they exceed the workspace memory budget")
expect(editor, /synchronizeCommittedText[\s\S]*canReplaceContent\(textView\.textStorage\.length\)[\s\S]*textView\.text = parent\.text/,
  "committed TextKit changes must be rolled back if a delegate path bypasses preflight")
expect(workspace, /canReplaceDocumentContent[\s\S]*replacementRejection[\s\S]*workspace_edit_memory_limit/,
  "growing edits must enforce capacity while non-growing edits remain available")
expect(documentSession, /didSet \{ contentUTF16UnitCount = content\.utf16\.count \}/,
  "document sessions must cache UTF-16 length when content changes")
expect(documentSession, /func draftSnapshot\([\s\S]*checkpointGeneration \+= 1[\s\S]*return MobileDraftSnapshot\(/,
  "draft snapshots must return the generation-advanced value")
expect(workspace, /currentUTF16UnitCount: document\.contentUTF16UnitCount[\s\S]*utf16UnitCount: document\.contentUTF16UnitCount/,
  "per-keystroke workspace checks must use cached document lengths")
expect(editorScreen, /utf16_units[\s\S]*document\.contentUTF16UnitCount/,
  "the editor status must not rescan the full document for its UTF-16 length")
expect(workspace, /let opened = try await files\.open\(reference\)[\s\S]*standardizedFileURL == expectedURL[\s\S]*validateReload\(opened, replacing: document\)/,
  "preserve-and-reload must discard a stale provider read after the source binding changes")
expect(workspace, /try validateReload\(opened, replacing: document\)\s*applyReload\(opened, to: document\)\s*\} catch \{\s*guard documents\.contains[\s\S]{0,180}standardizedFileURL == expectedURL else \{ return \}/,
  "preserve-and-reload must discard stale provider failures after the source binding changes")
expect(workspace, /private func reloadFromSource[\s\S]*let opened = try await files\.open\(reference\)[\s\S]*standardizedFileURL == expectedURL[\s\S]*validateReload\(opened, replacing: document\)[\s\S]*catch \{[\s\S]*standardizedFileURL == expectedURL/,
  "manual reload must ignore stale provider success and failure results")
expect(workspace, /validateReload\(opened, replacing: document\)[\s\S]*excludingDocumentID/,
  "source reloads must replace, rather than double-count, the current document capacity")
expect(findCore, /replacementUTF16Length[\s\S]*maximumOutputUTF16Length[\s\S]*replacementExceedsLimit[\s\S]*NSMutableString\(capacity: outputLength\)/,
  "find/replace must bound output before constructing the replacement string")
expect(findCore, /ReplacementTemplateSegment[\s\S]*replacementSegments[\s\S]*appendLiteral[\s\S]*appendReplacement/,
  "regex replacement preflight and output must share a Unicode-safe template parser")
expect(findBar, /maximumReplacementUTF16UnitCount[\s\S]*maximumOutputUTF16Length:/,
  "find/replace must receive the current document's remaining workspace budget")
expect(workspace, /retainAfterUnverifiedCopy\(\)/,
  "an unverified Save As must preserve the original source baseline")
expect(editorScreen, /confirmationDialog\(/,
  "source conflicts need an explicit mobile resolution dialog")
expect(editorScreen, /String\(localized: "save_as"\)/,
  "Save As must remain available for conflict recovery")
expect(editorScreen, /SystemShareSheet/, "the system share sheet must expose encoded snapshots")
expect(editorScreen, /!document.requiresEncodingConfirmation && !document.isSaving/,
  "reload and encoding operations must temporarily lock editing")
expect(editorScreen, /UIAccessibility\.post\(notification: \.announcement/,
  "save and recovery notices must be announced to VoiceOver")
expect(fileAccess, /LumenShare-/, "sharing must use an app-owned temporary snapshot")
const shareDirectoryCreations = [
  ...fileAccess.matchAll(/\.appendingPathComponent\("LumenShare-/g)
]
if (shareDirectoryCreations.length !== 1) {
  fail("share snapshots must use exactly one app-owned LumenShare directory layer")
}
expect(fileAccess, /cleanupAbandonedShareSnapshots/,
  "abandoned temporary share snapshots must be cleaned on the next launch")
expect(fileAccess, /completeFileProtectionUntilFirstUserAuthentication/,
  "temporary share snapshots must use iOS data protection")
expect(editor, /LumenTextView\(usingTextLayoutManager: true\)/, "TextKit 2 must back the editor")
expect(editor, /markedTextRange == nil/, "IME composition must be protected from model write-back")
expect(editor, /guard textView\.markedTextRange == nil else \{ return \}/,
  "IME composition must not publish partial marked text")
expect(editor, /adjustsFontForContentSizeCategory = true/, "Dynamic Type support is required")
expect(editor, /UIKeyCommand\(input: "s"/, "external-keyboard save command is required")
expect(editor, /case \.indent:/, "mobile multi-line indentation is required")
expect(editor, /case \.duplicateLines:/, "mobile line duplication is required")
expect(findCore, /shouldCancel: @escaping @Sendable/,
  "bounded find operations must support cooperative cancellation")
expect(findBar, /Task\.detached\(priority: \.userInitiated\)/,
  "large find scans must run away from the main actor")
expect(findBar, /dynamicTypeSize\.isAccessibilitySize/,
  "the find surface must reflow for accessibility text sizes")
expect(rootView, /SystemDocumentPicker/, "the system Files entry point is required")
expect(rootView, /scenePhase/, "background checkpoint integration is required")
expect(rootView, /applicationDidBecomeActive/,
  "foreground activation must revalidate File Provider revisions")
expect(workflow, /xcodebuild analyze/,
  "Apple CI must run the Xcode static analyzer")
expect(workflow, /build-for-testing[\s\S]*LumenEditorIOS-DerivedData[\s\S]*test-without-building[\s\S]*only-testing:LumenEditorIOSUITests/,
  "Apple CI must reuse one explicit test build across iPhone and iPad")
expect(workflow, /LumenEditorIOS-ReleaseBuild\.xcresult[\s\S]*LumenEditorIOS-Analyze\.xcresult[\s\S]*LumenEditorIOS-TestBuild\.xcresult[\s\S]*LumenEditorIOS-Archive\.xcresult/,
  "Apple CI must retain structured build, analysis, test-build, and archive results")
expect(workflow, /test-timeouts-enabled YES[\s\S]*default-test-execution-time-allowance 90[\s\S]*maximum-test-execution-time-allowance 180/,
  "Apple CI must bound individual simulator test execution time")
expect(workflow, /simctl erase "\$iphone_id"[\s\S]*simctl erase "\$ipad_id"/,
  "Apple CI must erase both simulators before exercising isolated UI flows")
expect(workflow, /trap cleanup EXIT[\s\S]*trap cleanup EXIT/,
  "Apple CI must shut down both simulators even when tests fail")
expect(workflow, /Run isolated iPad UI flows[\s\S]*if: \$\{\{ !cancelled\(\)[\s\S]*Verify Release archive metadata without signing[\s\S]*if: \$\{\{ !cancelled\(\)/,
  "Apple CI must continue collecting iPad and archive evidence after an earlier failure")
expect(workflow, /xcodebuild -version[\s\S]*sw_vers[\s\S]*git rev-parse HEAD[\s\S]*simctl list devices available/,
  "Apple CI must capture toolchain, commit, and simulator metadata")
expect(workflow, /workflow run:[\s\S]*iOS runtime:[\s\S]*iPhone simulator:[\s\S]*iPad simulator:/,
  "Apple CI evidence must identify its workflow run and exact simulator runtime")
expect(workflow, /status=0[\s\S]*xcresulttool get test-results summary[\s\S]*python3 -m json\.tool[\s\S]*totalTestCount[\s\S]*core_tests[\s\S]*ui_tests[\s\S]*exit "\$status"[\s\S]*LumenEditorIOS-\*-summary\.json/,
  "Apple CI must validate and upload readable result-bundle summaries")
expect(workflow, /LumenEditorIOS-environment\.txt[\s\S]*native-ios-xcresult/,
  "Apple CI must upload its environment evidence with the Xcode results")
expect(workflow, /SWIFT_STRICT_CONCURRENCY=complete/g,
  "Apple CI must enforce complete Swift concurrency checking")
expect(workflow, /xcodebuild archive/,
  "Apple CI must produce an unsigned Release archive for metadata validation")
expect(workflow, /PrivacyInfo\.xcprivacy[\s\S]*Assets\.car[\s\S]*UIDeviceFamily\.0[\s\S]*UIDeviceFamily\.1/,
  "the archived app must be checked for privacy, assets, and universal device support")
expect(workflow, /grep -aFq 'LUMEN_UI_TEST_SESSION' "\$executable"[\s\S]*DEBUG-only UI-test environment key/,
  "the Release archive must prove that its executable cannot activate UI-test storage")

const forbidden = [
  [/import WebKit/, "WebKit must not be the primary iOS editor"],
  [/SwiftUI\.TextEditor|\bTextEditor\s*\(/, "SwiftUI.TextEditor must not replace the TextKit surface"],
  [/Process\s*\(/, "iOS must not launch local processes"],
  [/NSTask/, "iOS must not launch local tasks"],
  [/\?\?\s*\(?\s*(?:try|await)\b/,
    "try or await must cover the complete nil-coalescing expression"]
]
for (const path of await filesUnder(join(iosRoot, "Sources"), ".swift")) {
  const source = await readFile(path, "utf8")
  for (const [pattern, message] of forbidden) {
    if (pattern.test(source)) fail(`${message}: ${relative(root, path)}`)
  }
}

const stringKeyPatterns = [
  /String\(localized:\s*"([^"]+)"/g,
  /NSLocalizedString\("([^"]+)"/g
]
const usedKeys = new Set()
for (const path of await filesUnder(join(iosRoot, "Sources"), ".swift")) {
  const source = await readFile(path, "utf8")
  for (const pattern of stringKeyPatterns) {
    for (const match of source.matchAll(pattern)) usedKeys.add(match[1])
  }
}
const localeKeys = new Map()
for (const locale of ["en", "zh-Hans"]) {
  const strings = await readFile(join(iosRoot, `Resources/${locale}.lproj/Localizable.strings`), "utf8")
  const declared = [...strings.matchAll(/^"([^"]+)"\s*=/gm)].map((match) => match[1])
  const duplicates = declared.filter((key, index) => declared.indexOf(key) !== index)
  if (duplicates.length > 0) {
    fail(`${locale} localization has duplicate keys: ${[...new Set(duplicates)].join(", ")}`)
  }
  localeKeys.set(locale, new Set(declared))
  for (const key of usedKeys) {
    if (!new RegExp(`^"${key}"\\s*=`, "m").test(strings)) {
      fail(`${locale} localization is missing ${key}`)
    }
  }
}
const englishOnly = [...localeKeys.get("en")].filter(
  (key) => !localeKeys.get("zh-Hans").has(key)
)
const chineseOnly = [...localeKeys.get("zh-Hans")].filter(
  (key) => !localeKeys.get("en").has(key)
)
if (englishOnly.length > 0 || chineseOnly.length > 0) {
  fail(`locale key sets differ (en only: ${englishOnly.join(", ") || "none"}; ` +
    `zh-Hans only: ${chineseOnly.join(", ") || "none"})`)
}

const scripts = JSON.parse(packageJson).scripts
if (scripts["check:native-ios"] !== "node scripts/check-native-ios.mjs") {
  fail("package.json must expose check:native-ios")
}
if (!scripts.test.includes("check:native-ios")) {
  fail("npm test must include the iOS contract gate")
}

const coreTestSources = await filesUnder(
  join(iosRoot, "Tests/LumenEditorMobileCoreTests"), ".swift"
)
const coreTestCount = (await Promise.all(coreTestSources.map(async (path) =>
  [...(await readFile(path, "utf8")).matchAll(/^\s*func test\w*\s*\(/gm)].length
))).reduce((sum, count) => sum + count, 0)
const uiTestCount = [...uiTests.matchAll(/^\s*func test\w*\s*\(/gm)].length
if (coreTestCount < 48 || uiTestCount < 4) {
  fail(`test inventory regressed (Core: ${coreTestCount}, UI: ${uiTestCount})`)
}

console.log(`[native-ios] verified ${usedKeys.size} localized UI keys, ` +
  `${coreTestCount} Core tests, ${uiTestCount} UI tests, and the mobile safety contract`)
