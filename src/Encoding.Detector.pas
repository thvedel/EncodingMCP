unit Encoding.Detector;

/// <summary>
///   Encoding detection via BOM, strict UTF-8 validation, and 8-bit codepage heuristics.
/// </summary>

interface

uses
  System.SysUtils,
  System.Classes,
  Encoding.Types;

type
  /// <summary>
  ///   BOM detection result. Contains identified encoding and BOM length in bytes.
  /// </summary>
  TBomInfo = record
    Detected: Boolean;
    EncodingId: TEncodingId;
    BomLength: Integer;
  end;

/// <summary>
///   Checks for BOM (UTF-8/16/32 LE+BE) in the first bytes of the buffer.
///   Returns Detected=False if no BOM is found.
/// </summary>
function DetectBom(const ABytes: TBytes): TBomInfo;

/// <summary>
///   Detects encoding for a byte sequence. Pipeline:
///     1) BOM check
///     2) Strict UTF-8 validation
///     3) UTF-16 without BOM heuristic (many null bytes in even/odd positions)
///     4) 8-bit codepage scoring (heuristic)
///     5) Fallback Windows-1252
/// </summary>
function DetectEncoding(const ABytes: TBytes): TDetectedEncoding;

/// <summary>
///   Detects encoding for a file. Reads at most AMaxSampleBytes bytes for
///   detection (default 1 MB) — sufficient for BOM and statistical heuristics.
/// </summary>
function DetectFileEncoding(const APath: string;
  AMaxSampleBytes: Integer = 1024 * 1024): TDetectedEncoding;

/// <summary>
///   Analyzes line-ending style in bytes (CRLF/LF/CR/Mixed).
/// </summary>
function DetectLineEnding(const ABytes: TBytes): TLineEnding;

/// <summary>
///   Returns True when the bytes are a binary Delphi form (DFM/XFM/FMX):
///   either the raw 'TPF0' stream signature or a resource header
///   ($FF $0A $00 ...) followed by 'TPF0'. Such files are not text and must
///   not be decoded or rewritten as text.
/// </summary>
function IsBinaryDfm(const ABytes: TBytes): Boolean;

implementation

uses
  System.Math,
  Encoding.Heuristics;

function IsBinaryDfm(const ABytes: TBytes): Boolean;
const
  SIGNATURE: array[0..3] of Byte = ($54, $50, $46, $30); // 'TPF0'
  // The resource header holds the upper-case form name, flags and size
  // before the signature; real headers are far shorter than this limit.
  MAX_HEADER = 512;

  function SignatureAt(AOffset: Integer): Boolean;
  begin
    Result := (AOffset + 4 <= Length(ABytes)) and
      (ABytes[AOffset] = SIGNATURE[0]) and (ABytes[AOffset + 1] = SIGNATURE[1]) and
      (ABytes[AOffset + 2] = SIGNATURE[2]) and (ABytes[AOffset + 3] = SIGNATURE[3]);
  end;

var
  I: Integer;
begin
  if SignatureAt(0) then
    Exit(True);
  if (Length(ABytes) < 8) or (ABytes[0] <> $FF) or (ABytes[1] <> $0A) or
     (ABytes[2] <> $00) then
    Exit(False);
  for I := 3 to Min(MAX_HEADER, Length(ABytes) - 4) do
    if SignatureAt(I) then
      Exit(True);
  Result := False;
end;

function DetectBom(const ABytes: TBytes): TBomInfo;
begin
  Result.Detected := False;
  Result.EncodingId := TEncodingId.Unknown;
  Result.BomLength := 0;
  if Length(ABytes) >= 4 then
  begin
    if (ABytes[0] = $FF) and (ABytes[1] = $FE) and (ABytes[2] = $00) and (ABytes[3] = $00) then
    begin
      Result.Detected := True;
      Result.EncodingId := TEncodingId.Utf32Le;
      Result.BomLength := 4;
      Exit;
    end;
    if (ABytes[0] = $00) and (ABytes[1] = $00) and (ABytes[2] = $FE) and (ABytes[3] = $FF) then
    begin
      Result.Detected := True;
      Result.EncodingId := TEncodingId.Utf32Be;
      Result.BomLength := 4;
      Exit;
    end;
  end;
  if Length(ABytes) >= 3 then
  begin
    if (ABytes[0] = $EF) and (ABytes[1] = $BB) and (ABytes[2] = $BF) then
    begin
      Result.Detected := True;
      Result.EncodingId := TEncodingId.Utf8;
      Result.BomLength := 3;
      Exit;
    end;
  end;
  if Length(ABytes) >= 2 then
  begin
    if (ABytes[0] = $FF) and (ABytes[1] = $FE) then
    begin
      Result.Detected := True;
      Result.EncodingId := TEncodingId.Utf16Le;
      Result.BomLength := 2;
      Exit;
    end;
    if (ABytes[0] = $FE) and (ABytes[1] = $FF) then
    begin
      Result.Detected := True;
      Result.EncodingId := TEncodingId.Utf16Be;
      Result.BomLength := 2;
      Exit;
    end;
  end;
end;

function CountNullsInPositions(const ABytes: TBytes; AOffset: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := AOffset;
  while I < Length(ABytes) do
  begin
    if ABytes[I] = 0 then
      Inc(Result);
    Inc(I, 2);
  end;
end;

function DetectUtf16WithoutBom(const ABytes: TBytes; out AId: TEncodingId): Boolean;
var
  LLen, LEvenNulls, LOddNulls, LTotalPairs: Integer;
  LEvenRatio, LOddRatio: Double;
begin
  Result := False;
  LLen := Length(ABytes);
  if (LLen < 32) or ((LLen mod 2) <> 0) then
    Exit;
  LEvenNulls := CountNullsInPositions(ABytes, 0);
  LOddNulls := CountNullsInPositions(ABytes, 1);
  LTotalPairs := LLen div 2;
  if LTotalPairs = 0 then
    Exit;
  LEvenRatio := LEvenNulls / LTotalPairs;
  LOddRatio := LOddNulls / LTotalPairs;
  // ASCII text in UTF-16 LE: high byte is 0 → odd positions have many nulls
  if (LOddRatio > 0.30) and (LEvenRatio < 0.05) then
  begin
    AId := TEncodingId.Utf16Le;
    Exit(True);
  end;
  if (LEvenRatio > 0.30) and (LOddRatio < 0.05) then
  begin
    AId := TEncodingId.Utf16Be;
    Exit(True);
  end;
end;

function DetectLineEnding(const ABytes: TBytes): TLineEnding;
var
  I, LLfOnly, LCrLf, LCrOnly: Integer;
begin
  LLfOnly := 0;
  LCrLf := 0;
  LCrOnly := 0;
  I := 0;
  while I < Length(ABytes) do
  begin
    if ABytes[I] = 13 then
    begin
      if (I + 1 < Length(ABytes)) and (ABytes[I + 1] = 10) then
      begin
        Inc(LCrLf);
        Inc(I, 2);
        Continue;
      end
      else
        Inc(LCrOnly);
    end
    else if ABytes[I] = 10 then
      Inc(LLfOnly);
    Inc(I);
  end;
  if (LLfOnly = 0) and (LCrLf = 0) and (LCrOnly = 0) then
    Exit(TLineEnding.Unknown);
  if (LCrLf > 0) and (LLfOnly = 0) and (LCrOnly = 0) then
    Exit(TLineEnding.CrLf);
  if (LLfOnly > 0) and (LCrLf = 0) and (LCrOnly = 0) then
    Exit(TLineEnding.Lf);
  if (LCrOnly > 0) and (LLfOnly = 0) and (LCrLf = 0) then
    Exit(TLineEnding.Cr);
  Result := TLineEnding.Mixed;
end;

function DetectEncoding(const ABytes: TBytes): TDetectedEncoding;
var
  LBom: TBomInfo;
  LUtf16Id: TEncodingId;
  LScores: TCodepageScores;
  LSample: TBytes;
begin
  Result.Id := TEncodingId.Unknown;
  Result.HasBom := False;
  Result.Confidence := 0.0;
  Result.LineEnding := DetectLineEnding(ABytes);

  if Length(ABytes) = 0 then
  begin
    Result.Id := TEncodingId.Utf8;
    Result.Confidence := 0.5;
    Exit;
  end;

  // 1) BOM
  LBom := DetectBom(ABytes);
  if LBom.Detected then
  begin
    Result.Id := LBom.EncodingId;
    Result.HasBom := True;
    Result.Confidence := 1.0;
    Exit;
  end;

  // 2) UTF-8 streng-validering
  if IsValidUtf8(ABytes) then
  begin
    if IsPureAscii(ABytes) then
    begin
      Result.Id := TEncodingId.Ascii;
      Result.Confidence := 0.99;
    end
    else
    begin
      Result.Id := TEncodingId.Utf8;
      Result.Confidence := 0.95;
    end;
    Exit;
  end;

  // 3) UTF-16 uden BOM
  if DetectUtf16WithoutBom(ABytes, LUtf16Id) then
  begin
    Result.Id := LUtf16Id;
    Result.Confidence := 0.85;
    Exit;
  end;

  // 4) 8-bit heuristik
  LSample := ABytes;
  if Length(LSample) > 65536 then
  begin
    SetLength(LSample, 65536);
    Move(ABytes[0], LSample[0], 65536);
  end;
  LScores := ScoreCodepages(LSample);
  if Length(LScores) > 0 then
  begin
    Result.Id := LScores[0].EncodingId;
    Result.Confidence := LScores[0].Score;
    Exit;
  end;

  // 5) Fallback
  Result.Id := TEncodingId.Windows1252;
  Result.Confidence := 0.50;
end;

function DetectFileEncoding(const APath: string;
  AMaxSampleBytes: Integer): TDetectedEncoding;
var
  LStream: TFileStream;
  LBytes: TBytes;
  LToRead: Int64;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    LToRead := LStream.Size;
    if LToRead > AMaxSampleBytes then
      LToRead := AMaxSampleBytes;
    SetLength(LBytes, LToRead);
    if LToRead > 0 then
      LStream.ReadBuffer(LBytes[0], LToRead);
  finally
    LStream.Free;
  end;
  Result := DetectEncoding(LBytes);
end;

end.
