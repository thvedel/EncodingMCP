unit Encoding.Heuristics;

/// <summary>
///   Heuristic scoring of 8-bit codepage candidates based on byte frequency
///   and language characteristics.
/// </summary>

interface

uses
  System.SysUtils,
  Encoding.Types;

type
  /// <summary>Score for a single encoding candidate in [0..1].</summary>
  TCodepageScore = record
    EncodingId: TEncodingId;
    Score: Double;
  end;

  TCodepageScores = TArray<TCodepageScore>;

/// <summary>
///   Validates a byte sequence as strictly conformant UTF-8 (without BOM).
///   Rejects overlong encodings, surrogates, and out-of-range codepoints.
/// </summary>
/// <returns>True if bytes constitute valid UTF-8.</returns>
function IsValidUtf8(const ABytes: TBytes): Boolean;

/// <summary>
///   Returns True if the byte sequence contains only ASCII (0x00..0x7F)
///   and is not empty.
/// </summary>
function IsPureAscii(const ABytes: TBytes): Boolean;

/// <summary>
///   Counts how many bytes fall in the C1 control zone (0x80..0x9F).
/// </summary>
function CountC1Bytes(const ABytes: TBytes): Integer;

/// <summary>
///   Counts bytes that are valid printable Windows-1252 characters in the C1 zone
///   (€, ‚, ƒ, „, …, †, ‡, ˆ, ‰, Š, ‹, Œ, Ž, ‘’–—˜™š›œžŸ).
/// </summary>
function CountValidWin1252C1(const ABytes: TBytes): Integer;

/// <summary>
///   Counts bytes that are undefined in Windows-1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D).
///   If present, the file is likely NOT Windows-1252.
/// </summary>
function CountUndefinedWin1252(const ABytes: TBytes): Integer;

/// <summary>
///   Scores candidate encodings and returns them sorted by probability.
///   Used when BOM is absent and UTF-8 validation fails.
/// </summary>
function ScoreCodepages(const ABytes: TBytes): TCodepageScores;

implementation

uses
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults;

function IsValidUtf8(const ABytes: TBytes): Boolean;
var
  I, LLen, LContinuation, LCodepoint, LMin: Integer;
  LByte: Byte;
begin
  LLen := Length(ABytes);
  I := 0;
  while I < LLen do
  begin
    LByte := ABytes[I];
    if LByte < $80 then
    begin
      Inc(I);
      Continue;
    end;
    if (LByte and $E0) = $C0 then
    begin
      // 2-byte sequence
      LContinuation := 1;
      LCodepoint := LByte and $1F;
      LMin := $80;
    end
    else if (LByte and $F0) = $E0 then
    begin
      LContinuation := 2;
      LCodepoint := LByte and $0F;
      LMin := $800;
    end
    else if (LByte and $F8) = $F0 then
    begin
      LContinuation := 3;
      LCodepoint := LByte and $07;
      LMin := $10000;
    end
    else
      Exit(False);
    if I + LContinuation >= LLen then
      Exit(False);
    while LContinuation > 0 do
    begin
      Inc(I);
      LByte := ABytes[I];
      if (LByte and $C0) <> $80 then
        Exit(False);
      LCodepoint := (LCodepoint shl 6) or (LByte and $3F);
      Dec(LContinuation);
    end;
    if LCodepoint < LMin then
      Exit(False); // overlong
    if (LCodepoint >= $D800) and (LCodepoint <= $DFFF) then
      Exit(False); // surrogate
    if LCodepoint > $10FFFF then
      Exit(False);
    Inc(I);
  end;
  Result := True;
end;

function IsPureAscii(const ABytes: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(ABytes) = 0 then
    Exit(False);
  for I := 0 to High(ABytes) do
    if ABytes[I] >= $80 then
      Exit(False);
  Result := True;
end;

function CountC1Bytes(const ABytes: TBytes): Integer;
var
  I: Integer;
  LByte: Byte;
begin
  Result := 0;
  for I := 0 to High(ABytes) do
  begin
    LByte := ABytes[I];
    if (LByte >= $80) and (LByte <= $9F) then
      Inc(Result);
  end;
end;

function IsUndefinedWin1252Byte(AByte: Byte): Boolean;
begin
  Result := (AByte = $81) or (AByte = $8D) or (AByte = $8F) or
            (AByte = $90) or (AByte = $9D);
end;

function CountValidWin1252C1(const ABytes: TBytes): Integer;
var
  I: Integer;
  LByte: Byte;
begin
  Result := 0;
  for I := 0 to High(ABytes) do
  begin
    LByte := ABytes[I];
    if (LByte >= $80) and (LByte <= $9F) and not IsUndefinedWin1252Byte(LByte) then
      Inc(Result);
  end;
end;

function CountUndefinedWin1252(const ABytes: TBytes): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ABytes) do
    if IsUndefinedWin1252Byte(ABytes[I]) then
      Inc(Result);
end;

function ScoreCodepages(const ABytes: TBytes): TCodepageScores;
var
  LValidC1, LUndefinedW1252, LHighBytes, LEuroAtA4: Integer;
  LWin1252, LIso88591, LIso885915: Double;
  I: Integer;
  LByte: Byte;
  LScores: TList<TCodepageScore>;
  LScore: TCodepageScore;
begin
  LValidC1 := CountValidWin1252C1(ABytes);
  LUndefinedW1252 := CountUndefinedWin1252(ABytes);
  LHighBytes := 0;
  LEuroAtA4 := 0;
  for I := 0 to High(ABytes) do
  begin
    LByte := ABytes[I];
    if LByte >= $80 then
      Inc(LHighBytes);
    if LByte = $A4 then
      Inc(LEuroAtA4);
  end;

  // Windows-1252: strong if we see printable C1 chars, weakened by undefined bytes
  if LValidC1 > 0 then
    LWin1252 := 0.85 + Min(0.10, LValidC1 / 100.0)
  else if LUndefinedW1252 > 0 then
    LWin1252 := 0.30 // undefined bytes present - poor match for Win1252
  else
    LWin1252 := 0.65; // default fallback strength when no C1 seen

  // ISO-8859-1: strong if no C1 bytes and no Euro suspicion
  if LValidC1 + LUndefinedW1252 = 0 then
    LIso88591 := 0.55
  else
    LIso88591 := 0.10; // ISO-8859-1 has no characters in 0x80..0x9F

  // ISO-8859-15: like 8859-1 but preferred if 0xA4 occurs (Euro sign)
  if LValidC1 + LUndefinedW1252 = 0 then
  begin
    if LEuroAtA4 > 0 then
      LIso885915 := 0.60
    else
      LIso885915 := 0.40;
  end
  else
    LIso885915 := 0.10;

  // If the file is pure ASCII (no high bytes), all 8-bit codepages are equivalent.
  // We prioritize Windows-1252 as default for Delphi/Windows context.
  if LHighBytes = 0 then
  begin
    LWin1252 := 0.50;
    LIso88591 := 0.45;
    LIso885915 := 0.40;
  end;

  LScores := TList<TCodepageScore>.Create;
  try
    LScore.EncodingId := TEncodingId.Windows1252;
    LScore.Score := LWin1252;
    LScores.Add(LScore);
    LScore.EncodingId := TEncodingId.Iso885915;
    LScore.Score := LIso885915;
    LScores.Add(LScore);
    LScore.EncodingId := TEncodingId.Iso88591;
    LScore.Score := LIso88591;
    LScores.Add(LScore);
    LScores.Sort(TComparer<TCodepageScore>.Construct(
      function(const L, R: TCodepageScore): Integer
      begin
        Result := CompareValue(R.Score, L.Score);
      end));
    Result := LScores.ToArray;
  finally
    LScores.Free;
  end;
end;

end.
