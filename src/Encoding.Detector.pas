unit Encoding.Detector;

/// <summary>
///   Encoding-detektion via BOM, streng UTF-8-validering og 8-bit codepage-heuristik.
/// </summary>

interface

uses
  System.SysUtils,
  System.Classes,
  Encoding.Types;

type
  /// <summary>
  ///   BOM-detektionsresultat. Indeholder identificeret encoding og BOM-længde i bytes.
  /// </summary>
  TBomInfo = record
    Detected: Boolean;
    EncodingId: TEncodingId;
    BomLength: Integer;
  end;

/// <summary>
///   Tjekker for BOM (UTF-8/16/32 LE+BE) i de første bytes af buffer.
///   Returnerer Detected=False hvis ingen BOM findes.
/// </summary>
function DetectBom(const ABytes: TBytes): TBomInfo;

/// <summary>
///   Detekterer encoding for en byte-sekvens. Pipeline:
///     1) BOM-check
///     2) UTF-8 streng-validering
///     3) UTF-16 uden BOM heuristik (mange null-bytes i lige/ulige positioner)
///     4) 8-bit codepage scoring (heuristik)
///     5) Fallback Windows-1252
/// </summary>
function DetectEncoding(const ABytes: TBytes): TDetectedEncoding;

/// <summary>
///   Detekterer encoding for en fil. Læser maksimalt AMaxSampleBytes bytes til
///   detektion (default 1 MB) — tilstrækkeligt for BOM og statistisk heuristik.
/// </summary>
function DetectFileEncoding(const APath: string;
  AMaxSampleBytes: Integer = 1024 * 1024): TDetectedEncoding;

/// <summary>
///   Analyserer line-ending stil i bytes (CRLF/LF/CR/Mixed).
/// </summary>
function DetectLineEnding(const ABytes: TBytes): TLineEnding;

implementation

uses
  System.Math,
  Encoding.Heuristics;

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
  // ASCII-tekst i UTF-16 LE: høj-byten er 0 → odd-positioner har mange nulls
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
