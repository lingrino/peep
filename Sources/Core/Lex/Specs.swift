// Keyword tables and options for every language lexed by the shared C-family engine.
//
// Conventions for keyword groups:
//   K  = keyword            D = declares a function (next identifier = function name)
//   T  = declares a type     C = constant (true/false/nil)     B = builtin (self/this)
//   Y  = builtin type names (int, bool...; lowercase types the capitalization rule misses)
// Each spec is a lazily-built global (`static let`): only languages actually previewed pay.

private let K = TokenKind.keyword.rawValue
private let D = TokenKind.keyword.rawValue | KeywordTable.Hint.declaresFunction
private let T = TokenKind.keyword.rawValue | KeywordTable.Hint.declaresType
private let C = TokenKind.constant.rawValue
private let B = TokenKind.builtin.rawValue
private let Y = TokenKind.type.rawValue
private let P = TokenKind.preprocessor.rawValue

public enum Specs {
    public static let swift = CLikeSpec(keywords: KeywordTable([
        (K, "associatedtype deinit fileprivate import init inout internal let open operator private precedencegroup public rethrows static subscript var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws any some nonisolated isolated consuming borrowing sending package indirect lazy mutating nonmutating override required convenience dynamic final optional weak unowned get set willSet didSet macro each repeat discard copy consume"),
        (D, "func"),
        (T, "class struct enum protocol extension actor typealias"),
        (C, "true false nil"),
        (B, "self Self super"),
    ])) { s in
        s.nestedBlockComments = true
        s.singleQuote = .none
        s.backtick = .identifier
        s.tripleQuotes = true
        s.interpolation = .swift
        s.swiftRawStrings = true
        s.atAttribute = true
        s.hashPreprocessor = true   // #if / #available / #selector
        s.regexLiterals = false
    }

    static let cKeywords = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local alignas alignof constexpr static_assert thread_local typeof"
    static let cTypes = "void char short int long float double signed unsigned bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t wchar_t FILE"

    public static let c = CLikeSpec(keywords: KeywordTable([
        (K, cKeywords), (T, "struct"), (Y, cTypes), (C, "NULL true false nullptr"),
    ])) { s in s.hashPreprocessor = true; s.capitalizedTypes = false }

    public static let cpp = CLikeSpec(keywords: KeywordTable([
        (K, cKeywords + " catch co_await co_return co_yield concept consteval constinit const_cast decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept operator override private protected public reinterpret_cast requires static_cast template throw try typeid typename using virtual and or not xor and_eq or_eq not_eq bitand bitor compl import module"),
        (T, "class struct"), (Y, cTypes + " char8_t char16_t char32_t auto"),
        (C, "NULL true false nullptr"), (B, "this std"),
    ])) { s in s.hashPreprocessor = true; s.cppRawStrings = true; s.capitalizedTypes = false }

    public static let objc = CLikeSpec(keywords: KeywordTable([
        (K, cKeywords + " interface implementation end protocol property synthesize dynamic optional required class selector encode synchronized try catch finally throw autoreleasepool import package private public protected nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull __block __weak __strong instancetype in out inout oneway bycopy byref"),
        (T, "struct"), (Y, cTypes + " id BOOL SEL IMP Class NSInteger NSUInteger CGFloat"),
        (C, "NULL nil Nil YES NO true false"), (B, "self super"),
    ])) { s in s.hashPreprocessor = true; s.atKeywords = true }

    public static let csharp = CLikeSpec(keywords: KeywordTable([
        (K, "abstract as base break case catch checked const continue default delegate do else event explicit extern finally fixed for foreach goto if implicit in internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static switch throw try typeof unchecked unsafe using virtual volatile while add alias ascending async await by descending dynamic equals from get global group init into join let nameof notnull on orderby partial remove select set unmanaged value var when where with yield required scoped file"),
        (T, "class struct interface enum record"),
        (Y, "bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint"),
        (C, "true false null"), (B, "this"),
    ])) { s in s.hashPreprocessor = true; s.csharpStrings = true; s.tripleQuotes = true }

    public static let java = CLikeSpec(keywords: KeywordTable([
        (K, "abstract assert break case catch const continue default do else exports extends final finally for goto if implements import instanceof module native new non-sealed open opens package permits private protected provides public requires return sealed static strictfp super switch synchronized throw throws to transient transitive try uses var volatile when while with yield"),
        (T, "class interface enum record"),
        (Y, "boolean byte char double float int long short void"),
        (C, "true false null"), (B, "this super"),
    ])) { s in s.atAttribute = true; s.tripleQuotes = true }

    public static let kotlin = CLikeSpec(keywords: KeywordTable([
        (K, "as break continue do else for if in is return throw try catch finally when while by constructor delegate dynamic field file get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg package typealias val var value"),
        (D, "fun"), (T, "class interface object"),
        (C, "true false null"), (B, "this super it"),
    ])) { s in
        s.nestedBlockComments = true; s.atAttribute = true; s.tripleQuotes = true
        s.interpolation = .dollarBrace; s.dollarIdentInterp = true; s.backtick = .identifier
    }

    public static let scala = CLikeSpec(keywords: KeywordTable([
        (K, "abstract case catch do else extends final finally for forSome if implicit import lazy match new override package private protected return sealed throw try type val var while with yield given using export then end enum derives opaque inline transparent extension"),
        (D, "def"), (T, "class trait object"),
        (C, "true false null"), (B, "this super"),
    ])) { s in
        s.nestedBlockComments = true; s.atAttribute = true; s.tripleQuotes = true
        s.interpolation = .dollarBrace; s.dollarIdentInterp = true; s.backtick = .identifier
    }

    public static let groovy = CLikeSpec(keywords: KeywordTable([
        (K, "abstract as assert break case catch const continue default do else extends final finally for goto if implements import in instanceof native new package private protected public return static strictfp switch synchronized throw throws trait transient try var volatile while"),
        (D, "def"), (T, "class interface enum"),
        (Y, "boolean byte char double float int long short void"),
        (C, "true false null"), (B, "this super it"),
    ])) { s in
        s.atAttribute = true; s.tripleQuotes = true; s.singleQuote = .string
        s.interpolation = .dollarBrace; s.dollarIdentInterp = true; s.hashComment = false
    }

    public static let dart = CLikeSpec(keywords: KeywordTable([
        (K, "abstract as assert async await base break case catch const continue covariant default deferred do dynamic else export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync throw try typedef var when while with yield"),
        (T, "class enum"), (Y, "void int double num bool"),
        (C, "true false null"), (B, "this super"),
    ])) { s in
        s.atAttribute = true; s.tripleQuotes = true; s.singleQuote = .string
        s.interpolation = .dollarBrace; s.dollarIdentInterp = true
    }

    public static let go = CLikeSpec(keywords: KeywordTable([
        (K, "break case chan const continue default defer else fallthrough for go goto if import map package range return select switch var"),
        (D, "func"), (T, "type struct interface"),
        (Y, "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"),
        (C, "true false nil iota"),
        (B, "append cap clear close complex copy delete imag len make max min new panic print println real recover"),
    ])) { s in s.backtick = .raw; s.capitalizedTypes = false }

    public static let rust = CLikeSpec(keywords: KeywordTable([
        (K, "as async await break const continue crate dyn else extern for if impl in let loop match mod move mut pub ref return static unsafe use where while yield box macro_rules union"),
        (D, "fn"), (T, "struct enum trait type"),
        (Y, "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        (C, "true false None Some Ok Err"), (B, "self Self super"),
    ])) { s in
        s.nestedBlockComments = true; s.singleQuote = .rustLifetimeOrChar; s.multilineStrings = true
        s.rustStrings = true; s.hashAttribute = true; s.macroBang = true
    }

    public static let zig = CLikeSpec(keywords: KeywordTable([
        (K, "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else errdefer export extern for if inline linksection noalias noinline nosuspend or orelse packed pub resume return suspend switch test threadlocal try unreachable usingnamespace var volatile while"),
        (D, "fn"), (T, "struct enum union opaque error"),
        (Y, "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f80 f128 bool void noreturn type anyerror anyopaque comptime_int comptime_float c_int c_uint c_long c_ulong c_char"),
        (C, "true false null undefined"),
    ])) { s in s.slashStar = false; s.chars = ByteClass(extraStart: "@") }

    static let jsKeywords = "async await break case catch const continue debugger default delete do else export extends finally for from if import in instanceof let new of return static switch throw try typeof var void while with yield get set as"
    static let jsConstants = "true false null undefined NaN Infinity"

    public static let javascript = CLikeSpec(keywords: KeywordTable([
        (K, jsKeywords), (D, "function"), (T, "class"), (C, jsConstants), (B, "this super arguments globalThis"),
    ])) { s in
        s.singleQuote = .string; s.backtick = .template; s.regexLiterals = true
        s.chars = ByteClass(extraStart: "$"); s.atAttribute = true
    }

    public static let typescript = CLikeSpec(keywords: KeywordTable([
        (K, jsKeywords + " abstract asserts declare enum implements infer is keyof module namespace never override private protected public readonly require satisfies unique accessor out"),
        (D, "function"), (T, "class interface type enum"),
        (Y, "any boolean number string symbol bigint object unknown void never"),
        (C, jsConstants), (B, "this super arguments globalThis"),
    ])) { s in
        s.singleQuote = .string; s.backtick = .template; s.regexLiterals = true
        s.chars = ByteClass(extraStart: "$"); s.atAttribute = true
    }

    public static let python = CLikeSpec(keywords: KeywordTable([
        (K, "and as assert async await break continue del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case type"),
        (D, "def"), (T, "class"),
        (C, "True False None NotImplemented Ellipsis __debug__"),
        (B, "self cls print len range open int str float bool list dict set tuple object super isinstance hasattr getattr setattr enumerate zip map filter sorted reversed sum min max abs any all repr type iter next"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true
        s.singleQuote = .string; s.tripleQuotes = true; s.pythonPrefixes = true; s.atAttribute = true
    }

    public static let ruby = CLikeSpec(keywords: KeywordTable([
        (K, "alias and begin break case defined? do else elsif end ensure for if in next not or redo rescue retry return then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public raise loop lambda proc __method__"),
        (D, "def"), (T, "class module"),
        (C, "true false nil __FILE__ __LINE__ __dir__"), (B, "self super"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true
        s.singleQuote = .string; s.multilineStrings = true; s.interpolation = .hashBrace
        s.backtick = .command; s.atVariable = true; s.dollarVariable = true; s.symbols = true
        s.regexLiterals = true; s.chars = ByteClass(extraIdent: "?!")
    }

    public static let php = CLikeSpec(keywords: KeywordTable([
        (K, "abstract and array as break callable case catch clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach global goto if implements include include_once instanceof insteadof isset list match namespace new or print private protected public readonly require require_once return static switch throw try unset use var while xor yield"),
        (D, "function"), (T, "class interface trait"),
        (C, "true false null TRUE FALSE NULL"), (B, "this self parent"),
    ], caseInsensitive: false)) { s in
        s.hashComment = true; s.singleQuote = .string; s.multilineStrings = true
        s.dollarVariable = true; s.interpolation = .none; s.atAttribute = false
    }

    public static let perl = CLikeSpec(keywords: KeywordTable([
        (K, "my our local use no require package return if elsif else unless while until for foreach last next redo do eval die warn print printf say and or not xor eq ne lt gt le ge cmp qw qq q bless ref defined undef wantarray"),
        (D, "sub"), (B, "__PACKAGE__ __FILE__ __LINE__ STDIN STDOUT STDERR"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true
        s.singleQuote = .string; s.multilineStrings = true; s.dollarVariable = true
        s.backtick = .command; s.regexLiterals = true; s.capitalizedTypes = false
    }

    public static let lua = CLikeSpec(keywords: KeywordTable([
        (K, "and break do else elseif end for goto if in local not or repeat return then until while"),
        (D, "function"), (C, "true false nil"), (B, "self _G _ENV require print pairs ipairs type tostring tonumber"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.dashDashComment = true; s.luaLongBrackets = true
        s.singleQuote = .string; s.capitalizedTypes = false
    }

    public static let r = CLikeSpec(keywords: KeywordTable([
        (K, "if else repeat while for in next break return library require"),
        (D, "function"), (C, "TRUE FALSE NULL NA NaN Inf NA_integer_ NA_real_ NA_character_"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.singleQuote = .string
        s.multilineStrings = true; s.backtick = .identifier; s.capitalizedTypes = false
        s.chars = ByteClass(extraIdent: ".")
    }

    public static let julia = CLikeSpec(keywords: KeywordTable([
        (K, "baremodule begin break catch const continue do else elseif end export finally for global if import in isa let local macro module quote return try using where while"),
        (D, "function"), (T, "struct abstract primitive mutable"),
        (C, "true false nothing missing Inf NaN"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.tripleQuotes = true
        s.interpolation = .dollarBrace; s.dollarIdentInterp = true; s.atAttribute = true; s.singleQuote = .char
    }

    public static let sql = CLikeSpec(keywords: KeywordTable([
        (K, "add all alter and any as asc authorization backup begin between break by cascade case check checkpoint close clustered coalesce collate column commit compute constraint contains continue convert create cross current current_date current_time current_timestamp current_user cursor database deallocate declare default delete deny desc disk distinct distributed double drop dump else end errlvl escape except exec execute exists exit external fetch file fillfactor for foreign freetext from full function goto grant group having holdlock identity if in index inner insert intersect into is join key kill left like limit lineno load merge national natural nocheck nonclustered not null nullif of off offset offsets on open option or order outer over percent pivot plan primary print proc procedure public raiserror read readtext reconfigure references replace replication restore restrict return returning returns revert revoke right rollback rowcount rule save schema select session_user set setuser show shutdown some statistics table tablesample then to top tran transaction trigger truncate try_convert union unique unpivot update updatetext use user using values varying view waitfor when where while with within writetext window recursive lateral materialized temporary temp if exists returning conflict do nothing upsert pragma explain analyze vacuum"),
        (Y, "int integer smallint bigint tinyint decimal numeric float real double precision char varchar nchar nvarchar text ntext date time timestamp timestamptz datetime interval boolean bool blob bytea json jsonb uuid serial bigserial money xml array"),
        (C, "true false null"),
    ], caseInsensitive: true)) { s in
        s.slashSlash = false; s.dashDashComment = true; s.singleQuote = .string
        s.multilineStrings = true; s.backtick = .identifier; s.capitalizedTypes = false
    }

    public static let haskell = CLikeSpec(keywords: KeywordTable([
        (K, "case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where forall qualified as hiding family mdo rec proc"),
        (C, "True False Nothing Just Left Right"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.dashDashComment = true; s.haskellBlockComment = true
        s.singleQuote = .none; s.chars = ByteClass(extraIdent: "'")
    }

    public static let elm = CLikeSpec(keywords: KeywordTable([
        (K, "if then else case of let in type alias module exposing import as port effect where"),
        (C, "True False Nothing Just"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.dashDashComment = true; s.haskellBlockComment = true
        s.tripleQuotes = true; s.singleQuote = .char
    }

    public static let ocaml = CLikeSpec(keywords: KeywordTable([
        (K, "and as assert begin class constraint do done downto else end exception external for fun function functor if in include inherit initializer lazy let match method module mutable new nonrec object of open or private rec sig struct then to try type val virtual when while with"),
        (C, "true false None Some"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.ocamlBlockComment = true; s.singleQuote = .none
        s.multilineStrings = true; s.chars = ByteClass(extraIdent: "'")
    }

    public static let fsharp = CLikeSpec(keywords: KeywordTable([
        (K, "abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not of open or override private public rec return select sig static struct then to try type upcast use val void when while with yield"),
        (C, "true false null None Some"), (B, "this"),
    ])) { s in
        s.slashStar = false; s.ocamlBlockComment = true; s.tripleQuotes = true; s.singleQuote = .char
        s.atAttribute = false
    }

    public static let elixir = CLikeSpec(keywords: KeywordTable([
        (K, "after alias and case catch cond do else end fn for if import in not or quote raise receive require rescue super throw try unless unquote use when with"),
        (D, "def defp defmacro defmacrop defdelegate defguard defguardp"), (T, "defmodule defprotocol defimpl defstruct defexception"),
        (C, "true false nil"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.tripleQuotes = true
        s.singleQuote = .string; s.interpolation = .hashBrace; s.symbols = true; s.atAttribute = true
        s.multilineStrings = true; s.chars = ByteClass(extraIdent: "?!")
    }

    public static let erlang = CLikeSpec(keywords: KeywordTable([
        (K, "after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor module export import define record include behaviour spec type"),
        (C, "true false undefined ok error"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.percentComment = true; s.singleQuote = .string
        s.capitalizedTypes = false
    }

    public static let nix = CLikeSpec(keywords: KeywordTable([
        (K, "assert else if in inherit let or rec then with import"),
        (C, "true false null"), (B, "builtins"),
    ])) { s in
        s.slashSlash = false; s.hashComment = true; s.singleQuote = .none; s.multilineStrings = true
        s.interpolation = .dollarBrace; s.chars = ByteClass(extraIdent: "-'")
    }

    public static let hcl = CLikeSpec(keywords: KeywordTable([
        (K, "resource data variable output locals module provider terraform for in if else endif endfor dynamic content each count depends_on for_each lifecycle"),
        (C, "true false null"),
    ])) { s in
        s.hashComment = true; s.interpolation = .dollarBrace; s.multilineStrings = false
        s.capitalizedTypes = false; s.chars = ByteClass(extraIdent: "-")
    }

    public static let protobuf = CLikeSpec(keywords: KeywordTable([
        (K, "syntax edition import weak public package option optional repeated required reserved returns stream to max extend extensions oneof map rpc"),
        (T, "message enum service"),
        (Y, "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes"),
        (C, "true false"),
    ])) { s in s.singleQuote = .string }

    public static let graphql = CLikeSpec(keywords: KeywordTable([
        (K, "query mutation subscription fragment on implements schema extend directive repeatable"),
        (T, "type interface union enum input scalar"),
        (C, "true false null"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.tripleQuotes = true
        s.dollarVariable = true; s.atAttribute = true
    }

    public static let glsl = CLikeSpec(keywords: KeywordTable([
        (K, cKeywords + " attribute uniform varying layout centroid flat smooth noperspective patch sample subroutine in out inout invariant precise discard lowp mediump highp precision kernel vertex fragment device constant threadgroup thread using namespace"),
        (T, "struct"),
        (Y, cTypes + " vec2 vec3 vec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 bvec2 bvec3 bvec4 mat2 mat3 mat4 sampler2D samplerCube float2 float3 float4 half half2 half3 half4 float2x2 float3x3 float4x4 texture2d sampler"),
        (C, "true false"),
    ])) { s in s.hashPreprocessor = true; s.capitalizedTypes = false; s.atAttribute = false }

    public static let solidity = CLikeSpec(keywords: KeywordTable([
        (K, "abstract anonymous as assembly break catch constant continue constructor delete do else emit enum event external fallback for if immutable import indexed internal is library mapping memory modifier new override payable pragma private public pure receive return returns revert storage try type unchecked using view virtual while"),
        (D, "function"), (T, "contract interface struct"),
        (Y, "address bool string bytes int uint byte"), (C, "true false"), (B, "this msg block tx"),
    ])) { s in s.singleQuote = .string }

    public static let d = CLikeSpec(keywords: KeywordTable([
        (K, "abstract alias align asm assert auto body break case cast catch const continue debug default delegate deprecated do else enum export extern final finally for foreach foreach_reverse goto if immutable import in inout invariant is lazy mixin module new nothrow out override package pragma private protected public pure ref return scope shared static super switch synchronized template throw try typeid typeof unittest version while with"),
        (D, "function"), (T, "class struct interface union"),
        (Y, "bool byte ubyte short ushort int uint long ulong float double real char wchar dchar string void size_t"),
        (C, "true false null"), (B, "this"),
    ])) { s in s.nestedBlockComments = true; s.backtick = .raw }

    public static let nim = CLikeSpec(keywords: KeywordTable([
        (K, "addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out ptr raise ref return shl shr static template try tuple type using var when while xor yield"),
        (D, "proc func method iterator template macro converter"), (C, "true false nil"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.tripleQuotes = true; s.singleQuote = .char
    }

    public static let crystal = CLikeSpec(keywords: KeywordTable([
        (K, "abstract alias annotation as asm begin break case do else elsif end ensure enum extend for fun if in include instance_sizeof is_a? lib macro next of out pointerof private protected rescue return require select sizeof struct super then type typeof uninitialized union unless until when while with yield"),
        (D, "def"), (T, "class module"), (C, "true false nil"), (B, "self"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.interpolation = .hashBrace
        s.atVariable = true; s.symbols = true; s.chars = ByteClass(extraIdent: "?!")
    }

    public static let powershell = CLikeSpec(keywords: KeywordTable([
        (K, "begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from if in param process return switch throw trap try until using var while workflow"),
        (D, "function"), (C, "$true $false $null"),
    ], caseInsensitive: true)) { s in
        s.slashSlash = false; s.slashStar = false; s.hashComment = true; s.singleQuote = .string
        s.multilineStrings = true; s.dollarVariable = true; s.capitalizedTypes = false
        s.chars = ByteClass(extraIdent: "-")
    }

    public static let vim = CLikeSpec(keywords: KeywordTable([
        (K, "if else elseif endif for endfor while endwhile try catch finally endtry return let unlet call execute set setlocal autocmd augroup command map nmap vmap imap noremap nnoremap vnoremap inoremap source runtime syntax highlight hi filetype echo"),
        (D, "function function! def"),
    ])) { s in s.slashSlash = false; s.slashStar = false; s.singleQuote = .string; s.capitalizedTypes = false }

    public static let assembly = CLikeSpec(keywords: KeywordTable([
        (K, "mov add sub mul div inc dec cmp jmp je jne jz jnz jg jl call ret push pop lea and or xor not shl shr nop int ldr str stp ldp bl b cbz cbnz adrp br blr movz movk"),
    ], caseInsensitive: true)) { s in
        s.slashSlash = true; s.slashStar = true; s.semicolonComment = true; s.hashComment = false
        s.singleQuote = .char; s.capitalizedTypes = false; s.chars = ByteClass(extraStart: ".%")
    }

    public static let lisp = CLikeSpec(keywords: KeywordTable([
        (K, "defun defmacro defvar defparameter defconst defn defn- def defmethod defrecord defprotocol defstruct deftype defmulti ns let let* letfn lambda fn if when unless cond case do progn loop recur and or not quote setq setf require import use"),
        (C, "nil t true false"),
    ])) { s in
        s.slashSlash = false; s.slashStar = false; s.semicolonComment = true; s.singleQuote = .none
        s.multilineStrings = true; s.capitalizedTypes = false; s.symbols = true
        s.chars = ByteClass(extraIdent: "-*+!?<>=/'.", extraStart: "*+!?<>=")
    }

    public static let pascal = CLikeSpec(keywords: KeywordTable([
        (K, "and array as asm begin case class const constructor destructor div do downto else end except exports file finalization finally for function goto if implementation in inherited initialization inline interface is label library mod nil not object of or packed procedure program property raise record repeat resourcestring set shl shr string then threadvar to try type unit until uses var while with xor"),
        (C, "true false nil"),
    ], caseInsensitive: true)) { s in s.slashStar = false; s.ocamlBlockComment = true; s.singleQuote = .string }

    public static let fortran = CLikeSpec(keywords: KeywordTable([
        (K, "program end subroutine function module use implicit none integer real double precision complex logical character dimension allocatable intent in out inout parameter call do if then else elseif endif enddo return stop contains type select case where while"),
        (C, ".true. .false."),
    ], caseInsensitive: true)) { s in
        s.slashSlash = false; s.slashStar = false; s.singleQuote = .string; s.capitalizedTypes = false
    }

    /// Fallback for unknown "code-ish" files: strings, numbers and common comment styles.
    public static let generic = CLikeSpec(keywords: KeywordTable([(C, "true false null nil")])) { s in
        s.hashComment = true; s.singleQuote = .string; s.capitalizedTypes = false
    }
}
