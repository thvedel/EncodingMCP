unit Encoding.Types;

/// <summary>
///   Fælles datatyper for encoding-detektion og -konvertering.
/// </summary>

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils;

type
  /// <summary>Identifikator for en understøttet encoding.</summary>
  TEncodingId = (
    Unknown,
    Ascii,
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
    Windows1252,
    Iso88591,
    Iso885915,
    MacRoman
  );

  TLineEnding = (Unknown, Lf, CrLf, Cr, Mixed);

  /// <summary>Resultat af encoding-detektion.</summary>
  TDetectedEncoding = record
    Id: TEncodingId;
    HasBom: Boolean;
    Confidence: Double; // 0.0..1.0
    LineEnding: TLineEnding;
    function Name: string;
    function CodePage: Integer;
    /// <summary>
    ///   Returnerer en TEncoding-instans. Kald TEncoding.IsStandardEncoding
    ///   før Free, da standard-encodings (UTF-8, Unicode) ikke må frigives.
    /// </summary>
    function CreateEncoding: TEncoding;
  end;

function EncodingIdFromName(const AName: string): TEncodingId;
function EncodingIdName(AId: TEncodingId): string;
function EncodingIdCodePage(AId: TEncodingId): Integer;
function LineEndingName(ALineEnding: TLineEnding): string;
function LineEndingFromName(const AName: string): TLineEnding;

implementation

const
  CP_WINDOWS_1252 = 1252;
  CP_ISO_8859_1 = 28591;
  CP_ISO_8859_15 = 28605;
  CP_MAC_ROMAN = 10000;

{ TDetectedEncoding }

function TDetectedEncoding.Name: string;
begin
  Result := EncodingIdName(Id);
end;

function TDetectedEncoding.CodePage: Integer;
begin
  Result := EncodingIdCodePage(Id);
end;

function TDetectedEncoding.CreateEncoding: TEncoding;
begin
  case Id of
    TEncodingId.Ascii:
      Result := TEncoding.ASCII;
    TEncodingId.Utf8:
      Result := TEncoding.UTF8;
    TEncodingId.Utf16Le:
      Result := TEncoding.Unicode;
    TEncodingId.Utf16Be:
      Result := TEncoding.BigEndianUnicode;
    TEncodingId.Utf32Le,
    TEncodingId.Utf32Be:
      Result := TEncoding.GetEncoding(CodePage);
  else
    Result := TEncoding.GetEncoding(CodePage);
  end;
end;

function EncodingIdName(AId: TEncodingId): string;
begin
  case AId of
    TEncodingId.Unknown: Result := 'Unknown';
    TEncodingId.Ascii: Result := 'ASCII';
    TEncodingId.Utf8: Result := 'UTF-8';
    TEncodingId.Utf16Le: Result := 'UTF-16LE';
    TEncodingId.Utf16Be: Result := 'UTF-16BE';
    TEncodingId.Utf32Le: Result := 'UTF-32LE';
    TEncodingId.Utf32Be: Result := 'UTF-32BE';
    TEncodingId.Windows1252: Result := 'Windows-1252';
    TEncodingId.Iso88591: Result := 'ISO-8859-1';
    TEncodingId.Iso885915: Result := 'ISO-8859-15';
    TEncodingId.MacRoman: Result := 'MacRoman';
  else
    Result := 'Unknown';
  end;
end;

function EncodingIdCodePage(AId: TEncodingId): Integer;
begin
  case AId of
    TEncodingId.Ascii: Result := 20127;
    TEncodingId.Utf8: Result := 65001;
    TEncodingId.Utf16Le: Result := 1200;
    TEncodingId.Utf16Be: Result := 1201;
    TEncodingId.Utf32Le: Result := 12000;
    TEncodingId.Utf32Be: Result := 12001;
    TEncodingId.Windows1252: Result := CP_WINDOWS_1252;
    TEncodingId.Iso88591: Result := CP_ISO_8859_1;
    TEncodingId.Iso885915: Result := CP_ISO_8859_15;
    TEncodingId.MacRoman: Result := CP_MAC_ROMAN;
  else
    Result := 0;
  end;
end;

function EncodingIdFromName(const AName: string): TEncodingId;
var
  LNorm: string;
begin
  LNorm := AName.ToUpper.Replace('_', '-').Replace(' ', '');
  if (LNorm = 'UTF-8') or (LNorm = 'UTF8') then Exit(TEncodingId.Utf8);
  if (LNorm = 'UTF-16') or (LNorm = 'UTF-16LE') or (LNorm = 'UTF16LE') then Exit(TEncodingId.Utf16Le);
  if (LNorm = 'UTF-16BE') or (LNorm = 'UTF16BE') then Exit(TEncodingId.Utf16Be);
  if (LNorm = 'UTF-32') or (LNorm = 'UTF-32LE') or (LNorm = 'UTF32LE') then Exit(TEncodingId.Utf32Le);
  if (LNorm = 'UTF-32BE') or (LNorm = 'UTF32BE') then Exit(TEncodingId.Utf32Be);
  if (LNorm = 'WINDOWS-1252') or (LNorm = 'CP1252') or (LNorm = '1252') or (LNorm = 'ANSI') then
    Exit(TEncodingId.Windows1252);
  if (LNorm = 'ISO-8859-1') or (LNorm = 'LATIN1') or (LNorm = 'LATIN-1') then Exit(TEncodingId.Iso88591);
  if (LNorm = 'ISO-8859-15') or (LNorm = 'LATIN9') or (LNorm = 'LATIN-9') then Exit(TEncodingId.Iso885915);
  if (LNorm = 'MACROMAN') or (LNorm = 'MAC-ROMAN') then Exit(TEncodingId.MacRoman);
  if LNorm = 'ASCII' then Exit(TEncodingId.Ascii);
  Result := TEncodingId.Unknown;
end;

function LineEndingName(ALineEnding: TLineEnding): string;
begin
  case ALineEnding of
    TLineEnding.Lf: Result := 'LF';
    TLineEnding.CrLf: Result := 'CRLF';
    TLineEnding.Cr: Result := 'CR';
    TLineEnding.Mixed: Result := 'Mixed';
  else
    Result := 'Unknown';
  end;
end;

function LineEndingFromName(const AName: string): TLineEnding;
var
  LNorm: string;
begin
  LNorm := AName.ToUpper;
  if LNorm = 'LF' then Exit(TLineEnding.Lf);
  if LNorm = 'CRLF' then Exit(TLineEnding.CrLf);
  if LNorm = 'CR' then Exit(TLineEnding.Cr);
  Result := TLineEnding.Unknown;
end;

end.
