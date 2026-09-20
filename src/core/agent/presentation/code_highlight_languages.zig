const std = @import("std");

const Allocator = std.mem.Allocator;

pub const KeywordCase = enum(u1) {
    sensitive,
    ascii_insensitive,
};

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
};

const Detection = enum(u4) {
    none,
    typescript_assertion,
    json,
    shell_shebang,
    python_header,
    sql_select,
    dockerfile_from,
    go_package,
    rust_function,
    diff_patch,
};

const LineComments = enum(u3) {
    none,
    slash,
    hash,
    dash,
    slash_hash,
    hash_slash,
    hash_semicolon,
};

const BlockComments = enum(u3) {
    none,
    slash_star,
    html,
    powershell,
    lua,
    haskell,
};

const Quotes = enum(u3) {
    none,
    double,
    double_single,
    shell,
    double_backtick,
    backtick,
};

const Settings = packed struct(u32) {
    line_comments: LineComments = .none,
    block_comment: BlockComments = .none,
    quotes: Quotes = .none,
    shell_operators: bool = false,
    dollar_vars: bool = false,
    dash_flags: bool = false,
    command_words: bool = false,
    bare_numbers: bool = true,
    diff_lines: bool = false,
    keyword_case: KeywordCase = .sensitive,
    detection: Detection = .none,
    _padding: u12 = 0,
};

const line_comment_sets = [_][]const []const u8{
    &.{},
    &.{"//"},
    &.{"#"},
    &.{"--"},
    &.{ "//", "#" },
    &.{ "#", "//" },
    &.{ "#", ";" },
};

const block_comments = [_]BlockComment{
    .{ .start = "/*", .end = "*/" },
    .{ .start = "<!--", .end = "-->" },
    .{ .start = "<#", .end = "#>" },
    .{ .start = "--[[", .end = "]]" },
    .{ .start = "{-", .end = "-}" },
};

const quote_sets = [_][]const u8{
    "",
    "\"",
    "\"'",
    "\"'`",
    "\"`",
    "`",
};

pub const Profile = struct {
    aliases: []const []const u8,
    keywords: []const []const u8 = &.{},
    literals: []const []const u8 = &.{},
    settings: Settings = .{},

    pub fn label(self: *const Profile) []const u8 {
        return self.aliases[0];
    }

    pub fn line_comments(self: *const Profile) []const []const u8 {
        return line_comment_sets[@intFromEnum(self.settings.line_comments)];
    }

    pub fn block_comment(self: *const Profile) ?BlockComment {
        const index = @intFromEnum(self.settings.block_comment);
        return if (index == 0) null else block_comments[index - 1];
    }

    pub fn quotes(self: *const Profile) []const u8 {
        return quote_sets[@intFromEnum(self.settings.quotes)];
    }

    pub fn operators(self: *const Profile) []const u8 {
        return if (self.settings.shell_operators) "&|;<>*" else "";
    }
};

const profiles = [_]Profile{
    .{
        .aliases = &.{"zig"},
        .settings = .{ .line_comments = .slash, .quotes = .double },
        .keywords = &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "struct", "enum", "union", "try", "catch", "comptime", "defer", "errdefer", "async", "await", "anytype", "void" },
    },
    .{
        .aliases = &.{ "ts", "js", "jsx", "javascript", "tsx", "typescript" },
        .settings = .{
            .line_comments = .slash,
            .block_comment = .slash_star,
            .quotes = .shell,
            .detection = .typescript_assertion,
        },
        .keywords = &.{ "const", "let", "var", "function", "class", "interface", "type", "export", "import", "from", "return", "if", "else", "for", "while", "async", "await", "new", "extends", "implements", "public", "private", "readonly" },
        .literals = &.{ "true", "false", "null", "undefined" },
    },
    .{
        .aliases = &.{"json"},
        .settings = .{ .quotes = .double, .detection = .json },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "sh", "bash", "zsh", "shell", "shellscript" },
        // Backticks are code, not strings, in shell.
        .settings = .{
            .line_comments = .hash,
            .quotes = .double_single,
            .shell_operators = true,
            .dollar_vars = true,
            .dash_flags = true,
            .command_words = true,
            .bare_numbers = false,
            .detection = .shell_shebang,
        },
    },
    .{
        .aliases = &.{ "python", "py" },
        .settings = .{ .line_comments = .hash, .quotes = .double_single, .detection = .python_header },
        .keywords = &.{ "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "try", "except", "with", "lambda", "async", "await", "pass", "raise", "yield", "match", "case" },
        .literals = &.{ "True", "False", "None" },
    },
    .{
        .aliases = &.{ "yaml", "yml" },
        .settings = .{ .line_comments = .hash, .quotes = .double_single },
        .literals = &.{ "true", "false", "null", "yes", "no", "on", "off" },
    },
    .{
        .aliases = &.{"toml"},
        .settings = .{ .line_comments = .hash, .quotes = .double_single },
        .literals = &.{ "true", "false" },
    },
    .{
        .aliases = &.{"sql"},
        .settings = .{
            .line_comments = .dash,
            .block_comment = .slash_star,
            .quotes = .double_single,
            .keyword_case = .ascii_insensitive,
            .detection = .sql_select,
        },
        .keywords = &.{ "select", "from", "where", "join", "left", "right", "inner", "outer", "on", "insert", "into", "values", "update", "set", "delete", "create", "alter", "drop", "table", "index", "group", "by", "order", "having", "limit", "as", "and", "or", "not", "distinct", "union" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "dockerfile", "docker" },
        .settings = .{
            .line_comments = .hash,
            .quotes = .double_single,
            .keyword_case = .ascii_insensitive,
            .detection = .dockerfile_from,
        },
        .keywords = &.{ "from", "run", "cmd", "entrypoint", "copy", "add", "workdir", "env", "arg", "expose", "volume", "user", "label", "onbuild", "stopsignal", "healthcheck", "shell", "maintainer" },
    },
    .{
        .aliases = &.{ "rust", "rs" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single, .detection = .rust_function },
        .keywords = &.{ "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "return", "if", "else", "match", "for", "while", "loop", "async", "await", "move", "where", "self", "super" },
        .literals = &.{ "true", "false", "None", "Some" },
    },
    .{
        .aliases = &.{"go"},
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_backtick, .detection = .go_package },
        .keywords = &.{ "package", "import", "func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "switch", "case", "go", "defer", "select", "chan", "map" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .aliases = &.{ "c", "h", "m", "mm" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while" },
        .literals = &.{ "true", "false", "NULL" },
    },
    .{
        .aliases = &.{ "cpp", "c++", "cc", "cxx", "hpp" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "auto", "bool", "class", "const", "constexpr", "decltype", "delete", "enum", "explicit", "friend", "inline", "namespace", "new", "nullptr", "private", "protected", "public", "template", "this", "typename", "using", "virtual", "void" },
        .literals = &.{ "true", "false", "nullptr", "NULL" },
    },
    .{
        .aliases = &.{ "csharp", "cs" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "class", "namespace", "using", "public", "private", "protected", "internal", "static", "void", "string", "int", "var", "new", "return", "if", "else", "for", "foreach", "while", "async", "await", "interface", "record", "get", "set" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{"java"},
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "class", "interface", "package", "import", "public", "private", "protected", "static", "final", "void", "new", "return", "if", "else", "for", "while", "try", "catch", "throws", "extends", "implements", "record", "var" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "kotlin", "kt", "kts" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "fun", "val", "var", "class", "object", "interface", "package", "import", "public", "private", "return", "if", "else", "when", "for", "while", "try", "catch", "data", "sealed", "suspend" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{"php"},
        .settings = .{ .line_comments = .slash_hash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "function", "class", "public", "private", "protected", "namespace", "use", "return", "if", "else", "foreach", "for", "while", "try", "catch", "new", "static", "const", "echo", "yield" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "ruby", "rb" },
        .settings = .{ .line_comments = .hash, .quotes = .double_single },
        .keywords = &.{ "def", "class", "module", "end", "return", "if", "elsif", "else", "unless", "case", "when", "do", "while", "for", "in", "begin", "rescue", "require", "attr_reader" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .aliases = &.{"swift"},
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "func", "let", "var", "class", "struct", "enum", "protocol", "extension", "import", "public", "private", "return", "if", "else", "guard", "for", "while", "switch", "case", "async", "await", "throws", "try" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .aliases = &.{ "powershell", "ps1", "pwsh", "ps" },
        .settings = .{ .line_comments = .hash, .block_comment = .powershell, .quotes = .double_single, .keyword_case = .ascii_insensitive },
        .keywords = &.{ "function", "param", "if", "else", "elseif", "foreach", "for", "while", "switch", "return", "throw", "try", "catch", "finally", "begin", "process", "end", "filter", "class", "enum" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{"lua"},
        .settings = .{ .line_comments = .dash, .block_comment = .lua, .quotes = .double_single },
        .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .aliases = &.{ "html", "htm", "vue", "svelte" },
        .settings = .{ .block_comment = .html, .quotes = .double_single },
        .keywords = &.{ "html", "head", "body", "main", "header", "footer", "section", "article", "div", "span", "a", "p", "script", "style", "link", "meta", "title", "button", "input", "form", "img", "ul", "li" },
    },
    .{
        .aliases = &.{"xml"},
        .settings = .{ .block_comment = .html, .quotes = .double_single },
        .keywords = &.{ "xml", "version", "encoding", "DOCTYPE", "CDATA" },
    },
    .{
        .aliases = &.{"css"},
        .settings = .{ .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "color", "background", "display", "position", "margin", "padding", "border", "font", "width", "height", "flex", "grid", "align", "justify", "transition", "transform", "animation", "media" },
    },
    .{
        .aliases = &.{ "hcl", "terraform", "tf" },
        .settings = .{ .line_comments = .hash_slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "resource", "module", "variable", "output", "provider", "terraform", "locals", "data", "dynamic", "for_each", "count" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "make", "makefile", "mk" },
        .settings = .{ .line_comments = .hash, .dollar_vars = true },
    },
    .{
        .aliases = &.{ "ini", "conf", "cfg", "editorconfig" },
        .settings = .{ .line_comments = .hash_semicolon },
    },
    .{
        .aliases = &.{ "dotenv", "env" },
        .settings = .{ .line_comments = .hash },
    },
    .{
        .aliases = &.{ "graphql", "gql" },
        .settings = .{ .line_comments = .hash, .quotes = .double },
        .keywords = &.{ "query", "mutation", "subscription", "fragment", "on", "type", "input", "interface", "enum", "union", "scalar", "schema", "extend", "implements", "directive" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{"dart"},
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "const", "final", "var", "class", "extends", "with", "implements", "mixin", "enum", "if", "else", "for", "while", "return", "async", "await", "new", "static", "import", "export", "void" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "scala", "sc" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double },
        .keywords = &.{ "val", "var", "def", "class", "object", "trait", "extends", "with", "package", "import", "if", "else", "for", "while", "yield", "match", "case", "return", "new", "type", "given", "override" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{ "elixir", "ex", "exs" },
        .settings = .{ .line_comments = .hash, .quotes = .double },
        .keywords = &.{ "def", "defmodule", "defp", "defmacro", "defguard", "do", "end", "fn", "if", "else", "unless", "case", "cond", "when", "with", "for", "try", "rescue", "after", "alias", "import", "require", "use" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .aliases = &.{ "haskell", "hs" },
        .settings = .{ .line_comments = .dash, .block_comment = .haskell, .quotes = .double },
        .keywords = &.{ "module", "where", "import", "data", "type", "newtype", "class", "instance", "deriving", "if", "then", "else", "case", "of", "do", "let", "in", "infix", "infixl", "infixr" },
        .literals = &.{ "True", "False" },
    },
    .{
        .aliases = &.{ "perl", "pl", "pm" },
        .settings = .{ .line_comments = .hash, .quotes = .shell, .dollar_vars = true },
        .keywords = &.{ "my", "our", "sub", "use", "package", "if", "else", "elsif", "unless", "while", "for", "foreach", "return", "local", "state", "say", "print", "die", "warn", "eval", "do", "require" },
        .literals = &.{"undef"},
    },
    .{
        .aliases = &.{"r"},
        .settings = .{ .line_comments = .hash, .quotes = .double_single },
        .keywords = &.{ "function", "if", "else", "for", "while", "repeat", "break", "next", "return", "in", "library", "require" },
        .literals = &.{ "TRUE", "FALSE", "NULL", "NA" },
    },
    .{
        .aliases = &.{ "groovy", "gradle" },
        .settings = .{ .line_comments = .slash, .block_comment = .slash_star, .quotes = .double_single },
        .keywords = &.{ "def", "class", "interface", "enum", "if", "else", "for", "while", "return", "new", "try", "catch", "finally", "throw", "package", "import", "extends", "implements", "static", "final", "void" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .aliases = &.{"nginx"},
        .settings = .{ .line_comments = .hash },
        .keywords = &.{ "server", "location", "listen", "root", "proxy_pass", "set", "return", "rewrite", "if", "error_page", "access_log", "include", "upstream", "worker_processes", "events", "http" },
    },
    .{
        // Inline code spans color as strings; prose numbers stay plain.
        .aliases = &.{ "markdown", "md", "mdx" },
        .settings = .{ .block_comment = .html, .quotes = .backtick, .bare_numbers = false },
    },
    .{
        // Explicit opt-out of highlighting; kept byte-identical.
        .aliases = &.{ "text", "txt", "plain", "plaintext" },
        .settings = .{ .bare_numbers = false },
    },
    .{
        .aliases = &.{ "diff", "patch" },
        .settings = .{ .diff_lines = true, .detection = .diff_patch },
    },
};

pub fn resolve(label: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        for (profile.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(label, alias)) return profile;
        }
    }
    return null;
}

pub fn infer(alloc: Allocator, source: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (matchesDetection(alloc, profile.settings.detection, source)) return profile;
    }
    return null;
}

fn matchesDetection(alloc: Allocator, detection: Detection, source: []const u8) bool {
    return switch (detection) {
        .none => false,
        .typescript_assertion => matchesTypeScriptAssertion(source),
        .json => isValidJson(alloc, source),
        .shell_shebang => matchesShellShebang(source),
        .python_header => matchesPythonHeader(source),
        .sql_select => matchesSqlSelect(source),
        .dockerfile_from => startsWithIgnoreCase(firstNonblankLine(source), "from "),
        .go_package => startsWith(firstNonblankLine(source), "package ") and containsLineStart(source, "func "),
        .rust_function => matchesRustFunction(source),
        .diff_patch => matchesDiffPatch(source),
    };
}

fn matchesDiffPatch(source: []const u8) bool {
    const line = firstNonblankLine(source);
    if (std.mem.startsWith(u8, line, "diff --git ") or std.mem.startsWith(u8, line, "@@ ")) return true;
    return std.mem.startsWith(u8, line, "--- ") and std.mem.indexOf(u8, source, "\n+++ ") != null;
}

fn matchesTypeScriptAssertion(source: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, "} as ")) |assertion_start| {
        const type_start = assertion_start + "} as ".len;
        if (type_start < source.len and std.ascii.isUpper(source[type_start])) return true;
        start = type_start;
    }
    return false;
}

fn isValidJson(alloc: Allocator, source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object or parsed.value == .array;
}

fn matchesShellShebang(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return std.mem.startsWith(u8, line, "#!") and
        (std.mem.indexOf(u8, line, "bash") != null or std.mem.indexOf(u8, line, "zsh") != null or std.mem.indexOf(u8, line, "/sh") != null);
}

fn matchesPythonHeader(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return (std.mem.startsWith(u8, line, "def ") or std.mem.startsWith(u8, line, "class ")) and std.mem.endsWith(u8, line, ":");
}

fn matchesSqlSelect(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return startsWithIgnoreCase(line, "select ") and containsWordIgnoreCase(source, "from");
}

fn matchesRustFunction(source: []const u8) bool {
    const line = firstNonblankLine(source);
    if (!std.mem.startsWith(u8, line, "fn ") and !std.mem.startsWith(u8, line, "pub fn ")) return false;
    return std.mem.indexOf(u8, source, "let ") != null or std.mem.indexOf(u8, source, "println!") != null or std.mem.indexOf(u8, line, "->") != null;
}

fn firstNonblankLine(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn containsLineStart(source: []const u8, prefix: []const u8) bool {
    if (std.mem.startsWith(u8, source, prefix)) return true;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, "\n")) |newline| {
        const line_start = newline + 1;
        if (std.mem.startsWith(u8, source[line_start..], prefix)) return true;
        start = line_start;
    }
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn containsWordIgnoreCase(source: []const u8, word: []const u8) bool {
    if (word.len > source.len) return false;
    var index: usize = 0;
    while (index + word.len <= source.len) : (index += 1) {
        const end = index + word.len;
        if (std.ascii.eqlIgnoreCase(source[index..end], word) and
            (index == 0 or !isWordByte(source[index - 1])) and
            (end == source.len or !isWordByte(source[end]))) return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "TypeScript assertions infer the canonical TypeScript label" {
    const source =
        "const hook = await resumeHook(token, { cleanup: true } as CleanupSignal);";

    try std.testing.expectEqualStrings("ts", infer(std.testing.allocator, source).?.label());
    try std.testing.expect(infer(std.testing.allocator, "const value = 1;") == null);
    try std.testing.expect(infer(std.testing.allocator, "const value = {} as cleanupSignal;") == null);
}

test "supported code fence labels resolve case insensitively" {
    const cases = [_]struct { label: []const u8, profile: []const u8 }{
        .{ .label = "Zig", .profile = "zig" },
        .{ .label = "js", .profile = "ts" },
        .{ .label = "JSX", .profile = "ts" },
        .{ .label = "javascript", .profile = "ts" },
        .{ .label = "TS", .profile = "ts" },
        .{ .label = "tsx", .profile = "ts" },
        .{ .label = "TypeScript", .profile = "ts" },
        .{ .label = "JSON", .profile = "json" },
        .{ .label = "sh", .profile = "sh" },
        .{ .label = "BASH", .profile = "sh" },
        .{ .label = "zsh", .profile = "sh" },
        .{ .label = "Shell", .profile = "sh" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.profile, resolve(case.label).?.label());
    try std.testing.expect(resolve("") == null);
    // text resolves to a deliberate plain profile; rendering stays byte-identical.
    try std.testing.expectEqualStrings("text", resolve("text").?.label());
}

test "expanded code fence labels resolve through the language registry" {
    const cases = [_]struct { label: []const u8, profile: []const u8 }{
        .{ .label = "python", .profile = "python" },         .{ .label = "py", .profile = "python" },
        .{ .label = "yaml", .profile = "yaml" },             .{ .label = "yml", .profile = "yaml" },
        .{ .label = "toml", .profile = "toml" },             .{ .label = "sql", .profile = "sql" },
        .{ .label = "dockerfile", .profile = "dockerfile" }, .{ .label = "rust", .profile = "rust" },
        .{ .label = "rs", .profile = "rust" },               .{ .label = "go", .profile = "go" },
        .{ .label = "c", .profile = "c" },                   .{ .label = "cpp", .profile = "cpp" },
        .{ .label = "c++", .profile = "cpp" },               .{ .label = "csharp", .profile = "csharp" },
        .{ .label = "cs", .profile = "csharp" },             .{ .label = "java", .profile = "java" },
        .{ .label = "kotlin", .profile = "kotlin" },         .{ .label = "php", .profile = "php" },
        .{ .label = "ruby", .profile = "ruby" },             .{ .label = "swift", .profile = "swift" },
        .{ .label = "powershell", .profile = "powershell" }, .{ .label = "ps1", .profile = "powershell" },
        .{ .label = "lua", .profile = "lua" },               .{ .label = "html", .profile = "html" },
        .{ .label = "xml", .profile = "xml" },               .{ .label = "css", .profile = "css" },
        .{ .label = "hcl", .profile = "hcl" },               .{ .label = "terraform", .profile = "hcl" },
        .{ .label = "tf", .profile = "hcl" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.profile, resolve(case.label).?.label());
}

test "high-confidence source shapes infer registered profiles" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { source: []const u8, profile: []const u8 }{
        .{ .source = "{\"ready\": true}", .profile = "json" },
        .{ .source = "#!/usr/bin/env bash\necho ready", .profile = "sh" },
        .{ .source = "def render(value):\n    return value", .profile = "python" },
        .{ .source = "SELECT id FROM users", .profile = "sql" },
        .{ .source = "FROM alpine:3.20\nRUN echo ready", .profile = "dockerfile" },
        .{ .source = "package main\nfunc main() {}", .profile = "go" },
        .{ .source = "fn main() { println!(\"ready\"); }", .profile = "rust" },
    };

    for (cases) |case| try std.testing.expectEqualStrings(case.profile, infer(alloc, case.source).?.label());
    try std.testing.expect(infer(alloc, "const value = 1;") == null);
    try std.testing.expect(infer(alloc, "title: ready") == null);
}

test "aliases do not collide across profiles" {
    for (profiles, 0..) |profile, profile_index| {
        for (profile.aliases) |alias| {
            for (profiles[profile_index + 1 ..]) |other| {
                for (other.aliases) |other_alias| {
                    try std.testing.expect(!std.ascii.eqlIgnoreCase(alias, other_alias));
                }
            }
        }
    }
}

test "resolve covers the added languages and aliases" {
    const cases = [_]struct { alias: []const u8, label: []const u8 }{
        .{ .alias = "makefile", .label = "make" },
        .{ .alias = "conf", .label = "ini" },
        .{ .alias = "env", .label = "dotenv" },
        .{ .alias = "gql", .label = "graphql" },
        .{ .alias = "dart", .label = "dart" },
        .{ .alias = "sc", .label = "scala" },
        .{ .alias = "exs", .label = "elixir" },
        .{ .alias = "hs", .label = "haskell" },
        .{ .alias = "pl", .label = "perl" },
        .{ .alias = "r", .label = "r" },
        .{ .alias = "gradle", .label = "groovy" },
        .{ .alias = "nginx", .label = "nginx" },
        .{ .alias = "md", .label = "markdown" },
        .{ .alias = "txt", .label = "text" },
        .{ .alias = "patch", .label = "diff" },
        .{ .alias = "shellscript", .label = "sh" },
        .{ .alias = "mm", .label = "c" },
        .{ .alias = "vue", .label = "html" },
    };
    for (cases) |case| {
        const profile = resolve(case.alias).?;
        try std.testing.expectEqualStrings(case.label, profile.label());
    }
}

test "infer detects diff patches without a fence label" {
    const alloc = std.testing.allocator;
    const profile = infer(alloc, "--- a/main.zig\n+++ b/main.zig\n@@ -1 +1 @@\n-old\n+new").?;
    try std.testing.expectEqualStrings("diff", profile.label());
    try std.testing.expect(infer(alloc, "plain prose about --- things") == null);
}

test "language profile metadata stays compact" {
    try std.testing.expect(@sizeOf(Profile) <= 64);
}
