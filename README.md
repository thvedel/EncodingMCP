# EncodingMCP

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Delphi](https://img.shields.io/badge/Delphi-12%2B-red.svg)](https://www.embarcadero.com/products/delphi)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue.svg)]()

Native Delphi MCP-server der løser problemet med at Windsurf/Codeium forventer at
tekstfiler er UTF-8 encoded. Mange Delphi-projekter har kildefiler i Windows-1252
eller andre 8-bit encodings, og uden korrekt håndtering bliver danske tegn (`æ`,
`ø`, `å`) og andre non-ASCII tegn ødelagt når en LLM ændrer i filerne.

Serveren detekterer automatisk encoding (BOM, UTF-8-validering eller heuristisk
codepage-scoring) og oversætter mellem fil-encoding og UTF-8 ved læsning og
skrivning. Encoding huskes per fil i en `.windsurf-encoding.json` sidecar i
workspace-roden.

## Hurtigstart

```cmd
git clone <repo-url>
cd EncodingMCP
build.bat
```

Resultatet er en selvstændig `.exe` under `build\Win64\Release\`. Peg Windsurf
på den (se [Konfiguration i Windsurf](#konfiguration-i-windsurf)).

## Indhold

| Sti | Beskrivelse |
|---|---|
| `EncodingMCP.dpr` | Hovedprogram (console application) |
| `src/MCP.*.pas` | Stdio-transport, JSON-RPC 2.0, server-dispatcher |
| `src/Encoding.*.pas` | Detektion, heuristik, workspace, cache |
| `src/FileIO.*.pas` | Encoding-aware fil-læsning/skrivning |
| `src/Tools.*.pas` | MCP-værktøjer (read/write/detect/override) |
| `tests/` | DUnitX testsuite |
| `build.bat` | Build-script (hovedprogram + tests) |

## Krav

- Delphi 12 (Studio 37) eller nyere — bruger kun RTL (`System.JSON`,
  `System.SysUtils`, `System.Classes`, `System.IOUtils`, `System.Generics.*`)
- Windows
- Ingen runtime-afhængigheder — det er én selvstændig `.exe`

`build.bat` antager at Delphi-installationens `rsvars.bat` ligger i sin
standardplacering (`C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat`).
Justér variablen `RSVARS` i `build.bat` hvis din installation ligger andetsteds
eller du bruger en anden Delphi-version.

## Build

```cmd
build.bat
```

Byggeri sker via `msbuild` mod de to `.dproj`-filer. Output havner under
`build\$(Platform)\$(Config)\` — som default `build\Win64\Release\`. Skift
`PLATFORM`/`CONFIG` i `build.bat` for at bygge anderledes (f.eks. `Win32`
eller `Debug`).

Du kan også åbne `EncodingMCP.dproj` direkte i RAD Studio og bygge derfra.

## Konfiguration i Windsurf

Byg projektet (`build.bat`) og noter den absolutte sti til den genererede
`EncodingMCP.exe`. Tilføj så følgende til `~/.codeium/windsurf/mcp_config.json`
(Windows: `%USERPROFILE%\.codeium\windsurf\mcp_config.json`):

```json
{
  "mcpServers": {
    "encoding-bridge": {
      "command": "<ABSOLUT_STI_TIL_EncodingMCP.exe>",
      "args": [],
      "disabled": false
    }
  }
}
```

Udskift `<ABSOLUT_STI_TIL_EncodingMCP.exe>` med stien til din build (f.eks.
`C:\\projects\\EncodingMCP\\build\\Win64\\Release\\EncodingMCP.exe`).
Backslashes skal escapes som `\\` i JSON.

Genstart Windsurf efter ændringen. Du kan sætte miljøvariablen
`ENCODING_MCP_LOG_LEVEL=debug` for mere logging på `stderr`.

## Tilgængelige tools

### `read_text_file`

Læser en tekstfil med automatisk encoding-detektion og returnerer indholdet som
UTF-8 sammen med metadata.

| Parameter | Type | Beskrivelse |
|---|---|---|
| `path` | string | Absolut sti til filen |
| `head` | integer | Valgfri: kun første N linjer |
| `tail` | integer | Valgfri: kun sidste N linjer |

Output (JSON i `content[0].text`):

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

Skriver UTF-8 indhold til en fil i den korrekte encoding. Hvis filen findes,
bevares dens originale encoding (med mindre der gives `encoding`-override).
Nye filer defaulter til UTF-8 med BOM.

| Parameter | Type | Beskrivelse |
|---|---|---|
| `path` | string | Absolut sti |
| `content` | string | UTF-8 indhold |
| `encoding` | string | Valgfri override (UTF-8, Windows-1252, ...) |
| `lineEnding` | string | Valgfri (CRLF/LF/CR) |
| `hasBom` | boolean | Valgfri |
| `createIfMissing` | boolean | Default true |

### `detect_encoding`

Returnerer detekteret encoding + kandidatscores uden at læse hele indholdet.

| Parameter | Type |
|---|---|
| `path` | string |

### `set_encoding_override`

Manuelt sæt encoding for en specifik fil eller for et extension-pattern.

| Parameter | Type | Beskrivelse |
|---|---|---|
| `path` | string | Enten path *eller* pattern |
| `pattern` | string | F.eks. `*.pas` |
| `encoding` | string | Encoding der skal anvendes |

## Encoding-detektion (pipeline)

1. **BOM-check** (UTF-8 / UTF-16 LE+BE / UTF-32 LE+BE) — 100% sikker
2. **Streng UTF-8-validering** — afviser overlong, surrogates, out-of-range
3. **UTF-16 uden BOM** — null-byte-distribution heuristik
4. **8-bit codepage scoring**:
   - **Windows-1252**: foretrukket hvis printable C1-tegn (€, smart quotes, ...)
   - **ISO-8859-1**: foretrukket hvis ingen C1-bytes
   - **ISO-8859-15**: hvis 0xA4 (€) ses uden andre C1-tegn
5. **Fallback**: Windows-1252 (Delphi/Windows-default)

## Sidecar-cache

`.windsurf-encoding.json` placeres i workspace-roden (mappen med `.git`,
`.windsurf`, `*.dproj`, `*.groupproj`, `.svn`, eller `.hg`). Format:

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

`manual: true` markerer entries sat eksplicit via `set_encoding_override` —
disse overskrives ikke af auto-detektion.

## Round-trip eksempel

Fil før (Windows-1252):
```
75 6E 69 74 20 54 65 73 74 3B 0D 0A 2F 2F 20 E6 F8 E5
```

Læst via `read_text_file`:
```
unit Test;\r\n// æøå
```

Skrevet tilbage via `write_text_file` med samme indhold:
```
75 6E 69 74 20 54 65 73 74 3B 0D 0A 2F 2F 20 E6 F8 E5
```

Bytes er identiske — encoding er bevaret.

## Begrænsninger og fremtidige forbedringer

- **Windsurf-integration**: Vi kan ikke garantere at Windsurf rent faktisk kalder
  `write_text_file` i stedet for sin native filskrivning. Det afhænger af
  hvordan tool-beskrivelserne får LLM'en til at vælge værktøjet. Test empirisk.
- **MacRoman**: Detekteres ikke aktivt endnu — koden har struktur til det men
  scoring er minimal.
- **Store filer**: Heuristik kører kun på første 64 KB. Det er hurtigt og
  tilstrækkeligt for typiske kildefiler.
- **Concurrent skrivning**: Cachen er ikke fil-låst. Flere instanser af serveren
  mod samme workspace kan trædepå hinanden.

## Tests

To måder at køre tests:

### Kommandolinje (CI/build)

```cmd
build.bat
```

Bygger og kører DUnitX-konsolrunneren. Output i terminal, exit code 0 ved
success.

### TestInsight i RAD Studio (under udvikling)

`tests\EncodingMCPTests.dpr` har en `{$IFDEF TESTINSIGHT}` der vælger mellem
to runners:

| Build-config | Define | Runner |
|---|---|---|
| Debug (IDE) | `TESTINSIGHT` defineret | TestInsight (resultater til View → TestInsight) |
| Release (build.bat) | ikke defineret | DUnitX-konsol med stdout-output |

`TESTINSIGHT` er sat i `tests\EncodingMCPTests.dproj`'s Debug-konfiguration —
ingen ekstra setup nødvendig efter første gang du har installeret TestInsight.

#### Engangs-setup (kun første gang i en frisk Delphi-installation)

1. **Installér TestInsight**:
   [github.com/Stefan-Glienke/TestInsight](https://github.com/Stefan-Glienke/TestInsight) — gratis open source af Stefan Glienke.
2. **Library Path**: I IDE'en, **Tools → Options → Language → Delphi → Library**
   → tilføj TestInsight `Source`-mappen til **Library Path** for **Win64**.
   På Windows ligger den typisk i
   `%LOCALAPPDATA%\Programs\TestInsight\Source` efter installation.

#### Daglig brug

1. Åbn `tests\EncodingMCPTests.dproj` i RAD Studio.
2. Vælg **Debug**-konfigurationen (default). Compile (Ctrl+F9).
3. Åbn **View → TestInsight** (eller View → Other Windows → TestInsight).
4. Klik **Run** i TestInsight-panelet — resultater dukker op live, og du kan
   dobbeltklikke på en fejl for at hoppe direkte til linjen i editoren.

Tests dækker:

- BOM-detektion (UTF-8/16 LE/BE)
- UTF-8 streng-validering (incl. overlong, surrogates, lone start bytes)
- Codepage-heuristik (Windows-1252 vs ISO-8859-1 vs ISO-8859-15)
- Line-ending detektion (CRLF/LF/Mixed)
- End-to-end round-trip (læs Windows-1252 → skriv tilbage, byte-sammenlign)
- BOM-skrivning og default UTF-8 BOM for nye filer

## Logging

Server logger til `stderr` (aldrig stdout — det reserveret til JSON-RPC).
Niveauer: `debug`, `info` (default), `warning`, `error`. Sæt via miljøvariabel:

```cmd
set ENCODING_MCP_LOG_LEVEL=debug
```

## Bidrag

Pull requests og issues er velkomne. Kør `build.bat` før du sender en PR for at
sikre at testsuiten fortsat passerer.

## Licens

Udgivet under [MIT License](LICENSE) — Copyright (c) 2026 Thomas Vedel.
