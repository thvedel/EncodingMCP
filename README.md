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
  "returnedLines": 42,
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

## Contributing

Pull requests and issues are welcome. Run `build.bat` before submitting a PR to
ensure the test suite still passes.

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Thomas Vedel.
