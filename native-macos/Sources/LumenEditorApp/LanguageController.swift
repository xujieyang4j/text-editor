import Combine
import Foundation
import LumenEditorCore

/// One bounded, immutable entry in the native syntax-language catalog.
struct LanguageDefinition: Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let aliases: [String]
    let extensions: [String]
    let fileNames: [String]
    fileprivate let detectionPriority: Int

    var id: String { name }
    var isPlainText: Bool { name == LanguageCatalog.plainTextName }

    init(
        name: String,
        aliases: [String] = [],
        extensions: [String] = [],
        fileNames: [String] = [],
        detectionPriority: Int = .max
    ) {
        self.name = name
        self.aliases = aliases
        self.extensions = extensions
        self.fileNames = fileNames
        self.detectionPriority = detectionPriority
    }
}

/// A defensive, finite catalog used by detection and by the language palette.
/// The built-in entries mirror CodeMirror's language-data names, while the
/// limits also make custom/test catalogs safe to search on every keystroke.
struct LanguageCatalog: Equatable, Sendable {
    static let plainTextName = "Plain Text"
    static let maximumLanguageCount = 192
    static let maximumLanguageNameUTF16Count = 100
    static let maximumAliasesPerLanguage = 16
    static let maximumExtensionsPerLanguage = 32
    static let maximumTokenUTF16Count = 64
    static let maximumSearchResults = 192
    private static let maximumTokenCandidates = 128

    let languages: [LanguageDefinition]

    init(languages requestedLanguages: [LanguageDefinition]) {
        var seen = Set<String>()
        var accepted: [LanguageDefinition] = []
        accepted.reserveCapacity(min(Self.maximumLanguageCount, requestedLanguages.count + 1))

        func append(_ raw: LanguageDefinition, detectionPriority: Int) {
            guard accepted.count < Self.maximumLanguageCount,
                  let name = Self.validName(raw.name) else { return }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return }
            accepted.append(LanguageDefinition(
                name: name,
                aliases: Self.validTokens(
                    raw.aliases, maximumCount: Self.maximumAliasesPerLanguage
                ),
                extensions: Self.validTokens(
                    raw.extensions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) },
                    maximumCount: Self.maximumExtensionsPerLanguage
                ),
                fileNames: Self.validTokens(
                    raw.fileNames, maximumCount: Self.maximumExtensionsPerLanguage
                ),
                detectionPriority: detectionPriority
            ))
        }

        append(
            LanguageDefinition(name: Self.plainTextName, aliases: ["text", "plaintext"]),
            detectionPriority: -1
        )
        for (index, language) in requestedLanguages.enumerated() {
            guard accepted.count < Self.maximumLanguageCount else { break }
            guard language.name.caseInsensitiveCompare(Self.plainTextName) != .orderedSame else {
                continue
            }
            append(language, detectionPriority: index)
        }

        let plain = accepted.removeFirst()
        languages = [plain] + accepted.sorted {
            let left = $0.name.lowercased()
            let right = $1.name.lowercased()
            return left == right ? $0.name < $1.name : left < right
        }
    }

    var plainText: LanguageDefinition { languages[0] }

    func language(named requestedName: String) -> LanguageDefinition? {
        let key = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf16.count <= Self.maximumLanguageNameUTF16Count else {
            return nil
        }
        if let exactName = languages.first(where: {
            $0.name.caseInsensitiveCompare(key) == .orderedSame
        }) {
            return exactName
        }
        return languages.first { language in
            language.aliases.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    /// Exact special filenames win; extension matching is case-insensitive and
    /// supports compound suffixes such as `.cmake.in`. Unknown names are text.
    func detect(fileName rawFileName: String?) -> LanguageDefinition {
        guard let rawFileName, !rawFileName.isEmpty else { return plainText }
        let fileName = (rawFileName as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName.utf16.count <= 1_024 else { return plainText }
        let folded = fileName.lowercased()

        if folded.hasPrefix("nginx"), folded.hasSuffix(".conf"),
           let nginx = language(named: "Nginx") {
            return nginx
        }
        // Detection follows source-catalog order instead of palette order.
        // This deliberately preserves CodeMirror's precedence for ambiguous
        // extensions such as .m, .v, and .sig.
        let detectionOrder = languages.sorted {
            $0.detectionPriority < $1.detectionPriority
        }
        if let exact = detectionOrder.first(where: { language in
            language.fileNames.contains { $0.caseInsensitiveCompare(fileName) == .orderedSame }
        }) {
            return exact
        }
        return detectionOrder.first(where: { language in
            language.extensions.contains { extensionName in
                folded.hasSuffix("." + extensionName.lowercased())
            }
        }) ?? plainText
    }

    func detect(url: URL?) -> LanguageDefinition {
        detect(fileName: url?.lastPathComponent)
    }

    func search(
        _ rawQuery: String,
        limit requestedLimit: Int = maximumSearchResults
    ) -> [(language: LanguageDefinition, match: NavigationFuzzyMatch)] {
        let query = Self.boundedPrefix(rawQuery, maximumUTF16Count: 256)
        let limit = min(Self.maximumSearchResults, max(0, requestedLimit))
        guard limit > 0 else { return [] }
        guard !query.isEmpty else {
            return languages.prefix(limit).map {
                ($0, NavigationFuzzyMatch(score: 1, matches: []))
            }
        }
        let ranked = languages.enumerated().compactMap { index, language
            -> (index: Int, language: LanguageDefinition, match: NavigationFuzzyMatch)? in
            var best = NavigationFuzzyMatcher.score(query: query, text: language.name)
            for alias in language.aliases {
                guard let aliasMatch = NavigationFuzzyMatcher.score(query: query, text: alias),
                      best == nil || aliasMatch.score > best!.score else { continue }
                // Alias offsets cannot highlight a differently-shaped display
                // name safely, but the score still makes aliases searchable.
                best = NavigationFuzzyMatch(score: aliasMatch.score, matches: [])
            }
            if language.aliases.contains(where: {
                $0.caseInsensitiveCompare(query) == .orderedSame
            }) {
                best = NavigationFuzzyMatch(score: 1_000_000, matches: [])
            }
            return best.map { (index, language, $0) }
        }.sorted { left, right in
            left.match.score == right.match.score
                ? left.index < right.index
                : left.match.score > right.match.score
        }
        return ranked.prefix(limit).map { ($0.language, $0.match) }
    }

    static let builtIn: LanguageCatalog = {
        let aliases: [String: [String]] = [
            "C++": ["cpp"], "C#": ["csharp", "cs"],
            "CoffeeScript": ["coffee"], "Common Lisp": ["lisp"],
            "F#": ["fsharp"], "JavaScript": ["js", "ecmascript", "node"],
            "JSON-LD": ["jsonld"], "Objective-C": ["objc"],
            "Objective-C++": ["objc++"], "Properties files": ["ini"],
            "ProtoBuf": ["protobuf"], "Shell": ["sh", "bash", "zsh"],
            "TypeScript": ["ts"], "YAML": ["yml"]
        ]
        let specialNames: [String: [String]] = [
            "Asterisk": ["extensions.conf"],
            "CMake": ["CMakeLists.txt"],
            "Dockerfile": ["Dockerfile"],
            "Groovy": ["Jenkinsfile"],
            "Python": ["BUCK", "BUILD"],
            "Ruby": ["Gemfile", "Rakefile"],
            "Shell": ["PKGBUILD"]
        ]
        let records = Self.builtInRecords.split(separator: "\n").compactMap { line
            -> LanguageDefinition? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard let first = fields.first else { return nil }
            let name = String(first)
            let extensions = fields.count > 1 ? fields[1].split(separator: ",").map(String.init) : []
            return LanguageDefinition(
                name: name, aliases: aliases[name] ?? [],
                extensions: extensions, fileNames: specialNames[name] ?? []
            )
        }
        return LanguageCatalog(languages: records)
    }()

    private static let builtInRecords = """
    C|c,h,ino
    C++|cpp,c++,cc,cxx,hpp,h++,hh,hxx
    CQL|cql
    CSS|css
    Go|go
    HTML|html,htm,handlebars,hbs
    Java|java
    JavaScript|js,mjs,cjs
    Jinja|j2,jinja,jinja2
    JSON|json,map,jsonc,geojson,har
    JSX|jsx
    LESS|less
    Liquid|liquid
    MariaDB SQL|
    Markdown|md,markdown,mkd,mdown,mkdn,mdx
    MS SQL|
    MySQL|
    PHP|php,php3,php4,php5,php7,phtml
    PLSQL|pls
    PostgreSQL|
    Python|bzl,py,pyw
    Rust|rs
    Sass|sass
    SCSS|scss
    SQL|sql
    SQLite|
    TSX|tsx
    TypeScript|ts,mts,cts
    WebAssembly|wat,wast
    XML|xml,xsl,xsd,svg
    YAML|yaml,yml
    APL|dyalog,apl
    PGP|asc,pgp,sig
    ASN.1|asn,asn1
    Asterisk|
    Brainfuck|b,bf
    Cobol|cob,cpy
    C#|cs
    Clojure|clj,cljc,cljx
    ClojureScript|cljs
    Closure Stylesheets (GSS)|gss
    CMake|cmake,cmake.in
    CoffeeScript|coffee
    Common Lisp|cl,lisp,el
    Cypher|cyp,cypher
    Cython|pyx,pxd,pxi
    Crystal|cr
    D|d
    Dart|dart
    diff|diff,patch
    Dockerfile|
    DTD|dtd
    Dylan|dylan,dyl,intr
    EBNF|
    ECL|ecl
    edn|edn
    Eiffel|e
    Elm|elm
    Erlang|erl
    Esper|
    Factor|factor
    FCL|
    Forth|forth,fth,4th
    Fortran|f,for,f77,f90,f95
    F#|fs
    Gas|s
    Gherkin|feature
    Groovy|groovy,gradle
    Haskell|hs
    Haxe|hx
    HXML|hxml
    HTTP|
    IDL|pro
    JSON-LD|jsonld
    Julia|jl
    Kotlin|kt,kts
    LiveScript|ls
    Lua|lua
    mIRC|mrc
    Mathematica|m,nb,wl,wls
    Modelica|mo
    MUMPS|mps
    Mbox|mbox
    Nginx|
    NSIS|nsh,nsi
    NTriples|nt,nq
    Objective-C|m
    Objective-C++|mm
    OCaml|ml,mli,mll,mly
    Octave|m
    Oz|oz
    Pascal|p,pas
    Perl|pl,pm
    Pig|pig
    PowerShell|ps1,psd1,psm1
    Properties files|properties,ini,in
    ProtoBuf|proto
    Pug|pug,jade
    Puppet|pp
    Q|q
    R|r
    RPM Changes|
    RPM Spec|spec
    Ruby|rb
    SAS|sas
    Scala|scala
    Scheme|scm,ss
    Shell|sh,ksh,bash
    Sieve|siv,sieve
    Smalltalk|st
    Solr|
    SML|sml,sig,fun,smackspec
    SPARQL|rq,sparql
    Spreadsheet|
    Squirrel|nut
    Stylus|styl
    Swift|swift
    sTeX|
    LaTeX|text,ltx,tex
    SystemVerilog|v,sv,svh
    Tcl|tcl
    Textile|textile
    TiddlyWiki|
    Tiki wiki|
    TOML|toml
    Troff|1,2,3,4,5,6,7,8,9
    TTCN|ttcn,ttcn3,ttcnpp
    TTCN_CFG|cfg
    Turtle|ttl
    Web IDL|webidl
    VB.NET|vb
    VBScript|vbs
    Velocity|vtl
    Verilog|v
    VHDL|vhd,vhdl
    XQuery|xy,xquery,xq,xqm,xqy
    Yacas|ys
    Z80|z80
    MscGen|mscgen,mscin,msc
    Xù|xu
    MsGenny|msgenny
    Vue|vue
    Angular Template|
    """

    private static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= maximumLanguageNameUTF16Count,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return name
    }

    private static func validTokens(_ raw: [String], maximumCount: Int) -> [String] {
        var seen = Set<String>()
        var accepted: [String] = []
        accepted.reserveCapacity(min(maximumCount, raw.count))
        for token in raw.prefix(maximumTokenCandidates) {
            guard accepted.count < maximumCount else { break }
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.lowercased()
            guard !value.isEmpty, value.utf16.count <= maximumTokenUTF16Count,
                  !value.contains("/"), !value.contains("\\"),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(key).inserted else { continue }
            accepted.append(value)
        }
        return accepted
    }

    fileprivate static func boundedPrefix(
        _ value: String, maximumUTF16Count: Int
    ) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var result = ""
        result.reserveCapacity(maximumUTF16Count)
        var count = 0
        for character in value {
            let width = String(character).utf16.count
            guard count + width <= maximumUTF16Count else { break }
            result.append(character)
            count += width
        }
        return result
    }
}

struct LanguagePaletteItem: Identifiable, Equatable, Sendable {
    let language: LanguageDefinition
    let match: NavigationFuzzyMatch
    let isCurrent: Bool

    var id: String { language.id }
    var name: String { language.name }
    var matchedUTF16Offsets: [Int] { match.matches }
}

/// Native state owner for `select-language`. It captures the active document
/// when presented and revalidates that identity before accepting a row.
@MainActor
final class LanguageController: ObservableObject {
    typealias ActiveDocument = @MainActor () -> EditorDocument?
    typealias ApplyLanguage = @MainActor (EditorDocument, String) -> Bool
    typealias RefreshAutomaticLanguage = @MainActor (EditorDocument) -> Bool
    typealias PresentationAction = @MainActor () -> Void

    static let commandIDs = ["select-language"]
    static let maximumQueryUTF16Count = 256

    @Published var query: String {
        didSet {
            let bounded = LanguageCatalog.boundedPrefix(
                query, maximumUTF16Count: Self.maximumQueryUTF16Count
            )
            if bounded != query {
                query = bounded
            }
            guard query != oldValue else { return }
            reloadItems(preservingSelectionID: selectedItem?.id)
        }
    }
    @Published private(set) var items: [LanguagePaletteItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isPresented = false
    @Published private(set) var presentedDocumentID: String?

    let catalog: LanguageCatalog
    private let activeDocument: ActiveDocument
    private let applyLanguage: ApplyLanguage
    private let refreshAutomatic: RefreshAutomaticLanguage
    init(
        model: AppModel,
        catalog: LanguageCatalog = .builtIn
    ) {
        self.catalog = catalog
        query = ""
        activeDocument = { [weak model] in model?.selectedDocument }
        applyLanguage = { [weak model] document, language in
            model?.selectLanguage(language, for: document, using: catalog) == true
        }
        refreshAutomatic = { [weak model] document in
            model?.refreshAutomaticLanguage(for: document, using: catalog) == true
        }
    }

    init(
        catalog: LanguageCatalog = .builtIn,
        activeDocument: @escaping ActiveDocument,
        applyLanguage: @escaping ApplyLanguage,
        refreshAutomaticLanguage: RefreshAutomaticLanguage? = nil
    ) {
        self.catalog = catalog
        query = ""
        self.activeDocument = activeDocument
        self.applyLanguage = applyLanguage
        refreshAutomatic = refreshAutomaticLanguage ?? { document in
            document.refreshAutomaticLanguage(using: catalog)
        }
    }

    var selectedItem: LanguagePaletteItem? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var currentLanguageName: String? {
        guard let document = activeDocument(),
              !isPresented || document.sessionDocumentID == presentedDocumentID else {
            return nil
        }
        return document.language
    }

    @discardableResult
    func present(query initialQuery: String = "") -> Bool {
        guard let document = activeDocument() else { return false }
        presentedDocumentID = document.sessionDocumentID
        isPresented = true
        query = LanguageCatalog.boundedPrefix(
            initialQuery, maximumUTF16Count: Self.maximumQueryUTF16Count
        )
        reloadItems()
        return true
    }

    func dismiss() {
        isPresented = false
        presentedDocumentID = nil
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? 0
        selectedIndex = ((current + delta) % items.count + items.count) % items.count
    }

    func moveSelection(_ delta: Int) { moveSelection(by: delta) }

    @discardableResult
    func acceptSelection() -> Bool {
        guard let item = selectedItem, selectLanguage(item.language.name) else { return false }
        dismiss()
        return true
    }

    @discardableResult
    func acceptItem(at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        selectedIndex = index
        return acceptSelection()
    }

    /// Selects only catalog-owned values. Any non-Plain-Text selection locks
    /// the document; Plain Text deliberately selects an unlocked plain-text
    /// mode until the next explicit automatic refresh or filename transition.
    @discardableResult
    func selectLanguage(_ requestedName: String) -> Bool {
        guard let language = catalog.language(named: requestedName),
              let document = activeDocument(),
              !isPresented || document.sessionDocumentID == presentedDocumentID else {
            return false
        }
        guard applyLanguage(document, language.name) else { return false }
        reloadItems(preservingSelectionID: language.id)
        return true
    }

    @discardableResult
    func refreshAutomaticLanguage(for document: EditorDocument? = nil) -> Bool {
        guard let document = document ?? activeDocument() else { return false }
        let changed = refreshAutomatic(document)
        if isPresented, document.sessionDocumentID == presentedDocumentID { reloadItems() }
        return changed
    }

    /// Installs the catalog route. The shell can either provide presentation
    /// callbacks in the initializer or invoke its panel action here.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        presentPalette: PresentationAction? = nil
    ) throws -> [CommandHandlerToken] {
        let token = try router.register(
            "select-language", replaceExisting: replaceExisting,
            enablement: { [weak self] context in
                guard let self else {
                    return .disabled(reason: "Language selection unavailable")
                }
                guard context.availableRequirements.contains(.document),
                      self.activeDocument() != nil else {
                    return .disabled(reason: "No active document")
                }
                return .enabled
            }
        ) { [weak self] _ in
            await prepareForCommand()
            guard let self else {
                throw CommandHandlerSignal.unavailable(
                    reason: "Language selection unavailable"
                )
            }
            guard self.present() else { throw CommandHandlerSignal.noChange }
            presentPalette?()
        }
        return [token]
    }

    private func reloadItems(preservingSelectionID preferredID: String? = nil) {
        guard isPresented else {
            items = []
            selectedIndex = nil
            return
        }
        let active = activeDocument()
        let currentName = active?.sessionDocumentID == presentedDocumentID
            ? active?.language : nil
        items = catalog.search(query).map { result in
            LanguagePaletteItem(
                language: result.language, match: result.match,
                isCurrent: result.language.name == currentName
            )
        }
        if let preferredID, let index = items.firstIndex(where: { $0.id == preferredID }) {
            selectedIndex = index
        } else if let currentName, let index = items.firstIndex(where: { $0.name == currentName }) {
            selectedIndex = index
        } else {
            selectedIndex = items.isEmpty ? nil : 0
        }
    }
}
