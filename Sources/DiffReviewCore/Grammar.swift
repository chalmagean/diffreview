import Foundation

/// What the highlighter knows about one language.
struct Grammar: Sendable {
    struct Pair: Sendable {
        var open: [UInt16]
        var close: [UInt16]
    }

    struct StringRule: Sendable {
        var delimiter: [UInt16]
        var escapes = true
        /// Stays open across lines until closed.
        var multiline = false
        /// Rust's `'x'`: exactly one character, so `'a` (a lifetime) isn't a string.
        var charLiteral = false
    }

    var keywords: Set<String> = []
    var constants: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[UInt16]] = []
    /// Checked before line comments, so Lua's `--[[` wins over `--`.
    var blockComments: [Pair] = []
    /// Checked in order: put `"""` before `"`.
    var strings: [StringRule] = []
    /// A character that, directly before a name, makes it one token of this kind (`@ivar`, `$var`, `#include`).
    var sigils: [UInt16: SyntaxKind] = [:]
    /// Capitalized names are types (most languages name types that way).
    var capitalizedTypes = true
    /// A name followed by `(` is a call.
    var calls = true
    /// `<tag` names are tags.
    var markup = false
    /// `#` starts a comment only at the start of a word (shells: `${#x}`, `a#b`).
    var hashNeedsSpace = false
    /// Names may end in `?` or `!` (Ruby).
    var wordSuffixes = false
    var dollarInIdentifiers = false
    var dashInIdentifiers = false
    /// A name or string followed by one of these is a key (`"a":`, `key =`).
    var keyDelimiters: Set<UInt16> = []
    /// A colon makes a key only before a space or the line end (YAML, CSS: not `a:hover`).
    var keyColonNeedsSpace = false

    static func forLanguage(_ language: String) -> Grammar? {
        switch language {
        case "swift": return swift
        case "ruby": return ruby
        case "python": return python
        case "javascript", "jsx": return javascript
        case "typescript", "tsx": return typescript
        case "go": return go
        case "rust": return rust
        case "c", "cpp", "objectivec": return c
        case "java", "kotlin", "groovy", "scala", "dart": return java
        case "csharp": return csharp
        case "php": return php
        case "bash", "zsh", "fish", "makefile", "dockerfile": return shell
        case "json": return json
        case "yaml": return yaml
        case "toml", "hcl": return toml
        case "html", "xml", "erb", "vue", "svelte": return html
        case "css", "scss", "sass": return css
        case "sql": return sql
        case "elixir": return elixir
        case "lua": return lua
        case "haskell": return haskell
        case "perl", "r": return scripting
        default: return nil
        }
    }

    // MARK: - Building blocks

    private static func u(_ s: String) -> [UInt16] { Array(s.utf16) }
    private static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: \.isWhitespace).map(String.init))
    }
    private static func pair(_ open: String, _ close: String) -> Pair { Pair(open: u(open), close: u(close)) }
    private static func str(_ d: String, escapes: Bool = true, multiline: Bool = false) -> StringRule {
        StringRule(delimiter: u(d), escapes: escapes, multiline: multiline)
    }

    private static let at = UInt16(UInt8(ascii: "@"))
    private static let dollar = UInt16(UInt8(ascii: "$"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let equals = UInt16(UInt8(ascii: "="))

    private static let cComments: (line: [[UInt16]], block: [Pair]) = ([u("//")], [pair("/*", "*/")])
    private static let quotes = [str("\""), str("'")]

    // MARK: - Languages

    static let swift = Grammar(
        keywords: words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open
            operator private precedencegroup protocol public rethrows static struct subscript typealias var
            break case catch continue default defer do else fallthrough for guard if in repeat return throw
            switch where while as is try await async throws some any super self Self get set willSet didSet
            mutating nonmutating override final lazy weak unowned required convenience indirect nonisolated
            isolated consuming borrowing macro package
            """),
        constants: words("true false nil"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("\"\"\"", multiline: true), str("\"")],
        sigils: [at: .function, hash: .keyword])

    static let ruby = Grammar(
        keywords: words("""
            alias and begin break case class def defined? do else elsif end ensure for if in module next not
            or redo rescue retry return self super then undef unless until when while yield require
            require_relative attr_reader attr_writer attr_accessor private protected public include extend
            raise lambda proc loop new
            """),
        constants: words("true false nil __FILE__ __LINE__"),
        lineComments: [u("#")],
        blockComments: [pair("=begin", "=end")],
        strings: quotes + [str("`")],
        sigils: [at: .constant, colon: .constant, dollar: .constant],
        wordSuffixes: true)

    static let python = Grammar(
        keywords: words("""
            and as assert async await break class continue def del elif else except finally for from global
            if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
            """),
        constants: words("True False None"),
        types: words("int float str bool list dict set tuple bytes object type"),
        lineComments: [u("#")],
        strings: [str("\"\"\"", multiline: true), str("'''", multiline: true)] + quotes,
        sigils: [at: .function])

    static let javascript = Grammar(
        keywords: words("""
            async await break case catch class const continue debugger default delete do else export extends
            finally for from function if import in instanceof let new of return static super switch this throw
            try typeof var void while with yield get set
            """),
        constants: words("true false null undefined NaN Infinity"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("`", multiline: true)] + quotes,
        sigils: [at: .function],
        dollarInIdentifiers: true)

    static let typescript: Grammar = {
        var g = javascript
        g.keywords.formUnion(words("""
            interface type enum implements namespace declare abstract private protected public readonly as
            keyof infer is satisfies module override
            """))
        g.types = words("string number boolean any unknown never void object symbol bigint")
        return g
    }()

    static let go = Grammar(
        keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface
            map package range return select struct switch type var
            """),
        constants: words("true false nil iota"),
        types: words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint
            uint8 uint16 uint32 uint64 uintptr any
            """),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("`", escapes: false, multiline: true), str("\""), str("'")],
        capitalizedTypes: false)

    static let rust = Grammar(
        keywords: words("""
            as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod
            move mut pub ref return self Self static struct super trait type unsafe use where while macro_rules
            """),
        constants: words("true false None Some Ok Err"),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("\""), StringRule(delimiter: u("'"), charLiteral: true)],
        sigils: [hash: .function])

    static let c = Grammar(
        keywords: words("""
            auto break case char const continue default do double else enum extern float for goto if inline int
            long register restrict return short signed sizeof static struct switch typedef union unsigned void
            volatile while class namespace template typename public private protected virtual override final
            new delete this throw try catch using constexpr nullptr operator friend explicit mutable noexcept
            static_cast dynamic_cast reinterpret_cast const_cast bool auto self super id instancetype
            @interface @implementation @end @property @protocol @selector
            """),
        constants: words("true false NULL nullptr nil YES NO"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: quotes,
        sigils: [hash: .keyword, at: .keyword])

    static let java = Grammar(
        keywords: words("""
            abstract assert break case catch class const continue default do else enum extends final finally
            for goto if implements import instanceof interface native new package private protected public
            return static strictfp super switch synchronized this throw throws transient try volatile while var
            val fun object when is in out companion data sealed open internal override lateinit by init
            typealias suspend inline reified def trait extends with yield late required
            """),
        constants: words("true false null"),
        types: words("int long short byte char boolean float double void"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("\"\"\"", multiline: true)] + quotes,
        sigils: [at: .function])

    static let csharp = Grammar(
        keywords: words("""
            abstract as base break case catch checked class const continue default delegate do else enum event
            explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace
            new operator out override params private protected public readonly ref return sealed sizeof
            stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while
            async await var get set init record yield where
            """),
        constants: words("true false null"),
        types: words("int long short byte char bool float double decimal void string object uint ulong"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: quotes)

    static let php = Grammar(
        keywords: words("""
            abstract and array as break callable case catch class clone const continue declare default do echo
            else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for
            foreach function global goto if implements include include_once instanceof insteadof interface
            isset list match namespace new or print private protected public readonly require require_once
            return static switch throw trait try unset use var while yield
            """),
        constants: words("true false null TRUE FALSE NULL"),
        lineComments: [u("//"), u("#")], blockComments: cComments.block,
        strings: quotes,
        sigils: [dollar: .constant])

    static let shell = Grammar(
        keywords: words("""
            if then else elif fi case esac for while until do done in function return select time export local
            readonly declare unset set source alias exit break continue shift trap eval exec end
            FROM RUN CMD ENTRYPOINT COPY ADD ENV ARG WORKDIR EXPOSE VOLUME USER LABEL
            """),
        constants: words("true false"),
        lineComments: [u("#")],
        strings: quotes + [str("`")],
        sigils: [dollar: .constant],
        capitalizedTypes: false, calls: false,
        hashNeedsSpace: true,
        dashInIdentifiers: true)

    static let json = Grammar(
        constants: words("true false null"),
        lineComments: cComments.line, blockComments: cComments.block,
        strings: [str("\"")],
        capitalizedTypes: false, calls: false,
        keyDelimiters: [colon])

    static let yaml = Grammar(
        constants: words("true false null yes no on off True False Null ~"),
        lineComments: [u("#")],
        strings: quotes,
        sigils: [UInt16(UInt8(ascii: "&")): .constant, UInt16(UInt8(ascii: "*")): .constant],
        capitalizedTypes: false, calls: false,
        hashNeedsSpace: true,
        dashInIdentifiers: true,
        keyDelimiters: [colon], keyColonNeedsSpace: true)

    static let toml = Grammar(
        keywords: words("resource variable output module provider data locals terraform"),
        constants: words("true false null"),
        lineComments: [u("#"), u("//")], blockComments: cComments.block,
        strings: [str("\"\"\"", multiline: true), str("'''", escapes: false, multiline: true)] + quotes,
        capitalizedTypes: false, calls: false,
        dashInIdentifiers: true,
        keyDelimiters: [equals])

    static let html = Grammar(
        blockComments: [pair("<!--", "-->"), pair("<%#", "%>")],
        strings: [str("\"", escapes: false), str("'", escapes: false)],
        capitalizedTypes: false, calls: false,
        markup: true,
        dashInIdentifiers: true)

    static let css = Grammar(
        keywords: words("!important"),
        lineComments: [u("//")], blockComments: cComments.block,
        strings: quotes,
        sigils: [at: .keyword, dollar: .constant, hash: .constant],
        capitalizedTypes: false, calls: true,
        dashInIdentifiers: true,
        keyDelimiters: [colon], keyColonNeedsSpace: true)

    static let sql: Grammar = {
        let list = """
            select from where and or not insert into values update set delete create table drop alter add
            column index primary key foreign references join left right inner outer full on as group by order
            having limit offset union all distinct case when then else end is null like in between exists
            default constraint unique view returning with begin commit rollback transaction asc desc if
            """
        // SQL is written in either case.
        let keywords = words(list)
        return Grammar(
            keywords: keywords.union(keywords.map { $0.uppercased() }),
            constants: words("true false TRUE FALSE NULL"),
            types: words("""
                int integer bigint smallint text varchar char boolean date timestamp numeric decimal real
                serial uuid jsonb json INT INTEGER BIGINT TEXT VARCHAR BOOLEAN DATE TIMESTAMP NUMERIC UUID
                """),
            lineComments: [u("--")], blockComments: cComments.block,
            strings: [str("'"), str("\"")],
            capitalizedTypes: false)
    }()

    static let elixir = Grammar(
        keywords: words("""
            def defp defmodule defstruct defmacro defimpl defprotocol do end if else unless case cond with fn
            for when and or not in import alias require use quote unquote receive after try catch rescue raise
            """),
        constants: words("true false nil"),
        lineComments: [u("#")],
        strings: [str("\"\"\"", multiline: true), str("\""), str("'")],
        sigils: [at: .constant, colon: .constant],
        wordSuffixes: true)

    static let lua = Grammar(
        keywords: words("""
            and break do else elseif end for function goto if in local not or repeat return then until while
            """),
        constants: words("true false nil"),
        lineComments: [u("--")], blockComments: [pair("--[[", "]]")],
        strings: [str("[[", escapes: false, multiline: true)] + quotes)

    static let haskell = Grammar(
        keywords: words("""
            case class data default deriving do else if import in infix infixl infixr instance let module
            newtype of then type where
            """),
        constants: words("True False Nothing Just"),
        lineComments: [u("--")], blockComments: [pair("{-", "-}")],
        strings: [str("\"")],
        calls: false)

    /// Perl, R: just comments, strings and numbers, plus common keywords.
    static let scripting = Grammar(
        keywords: words("if else elsif for foreach while return function sub my our use library next last"),
        constants: words("TRUE FALSE NULL NA"),
        lineComments: [u("#")],
        strings: quotes,
        sigils: [dollar: .constant, at: .constant])
}
