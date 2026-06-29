# EncodingMCP

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Delphi](https://img.shields.io/badge/Delphi-12.3%2B-red.svg)](https://www.embarcadero.com/products/delphi)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue.svg)]()

MCP server ([Model Context Protocol](https://modelcontextprotocol.io/)) that solves
the problem of AI coding tools (Windsurf, Claude Code, Claude Desktop,
Cursor, etc.) expecting text files to be UTF-8 encoded.

Many projects — particularly Delphi, C++Builder, and legacy Windows applications —
have source files in Windows-1252, ISO-8859-1, or other 8-bit encodings. Without
proper handling, special characters (`æ`, `ø`, `å`, `€`, smart quotes, etc.)
get corrupted when an LLM reads or writes these files.

The server automatically detects encoding (BOM, UTF-8 validation, or heuristic
codepage scoring) and translates between file encoding and UTF-8 on read and
write. Encoding is remembered per file in a `.windsurf-encoding.json` sidecar in
the workspace root.

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

- Delphi 12.3 (Studio 23.0) or Delphi 13.1 (Studio 37.0) — uses only RTL
  (`System.JSON`, `System.SysUtils`, `System.Classes`, `System.IOUtils`,
  `System.Generics.*`)
- Windows
- No runtime dependencies — it is a single standalone `.exe`

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

Building is done via `msbuild` against the two `.dproj` files. Output goes to
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
  "fromCache": false,
  "bytesRead": 1234,
  "totalLines": 42,
  "lineNumberStart": 1,
  "returnedLines": 42,
  "matchCount": 3,
  "content": "unit MainForm; ..."
}
```

### `write_text_file`

Writes UTF-8 content to a file in the correct encoding. If the file exists,
its original encoding is preserved (unless an `encoding` override is given).
New files default to UTF-8 with BOM.

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Absolute path |
| `content` | string | UTF-8 content |
| `encoding` | string | Optional override (UTF-8, Windows-1252, ...) |
| `lineEnding` | string | Optional (CRLF/LF/CR) |
| `hasBom` | boolean | Optional |
| `createIfMissing` | boolean | Default true |

### `edit_text_file`

Edits a text file by search/replace or line-range replacement, preserving the
file's original encoding, BOM, and line-ending style.

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
  `oldText`. The specified line range is replaced entirely.
- **Multi-edit (atomic)**: provide `edits` array. Each edit is applied sequentially.
  If any edit fails, no changes are written. Each item supports: `oldText`, `newText`,
  `startLine`, `endLine`, `maxReplacements`.

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

The `diff` field is only present when `changed` is `true`. It contains a unified
diff snippet showing removed (`-`) and added (`+`) lines with context.

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
| `pattern` | string | Optional: glob pattern to filter files (e.g. `*.pas`, `*.dfm`) |

Output (JSON in `content[0].text`):

```json
{
  "path": "C:/Projects/MyApp",
  "totalFiles": 12,
  "files": ["src/Main.pas", "src/Utils.pas", ...]
}
```

### `detect_encoding`

Returns detected encoding + candidate scores without reading the full content.

| Parameter | Type |
|---|---|
| `path` | string |

### `set_encoding_override`

Manually set encoding for a specific file or for an extension pattern.

| Parameter | Type | Description |
|---|---|---|
| `path` | string | Either path *or* pattern |
| `pattern` | string | E.g. `*.pas` |
| `encoding` | string | Encoding to apply |

## Security

All tools validate that the requested `path` resides within a detected workspace
root (directory containing `.git`, `.windsurf`, `*.dproj`, etc.). Paths that
resolve outside the workspace are rejected.

## Encoding detection (pipeline)

1. **BOM check** (UTF-8 / UTF-16 LE+BE / UTF-32 LE+BE) — 100% certain
2. **Strict UTF-8 validation** — rejects overlong, surrogates, out-of-range
3. **UTF-16 without BOM** — null-byte distribution heuristic
4. **8-bit codepage scoring**:
   - **Windows-1252**: preferred if printable C1 characters (€, smart quotes, ...)
   - **ISO-8859-1**: preferred if no C1 bytes
   - **ISO-8859-15**: if 0xA4 (€) seen without other C1 characters
5. **Fallback**: Windows-1252 (Delphi/Windows default)

## Sidecar cache

`.windsurf-encoding.json` is placed in the workspace root (the directory
containing `.git`, `.windsurf`, `*.dproj`, `*.groupproj`, `.svn`, or `.hg`).
Format:

```json
{
  "version": 1,
  "files": {
    "src/MainForm.pas": {
      "encoding": "Windows-1252",
      "hasBom": false,
      "lineEnding": "CRLF",
      "detectedAt": "2026-04-30T16:21:06+02:00"
    }
  },
  "overrides": {
    "*.pas": "Windows-1252"
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

## Limitations and future improvements

- **Client integration**: There is no guarantee that the AI tool will actually
  call `write_text_file` instead of its native file writing. It depends on
  how the tool descriptions cause the LLM to choose the tool. Test empirically.
- **MacRoman**: Not actively detected yet — the code has the structure for it but
  scoring is minimal.
- **Large files**: Heuristics run only on the first 64 KB. This is fast and
  sufficient for typical source files.
- **Concurrent writes**: File writing (both user files and sidecar cache)
  is atomic via temp file + rename, so a crash never leaves a half-written
  file. The sidecar cache merges with disk content before writing, so entries from
  other instances are preserved. However, there is no file-locking layer — with truly
  concurrent writes to the *same* file from two instances, the last one wins.

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
- Atomic file writing (no .tmp file left behind)
- Cache merge (two instances preserve each other's entries)
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
- Workspace restriction: path validation (inside workspace acceptance)
- list_files tool: recursive listing, glob filtering, empty directory, subdirectories, missing directory
- read_text_files (batch-read): single/multiple files, inline error handling, metadataOnly, head param, searchText, empty array
- Multi-edit (atomic): two edits applied, second-fails-nothing-written, dryRun, empty array, mixed modes
- write_text_files (batch-write): single/multiple files, inline error handling, creates new, empty array, encoding override
- Diff output: contains changed lines, empty when no change, multi-edit shows all changes

## Contributing

Pull requests and issues are welcome. Run `build.bat` before submitting a PR to
ensure the test suite still passes.

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Thomas Vedel.
