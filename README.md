# EncodingMCP

**Let AI coding assistants read and edit text files in any encoding — without corrupting them.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-none-brightgreen.svg)]()
[![Built with Delphi](https://img.shields.io/badge/Built%20with-Delphi-red.svg)](https://www.embarcadero.com/products/delphi)

AI coding tools (GitHub Copilot, Claude Code, Cursor, Windsurf, Claude Desktop,
…) assume that every text file is UTF-8. A great deal of real-world source code
is not: files in Windows-1252, ISO-8859-x, UTF-16 and other encodings are the
norm in codebases that predate UTF-8 or that target Windows tooling. When an LLM
reads such a file as UTF-8 and writes it back, every `æ`, `ø`, `å`, `ü`, `€` or
smart quote is silently destroyed.

EncodingMCP is an [MCP](https://modelcontextprotocol.io/) server that puts an
encoding-aware layer between the assistant and the disk. It detects the
encoding of each file (BOM, strict UTF-8 validation, codepage heuristics),
hands the assistant clean UTF-8, and converts back to the file's own encoding
on write — preserving BOM and line-ending style. Encodings are remembered per
file in a `.encoding-mcp.json` sidecar, and explicit overrides can be set per
file or per pattern.

It is **language-agnostic**. Typical candidates:

- C / C++ / C# / Java projects with Windows-1252 or ISO-8859-1 sources
- Classic VB6, VBScript and VBA exports
- PHP, Perl and Python 2 code written before UTF-8 became the default
- COBOL, RPG, Fortran and other mainframe or legacy sources
- SQL scripts, `.ini`, `.reg`, `.bat`/`.cmd`, `.properties` and other config
  and resource files
- Localisation files, CSV exports, HTML/XML without a declaration
- UTF-16 files produced by Windows tools
- Delphi and C++Builder projects (`.pas`, `.dfm`, `.dpr`, `.cpp`, `.h`)

## Who is this for?

- Anyone who uses an AI coding assistant on a codebase that is not (entirely)
  UTF-8 and wants to stop reviewing diffs full of `Ã¸` and `Ã¤`.
- Teams maintaining legacy Windows applications where converting the whole
  repository to UTF-8 is not an option (toolchain, merge history, or policy).
- Developers working with UTF-16 or BOM-sensitive files that other tools
  silently rewrite.
- Delphi/C++Builder developers — the project originated there, and the
  binary-DFM guard is one example of how non-text formats are protected.

The server is a single standalone Windows executable with no runtime
dependencies. You do **not** need Delphi to use it — only to build it from
source.

## Quick Start

### Option A: Download prebuilt EXE (no Delphi required)

1. Go to [Releases](https://github.com/thvedel/EncodingMCP/releases/latest)
2. Download `EncodingMCP.exe`
3. Place it somewhere accessible (e.g. `C:\Tools\EncodingMCP.exe`)
4. Configure your MCP client (see [Installation](#installation))

> **Note (Windows):** After downloading you may need to right-click the file
> → Properties → "Unblock", as Windows marks files downloaded from the
> internet. Alternatively: `Unblock-File -Path <path>` in PowerShell.

### Option B: Build from source

```cmd
git clone https://github.com/thvedel/EncodingMCP.git
cd EncodingMCP
build.bat
```

The result is a standalone `.exe` under `build\Win64\Release\`.

## Contents

| Path | Description |
|---|---|
| `EncodingMCP.dpr` | Main program (console application) |
| `src/MCP.*.pas` | Stdio transport, JSON-RPC 2.0, server dispatcher |
| `src/Encoding.*.pas` | Detection, heuristics, workspace, cache |
| `src/FileIO.*.pas` | Encoding-aware file reading/writing |
| `src/Tools.*.pas` | MCP tools (read/write/detect/override) |
| `tests/` | DUnitX test suite |
| `build.bat` | Build script (main program + tests) |

## Requirements

**To use:** Windows x64. Nothing else — it is a single standalone `.exe`.

**To build from source:**

- Delphi 12.3 (Studio 23.0) or Delphi 13.1 (Studio 37.0) — uses only RTL
  (`System.JSON`, `System.SysUtils`, `System.Classes`, `System.IOUtils`,
  `System.Generics.*`)

`build.bat` automatically searches for Delphi in standard locations and selects
the newest available version:

| Delphi version | Studio number | Path to `rsvars.bat` |
|---|---|---|
| 13.1 | 37.0 | `C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat` |
| 12.3 | 23.0 | `C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat` |

If your installation is elsewhere, set the `RSVARS` environment variable
before running `build.bat`.

## Build

```cmd
build.bat
```

Building is done via `msbuild /t:Rebuild` against the two `.dproj` files —
always a full build, so stale DCUs can never hide errors. Output goes to
`build\$(Platform)\$(Config)\` — by default `build\Win64\Release\`. Change
`PLATFORM`/`CONFIG` in `build.bat` to build differently (e.g. `Win32`
or `Debug`).

You can also open `EncodingMCP.dproj` directly in RAD Studio and build from there.

## Installation

The server communicates via **stdio** (stdin/stdout JSON-RPC). Any MCP client
that supports stdio transport can use it. Below are examples for the most
popular clients.

In all examples, replace `<PATH>` with the absolute path to
`EncodingMCP.exe` (either downloaded from Releases or built locally).
Backslashes in JSON must be escaped as `\\`.

### Workspace roots

The server only serves files inside its **allowed workspace roots** (see
[Security](#security)). Without configuration it falls back to the workspace
containing the directory the client starts it in, which is often *not* your
project. Declare the roots explicitly in the client config instead.

There are two equivalent ways; both accept any number of roots:

1. **`args`** — one array element per root:

   ```json
   "command": "<PATH>",
   "args": ["C:\\Projects\\MyApp", "C:\\Projects\\Shared", "D:\\Components"]
   ```

2. **`env`** — the `ENCODING_MCP_WORKSPACE` variable with a semicolon-separated
   list:

   ```json
   "command": "<PATH>",
   "args": [],
   "env": {
     "ENCODING_MCP_WORKSPACE": "C:\\Projects\\MyApp;C:\\Projects\\Shared;D:\\Components"
   }
   ```

If both are present, the roots are combined. Each root must be an absolute path
to an existing directory — anything else is skipped with a warning on `stderr`.
Sub-directories are included automatically, so list the top-level folders only.
The first root is the default for `set_encoding_override` when no `directory`
is given. Roots advertised by the MCP client during `initialize` are added to
the configured set as well.

### GitHub Copilot

**Copilot CLI** (also used by IDE integrations that embed the CLI, e.g. RAD
Studio): edit `%USERPROFILE%\.copilot\mcp-config.json` for a global setup, or
`.mcp.json` in the repository root for a per-project setup:

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "type": "local",
      "command": "C:\\Tools\\EncodingMCP.exe",
      "args": ["C:\\Projects\\MyApp", "C:\\Projects\\Shared"],
      "tools": ["*"]
    }
  }
}
```

**VS Code** (Copilot Chat agent mode): edit `.vscode\mcp.json` in the
workspace, or add the same block under `"mcp"` → `"servers"` in the user
`settings.json`:

```json
{
  "servers": {
    "encoding-bridge": {
      "type": "stdio",
      "command": "C:\\Tools\\EncodingMCP.exe",
      "args": [],
      "env": {
        "ENCODING_MCP_WORKSPACE": "${workspaceFolder};C:\\Projects\\Shared"
      }
    }
  }
}
```

VS Code expands `${workspaceFolder}` to the open folder, so the same file can
be committed and used by the whole team. Restart the Copilot session (CLI) or
run **MCP: Restart Server** (VS Code) after changing the config.

### Windsurf / Codeium

Edit `%USERPROFILE%\.codeium\windsurf\mcp_config.json`:

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "command": "<PATH>",
      "args": [],
      "disabled": false
    }
  }
}
```

Restart Windsurf after the change.

### Claude Code

```bash
claude mcp add encoding-bridge "<PATH>"
```

### Claude Desktop

Edit the config file:
- **Windows**: `%APPDATA%\Claude\claude_desktop_config.json`
- **macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "command": "<PATH>",
      "args": []
    }
  }
}
```

### Cursor

Edit `.cursor/mcp.json` in your project (or the global config):

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "command": "<PATH>",
      "args": []
    }
  }
}
```

### Other MCP clients

Any client that supports MCP stdio transport can launch the EXE directly.
Protocol: JSON-RPC 2.0 over stdin/stdout. Server name: `encoding-bridge`.

### Debug logging

Set the environment variable `ENCODING_MCP_LOG_LEVEL=debug` for detailed logging
on `stderr`. Supported levels: `debug`, `info` (default), `warning`, `error`.

## Available tools

### `read_text_file`

Reads a text file with automatic encoding detection and returns the content as
UTF-8 along with metadata.

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path to the file |
| `head` | integer | Optional: only first N lines |
| `tail` | integer | Optional: only last N lines |
| `startLine` | integer | Optional: 1-based line number to start reading from. Use with `endLine` for a specific range. Takes priority over `head`/`tail`. |
| `endLine` | integer | Optional: 1-based line number to stop at (inclusive). Use with `startLine` for a specific range. Takes priority over `head`/`tail`. |
| `contextLines` | integer | Optional: extra lines to include before and after the `startLine`/`endLine` range. Only applies when a line range is specified. |
| `metadataOnly` | boolean | Optional: if true, return only metadata (encoding, lineEnding, totalLines, etc.) without file content. |
| `searchText` | string | Optional: search for lines containing this text (case-insensitive). Returns matching lines with line-number prefixes, separated by `...` between non-contiguous regions. Use `contextLines` for surrounding context. Takes priority over head/tail/startLine/endLine. |

Output (JSON in `content[0].text`):

```json
{
  "path": "...",
  "encoding": "Windows-1252",
  "hasBom": false,
  "lineEnding": "CRLF",
  "confidence": 0.95,
  "source": "detected",
  "format": "text",
  "fromCache": false,
  "bytesRead": 1234,
  "totalLines": 42,
  "lineNumberStart": 1,
  "returnedLines": 42,
  "matchCount": 3,
  "content": "#include \"legacy.h\" ..."
}
```

- `source` tells where the encoding came from: `bom`, `fileOverride`,
  `patternOverride` or `detected`.
- `format` is `text`. Binary files that merely look like text are refused
  instead of being mangled; for example a Delphi form stored in binary format
  is rejected with an error and `format: "binary-dfm"`.
- For a pure-ASCII file the response also contains
  `writeRecommendation: "Windows-1252"` and a `note`: `ASCII` (even with high
  confidence) only means that no byte above 0x7F exists, so the codepage cannot
  be determined. See [Encoding policy](#encoding-policy).

### `write_text_file`

Writes UTF-8 content to a file in the correct encoding. If the file exists, its
encoding is re-checked on disk before every write (changes made by the IDE, git
or other tools are respected), and per-file and pattern overrides apply even if
the file has never been read. New files default to UTF-8 with BOM. Every write
holds an exclusive lock on the file (see [Concurrency](#concurrency)).

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path |
| `content` | string | UTF-8 content |
| `encoding` | string | Optional target encoding (UTF-8, Windows-1252, ...). Changing only the encoding keeps the existing line endings; the BOM is kept, added when switching from an 8-bit encoding to Unicode, and dropped for 8-bit encodings. |
| `lineEnding` | string | Optional (CRLF/LF/CR). Default preserves existing. |
| `hasBom` | boolean | Optional. Default preserves existing (true for new UTF files). `true` on a pure-ASCII file writes UTF-8 with BOM. |
| `createIfMissing` | boolean | Default true |
| `dryRun` | boolean | Optional: report encoding, BOM, line ending, upgrades and warnings without writing |
| `force` | boolean | Optional (default false): allow replacing a binary DFM with text |

Output (JSON in `content[0].text`):

```json
{
  "path": "...",
  "encoding": "Windows-1252",
  "hasBom": false,
  "lineEnding": "CRLF",
  "bytesWritten": 1234,
  "created": false,
  "source": "detected",
  "previousEncoding": "ASCII",
  "upgradedFrom": "ASCII",
  "warnings": ["..."]
}
```

`encoding` is always the encoding actually written. `source` is `bom`,
`fileOverride`, `patternOverride`, `detected`, `explicit` (the `encoding`
parameter) or `default` (new file). `previousEncoding` is the encoding of the
existing file on disk. `upgradedFrom` and `warnings` appear only when the
encoding had to change. `dryRun: true` is echoed when set.

#### Encoding policy

Applies to `write_text_file`, `write_text_files` and `edit_text_file`:

- **ASCII upgrade**: a pure-ASCII file has no byte that reveals its codepage.
  When non-ASCII characters are written to it, the file becomes Windows-1252
  (the Delphi default) — never UTF-8 without BOM, which Delphi would misread as
  ANSI (`Ã¸` instead of `ø`). The response reports `upgradedFrom: "ASCII"` and a
  warning. Use an override, `encoding` or `hasBom: true` to get UTF-8 with BOM
  instead.
- **Unrepresentable characters**: if the target encoding cannot represent a
  character (e.g. an emoji in Windows-1252), nothing is written. The error
  response contains `unrepresentableChars` (count) and `sample`; there is no
  silent `?` substitution.
- **Binary DFM guard**: an existing Delphi form stored in binary format is never
  overwritten with text unless `force: true` is given. `read_text_file` and
  `edit_text_file` refuse such files with `format: "binary-dfm"`.

### `edit_text_file`

Edits a text file by search/replace or line-range replacement, preserving the
file's original encoding, BOM, and line-ending style. The
[encoding policy](#encoding-policy) applies. The edit is rejected with
`reason: "modified"` if another process changed the file between the read and
the write (see [Concurrency](#concurrency)).

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path to the file (must exist) |
| `oldText` | string | Text to find and replace. Leave empty for range mode. |
| `newText` | string | Replacement text (required) |
| `startLine` | integer | Optional: 1-based start line for range replacement |
| `endLine` | integer | Optional: 1-based end line (inclusive) for range replacement |
| `maxReplacements` | integer | Optional: max replacements (default 1). 0 = unlimited. |
| `dryRun` | boolean | Optional: if true, compute the result without writing to disk. |
| `edits` | array | Optional: array of atomic edits (see below). Overrides top-level oldText/newText. |

**Modes:**
- **Search/replace**: provide `oldText` + `newText`. If `maxReplacements` is 1
  (default) and multiple matches exist, an error is returned with the match count.
- **Range replacement**: provide `startLine` + `endLine` + `newText` with empty
  `oldText`. The line range is replaced entirely; an empty `newText` deletes the
  lines including their line breaks. `startLine` = total lines + 1 appends at the
  end of the file; a larger `startLine` is an error. A trailing line break in
  `newText` does not add an extra blank line.
- The two modes are mutually exclusive per edit: `oldText` together with
  `startLine`/`endLine` is rejected instead of silently ignoring the range.
- **Multi-edit (atomic)**: provide an `edits` array. If any edit fails, nothing
  is written. Each item supports `oldText`, `newText`, `startLine`, `endLine`,
  `maxReplacements`.

**Line endings:** `oldText` and `newText` may use `\n`; both are normalized to
the file's line-ending style before matching and inserting. For files with mixed
line endings the dominant style is used.

**Multi-edit semantics:**
- All line ranges refer to the **original** file, regardless of their order in
  the array. They are applied from the end of the file towards the beginning, so
  one range edit never shifts the line numbers of another.
- Overlapping ranges, and two edits appending at the same position, are rejected.
- Search/replace edits are applied afterwards, in array order, to the result of
  the range edits.
- If an `oldText` would match a different number of times before and after the
  range edits, the order is ambiguous and the call is rejected.
- Error messages that concern one specific edit are prefixed with `Edit N:`.
  Errors about the call as a whole (overlapping ranges, empty `edits` array)
  have no prefix.

Output (JSON in `content[0].text`):

```json
{
  "path": "...",
  "encoding": "Windows-1252",
  "hasBom": false,
  "lineEnding": "CRLF",
  "bytesWritten": 1234,
  "replacements": 1,
  "changed": true,
  "diff": "@@ -1,3 +1,3 @@\n context\n-old line\n+new line\n context\n"
}
```

`upgradedFrom` and `warnings` are added when the [encoding policy](#encoding-policy)
changed the encoding; `dryRun: true` is echoed when set. `replacements` counts
search/replace matches that were replaced plus 1 for each range edit.

**Diff format:** the `diff` field is only present when `changed` is `true`. It is
a unified diff with 3 lines of context; nearby changes share one hunk, distant
changes get separate hunks (`@@ -a,b +c,d @@`), so unchanged lines between two
edits are not repeated. Diff lines are always separated by `\n`, whatever the
file's line endings — the file itself is written in its own style. A line whose
terminator differs from the file's style is marked with ` [LF]`, ` [CR]` or
` [CRLF]`, and a missing final line break is shown as
`\ No newline at end of file`.

### `read_text_files`

Reads multiple files in a single call. Reduces MCP round-trips during
cross-file refactoring. Each file entry supports the same parameters as
`read_text_file`. Errors for individual files are reported inline without
aborting the batch.

| Parameter | Type | Description |
|---|---|---|
| `files` | array | Array of file specifications (see below) |

Each entry in `files`:

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path to the file (required) |
| `head` | integer | Optional: first N lines |
| `tail` | integer | Optional: last N lines |
| `startLine` | integer | Optional: 1-based start line |
| `endLine` | integer | Optional: 1-based end line (inclusive) |
| `contextLines` | integer | Optional: extra context lines |
| `metadataOnly` | boolean | Optional: skip content |
| `searchText` | string | Optional: case-insensitive line search |

Output (JSON in `content[0].text`):

```json
{
  "totalFiles": 3,
  "succeeded": 2,
  "failed": 1,
  "results": [
    { "path": "...", "encoding": "UTF-8", "content": "...", ... },
    { "path": "...", "encoding": "Windows-1252", "content": "...", ... },
    { "path": "...", "error": "File not found: ..." }
  ]
}
```

### `write_text_files`

Writes multiple files in a single call with encoding-aware conversion.
Each file entry can specify its own encoding, lineEnding, and hasBom options.
Errors for individual files are reported inline without aborting the batch.

| Parameter | Type | Description |
|---|---|---|
| `files` | array | Array of file specifications (see below) |

Each entry in `files`:

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path to the file (required) |
| `content` | string | UTF-8 content to write (required) |
| `encoding` | string | Optional: target encoding (UTF-8, Windows-1252, etc.) |
| `lineEnding` | string | Optional: CRLF, LF, or CR |
| `hasBom` | boolean | Optional: write a BOM |
| `createIfMissing` | boolean | Optional (default true): create if not exists |
| `dryRun` | boolean | Optional: report the result of the write without writing |
| `force` | boolean | Optional (default false): allow replacing a binary DFM with text |

Output (JSON in `content[0].text`):

```json
{
  "totalFiles": 2,
  "succeeded": 2,
  "failed": 0,
  "results": [
    { "path": "...", "encoding": "UTF-8", "bytesWritten": 123, "created": true, ... },
    { "path": "...", "encoding": "Windows-1252", "bytesWritten": 456, "created": false, ... }
  ]
}
```

### `list_files`

Lists files in a directory recursively, optionally filtered by glob pattern.
Returns relative paths from the specified directory.

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path to the directory to list (must be within workspace) |
| `pattern` | string | Optional: glob pattern to filter files (e.g. `*.c`, `*.sql`, `*.pas`) |

Lock and temporary files of writes in progress (`*.lock`, `*.<pid>-<guid>.tmp`)
are never listed.

Output (JSON in `content[0].text`):

```json
{
  "path": "C:/Projects/MyApp",
  "totalFiles": 12,
  "files": ["src/legacy.c", "scripts/report.sql", "config.ini", "Forms/Main.pas", ...]
}
```

### `detect_encoding`

Analyses the **whole** file (no size limit) with exactly the same resolution as
`read_text_file` (BOM, overrides, detection), so both tools always report the
same encoding. Returns `format`, `encoding`, `hasBom`, `confidence`,
`lineEnding`, `source`, `bytesRead` and the candidate scores, plus
`writeRecommendation`/`note` for pure-ASCII files. A binary DFM is reported
with `format: "binary-dfm"` and a `note` instead of an encoding.

| Parameter | Type |
|---|---|
| `path` | string |

### `set_encoding_override`

Sets or removes a manual encoding override for one file or for a pattern.

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path of a single file (either `path` *or* `pattern`) |
| `pattern` | string | File-name pattern (`*.pas`) or path pattern relative to the workspace root (`src/**/*.dfm`) |
| `directory` | string | Optional, pattern only: a directory inside the workspace that selects the workspace root. Defaults to the first workspace root. |
| `encoding` | string | Encoding to apply. Required unless `remove` is true. |
| `remove` | boolean | If true, remove the override instead of setting it |

- Patterns without `/` match the file name in any folder. Patterns with `/`
  match the path relative to the workspace root and support `*`, `?` and `**`.
  Other glob syntax is rejected with an error instead of being accepted
  silently.
- Pattern overrides are stored in the **outermost** sidecar and therefore apply
  to the whole repository, including subfolders with their own `.dproj`. A
  matching pattern in a nearer sidecar takes precedence.
- With `remove`, a pattern is removed from every sidecar between `directory` and
  the outermost root; the response lists them in `removedFrom`.
- Overrides take precedence over detection, but a BOM always wins.
- The response contains `sidecar`, `root`, `matches` and `appliesTo`, so it is
  clear where the override was stored and which files it covers.

## Security

All tools validate that the requested `path` resides within an **allowed
workspace root**. Paths are fully resolved first, so `..` traversal cannot be
used to escape. Requests outside the allowed roots are rejected with an error.

The allowed roots are determined at startup, in this order:

1. **Command-line arguments** — each non-switch argument is a workspace root:
   `EncodingMCP.exe C:\Projects\MyApp C:\Projects\Shared`
2. **`ENCODING_MCP_WORKSPACE`** environment variable — semicolon-separated list,
   combined with any roots from step 1
3. **Fallback** (only when steps 1–2 yield nothing): the workspace containing
   the current directory

See [Workspace roots](#workspace-roots) for how to declare several roots in
the MCP client configuration.

In addition, roots advertised by the MCP client during `initialize`
(`rootUri`, `rootPath` or the MCP `roots` array) are added to the allowed set.

Configuring the root explicitly is recommended, since the working directory the
MCP client uses to launch the server is not guaranteed:

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "command": "<PATH>",
      "args": ["C:\\Projects\\MyApp"]
    }
  }
}
```

If no root can be determined at all, the server falls back to requiring a real
workspace marker (`.git`, `.windsurf`, `*.dproj`, `*.groupproj`, `.svn`, `.hg`)
at or above the requested path.

> **Note:** Containment is checked on the resolved path string. Symlinks and
> junctions that point out of the workspace are not resolved and can therefore
> still reach outside it.

## Encoding detection (pipeline)

1. **BOM check** (UTF-8 / UTF-16 LE+BE / UTF-32 LE+BE) — 100% certain
2. **Strict UTF-8 validation** — rejects overlong, surrogates, out-of-range
3. **UTF-16 without BOM** — null-byte distribution heuristic
4. **8-bit codepage scoring**:
   - **Windows-1252**: preferred if printable C1 characters (€, smart quotes, ...)
   - **ISO-8859-1**: preferred if no C1 bytes
   - **ISO-8859-15**: if 0xA4 (€) seen without other C1 characters
5. **Fallback**: Windows-1252 (the default ANSI codepage on Western Windows)

Resolution order: BOM > per-file override > pattern override > detection. A
file without any byte above 0x7F is reported as `ASCII`; writes to it follow the
[ASCII upgrade](#encoding-policy) rule.

## Sidecar cache

Encoding information is stored in `.encoding-mcp.json` sidecars:

- The **outermost sidecar** lives in the outermost workspace root: the allowed
  workspace root containing the file, otherwise the nearest directory with
  `.git`, `.svn` or `.hg`, otherwise the nearest directory with a workspace
  marker (`.windsurf`, `*.dproj`, `*.groupproj`).
- File entries are stored in the nearest existing sidecar between the file and
  the outermost root. Reading files never creates new sidecars in subfolders,
  even if they contain their own `.dproj`.
- Lookups walk the chain from the nearest sidecar to the outermost one.
- Sidecars are reloaded when they change on disk, so manual edits (adding or
  removing overrides) take effect on the next tool call — no restart needed.

A sidecar with the former name `.windsurf-encoding.json` is still read; it is
migrated to `.encoding-mcp.json` on the next save and then deleted. If both
files exist, `.encoding-mcp.json` wins and a warning is logged.
Format:

```json
{
  "version": 1,
  "files": {
    "src/legacy.c": {
      "encoding": "Windows-1252",
      "hasBom": false,
      "lineEnding": "CRLF",
      "detectedAt": "2026-04-30T16:21:06+02:00"
    },
    "scripts/report.sql": {
      "encoding": "ISO-8859-1",
      "hasBom": false,
      "lineEnding": "LF",
      "detectedAt": "2026-04-30T16:22:41+02:00"
    }
  },
  "overrides": {
    "*.pas": "Windows-1252",
    "config/**/*.ini": "ISO-8859-15"
  }
}
```

`manual: true` marks entries set explicitly via `set_encoding_override` —
these are not overwritten by auto-detection.

## Round-trip example

File before (Windows-1252):
```
75 6E 69 74 20 54 65 73 74 3B 0D 0A 2F 2F 20 E6 F8 E5
```

Read via `read_text_file`:
```
unit Test;\r\n// æøå
```

Written back via `write_text_file` with the same content:
```
75 6E 69 74 20 54 65 73 74 3B 0D 0A 2F 2F 20 E6 F8 E5
```

Bytes are identical — encoding is preserved.

## Concurrency

Several server instances (one per IDE window or agent session) may work in the
same repository at the same time. Writes are therefore protected on three
levels:

- **Atomic replacement.** Content is written to a temporary file next to the
  target and renamed over it (`MoveFileEx` with write-through), so a crash
  never leaves a half-written file. The temporary name
  `<file>.<pid>-<guid>.tmp` is unique per process and call, so two instances
  never collide on it.
- **Exclusive file lock.** Before touching a file the writer creates
  `<file>.lock` with `CREATE_NEW`, no sharing and `FILE_FLAG_DELETE_ON_CLOSE`.
  The whole sequence — re-read, resolve encoding, convert, rename — runs while
  the lock is held. A second writer waits with exponential backoff (10 → 200
  ms) for up to **2000 ms** and then fails with `reason: "locked"`. Because
  the OS deletes the lock file when the handle closes, a crashed instance
  cannot leave a stale lock behind.
- **Modified-since-read check.** `edit_text_file` records the file's last-write
  time when it reads the file and verifies it again *inside* the lock just
  before writing. If another process changed the file in between, the edit
  fails with `reason: "modified"` and nothing is written. The check is skipped
  for `dryRun`.

The sidecar cache uses the same lock: it reloads the sidecar, merges its
pending changes and writes the result while holding `.encoding-mcp.json.lock`,
so entries written by other instances are never lost.

Both failures are returned as a structured error with `isError: true`:

```json
{
  "path": "C:/Projects/MyApp/src/legacy.c",
  "error": "File was modified by another process since it was read: ... Read the file again and retry.",
  "reason": "modified",
  "retryable": true
}
```

`reason` is `locked` or `modified`; both are safe to retry (for `modified`,
read the file again first). In `write_text_files` the error appears inline for
the affected file and the other files are still written.

Lock and temporary files are ignored by `list_files` and by the sidecar logic.
On network shares where `CREATE_NEW` is not reliably exclusive the lock is
best-effort; atomic replacement still applies.

## Limitations and future improvements

- **Client integration**: There is no guarantee that the AI tool will actually
  call `write_text_file` instead of its native file writing. It depends on
  how the tool descriptions cause the LLM to choose the tool. Test empirically.
- **MacRoman**: Not actively detected yet — the code has the structure for it but
  scoring is minimal.
- **Large files**: Detection always analyses the whole file, so a late
  non-ASCII character is never missed. Very large files take correspondingly
  longer.
- **Other writers**: The file lock only coordinates processes that use the same
  `.lock` convention. An IDE or `git checkout` writing the file directly is not
  blocked; the modified-since-read check catches that case for edits.

## Tests

Two ways to run tests:

### Command line (CI/build)

```cmd
build.bat
```

Builds and runs the DUnitX console runner. Output in terminal, exit code 0 on
success.

### TestInsight in RAD Studio (during development)

`tests\EncodingMCPTests.dpr` has a `{$IFDEF TESTINSIGHT}` that selects between
two runners:

| Build config | Define | Runner |
|---|---|---|
| Debug (IDE) | `TESTINSIGHT` defined | TestInsight (results to View → TestInsight) |
| Release (build.bat) | not defined | DUnitX console with stdout output |

`TESTINSIGHT` is set in `tests\EncodingMCPTests.dproj`'s Debug configuration —
no extra setup required after the first time you install TestInsight.

#### One-time setup (only first time on a fresh Delphi installation)

1. **Install TestInsight**:
   [github.com/Stefan-Glienke/TestInsight](https://github.com/Stefan-Glienke/TestInsight) — free open source by Stefan Glienke.
2. **Library Path**: In the IDE, **Tools → Options → Language → Delphi → Library**
   → add the TestInsight `Source` folder to **Library Path** for **Win64**.
   On Windows it is typically located at
   `%LOCALAPPDATA%\Programs\TestInsight\Source` after installation.

#### Daily use

1. Open `tests\EncodingMCPTests.dproj` in RAD Studio.
2. Select the **Debug** configuration (default). Compile (Ctrl+F9).
3. Open **View → TestInsight** (or View → Other Windows → TestInsight).
4. Click **Run** in the TestInsight panel — results appear live, and you can
   double-click a failure to jump directly to the line in the editor.

Tests cover:

- BOM detection (UTF-8/16 LE/BE)
- Strict UTF-8 validation (incl. overlong, surrogates, lone start bytes)
- Codepage heuristics (Windows-1252 vs ISO-8859-1 vs ISO-8859-15)
- Line-ending detection (CRLF/LF/Mixed)
- End-to-end round-trip (read Windows-1252 → write back, byte comparison)
- BOM writing and default UTF-8 BOM for new files
- Atomic file writing (no temp file left behind)
- Cache merge (two instances preserve each other's entries)
- Concurrency: unique temp names, lock wait/timeout/cleanup, lock released on
  error, write refused while locked, modified-since-read (stale, fresh,
  dryRun), parallel sidecar saves keep all entries
- Line-range reading (startLine/endLine interval, clamping, priority over head/tail)
- Edit tool: search/replace (single, multi, unlimited, max-N, deletion)
- Edit tool: range replacement (middle, first, last, entire, clamp, invalid)
- Edit tool: encoding preservation, no-change detection, error handling
- lineNumberStart output for head, tail, startLine/endLine, and full file
- contextLines expansion and clamping for line-range reads
- dryRun mode for edit_text_file (no-write verification)
- Cache invalidation on file change (size/timestamp staleness check)
- Manual override survives cache invalidation
- Search-in-file: matching, context, case-insensitivity, region merging, match count
- Optimistic lock: external modification detection, successful edit without conflict
- Workspace restriction: allowed roots, traversal escape, sibling prefix directory,
  root directory itself, multiple roots, marker-discovery fallback
- list_files tool: recursive listing, glob filtering, empty directory, subdirectories, missing directory
- read_text_files (batch-read): single/multiple files, inline error handling, metadataOnly, head param, searchText, empty array
- Multi-edit (atomic): two edits applied, second-fails-nothing-written, dryRun, empty array, mixed modes
- write_text_files (batch-write): single/multiple files, inline error handling, creates new, empty array, encoding override
- Diff output: contains changed lines, empty when no change, multi-edit shows all changes
- Safe write encoding: ASCII → Windows-1252 upgrade, unrepresentable characters,
  explicit BOM, write dryRun, re-check on disk, overrides on files never read
- Sidecar rename and migration from `.windsurf-encoding.json` (including a
  legacy file that cannot be deleted)
- Overrides: outermost sidecar, path patterns, invalid patterns, remove across
  the whole sidecar chain, conflict warnings, reload after external sidecar
  changes
- detect/read consistency (pattern and file overrides), late non-ASCII byte,
  binary DFM guard, ASCII write recommendation
- Range edits: delete, append, original-file multi-edit, overlap and ambiguity
  errors, mutually exclusive modes, line-ending normalization and fallback,
  diff hunks and markers, large-diff fallback
- Argument handling: null treated as absent, empty `edits`/`files` arrays,
  missing required arguments raise `EInvalidArgumentError`

## Contributing

Pull requests and issues are welcome. Run `build.bat` before submitting a PR to
ensure the test suite still passes.

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Thomas Vedel.
