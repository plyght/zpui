//! Vendored tree-sitter queries, embedded verbatim (the same files the Rust
//! grammar crates expose as `HIGHLIGHTS_QUERY` etc.).

const g = "grammars/";

pub const rust_highlights = @embedFile(g ++ "rust/queries/highlights.scm");
pub const rust_injections = @embedFile(g ++ "rust/queries/injections.scm");

pub const javascript_highlights = @embedFile(g ++ "javascript/queries/highlights.scm");
pub const javascript_jsx_highlights = @embedFile(g ++ "javascript/queries/highlights-jsx.scm");
pub const javascript_injections = @embedFile(g ++ "javascript/queries/injections.scm");
pub const javascript_locals = @embedFile(g ++ "javascript/queries/locals.scm");

pub const typescript_highlights = @embedFile(g ++ "typescript/queries/highlights.scm");
pub const typescript_locals = @embedFile(g ++ "typescript/queries/locals.scm");

pub const python_highlights = @embedFile(g ++ "python/queries/highlights.scm");
pub const go_highlights = @embedFile(g ++ "go/queries/highlights.scm");
pub const json_highlights = @embedFile(g ++ "json/queries/highlights.scm");
pub const bash_highlights = @embedFile(g ++ "bash/queries/highlights.scm");
pub const toml_highlights = @embedFile(g ++ "toml/queries/highlights.scm");

pub const markdown_block_highlights = @embedFile(g ++ "markdown/tree-sitter-markdown/queries/highlights.scm");
pub const markdown_block_injections = @embedFile(g ++ "markdown/tree-sitter-markdown/queries/injections.scm");
pub const markdown_inline_highlights = @embedFile(g ++ "markdown/tree-sitter-markdown-inline/queries/highlights.scm");
pub const markdown_inline_injections = @embedFile(g ++ "markdown/tree-sitter-markdown-inline/queries/injections.scm");

pub const html_highlights = @embedFile(g ++ "html/queries/highlights.scm");
pub const html_injections = @embedFile(g ++ "html/queries/injections.scm");
pub const css_highlights = @embedFile(g ++ "css/queries/highlights.scm");
pub const yaml_highlights = @embedFile(g ++ "yaml/queries/highlights.scm");
pub const c_highlights = @embedFile(g ++ "c/queries/highlights.scm");
pub const cpp_highlights = @embedFile(g ++ "cpp/queries/highlights.scm");
pub const csharp_highlights = @embedFile(g ++ "c-sharp/queries/highlights.scm");
pub const java_highlights = @embedFile(g ++ "java/queries/highlights.scm");

pub const swift_highlights = @embedFile(g ++ "swift/queries/highlights.scm");
pub const swift_locals = @embedFile(g ++ "swift/queries/locals.scm");

pub const ruby_highlights = @embedFile(g ++ "ruby/queries/highlights.scm");
pub const ruby_locals = @embedFile(g ++ "ruby/queries/locals.scm");

pub const php_highlights = @embedFile(g ++ "php/queries/highlights.scm");
pub const sql_highlights = @embedFile(g ++ "sql/queries/highlights.scm");

pub const lua_highlights = @embedFile(g ++ "lua/queries/highlights.scm");
pub const lua_locals = @embedFile(g ++ "lua/queries/locals.scm");

pub const nix_highlights = @embedFile(g ++ "nix/queries/highlights.scm");
pub const make_highlights = @embedFile(g ++ "make/queries/highlights.scm");

pub const containerfile_highlights = @embedFile(g ++ "containerfile/queries/highlights.scm");
pub const containerfile_injections = @embedFile(g ++ "containerfile/queries/injections.scm");
