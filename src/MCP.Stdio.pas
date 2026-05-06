unit MCP.Stdio;

/// <summary>
///   Line-based UTF-8 stdio transport for MCP. Reads/writes directly via
///   Windows handles to avoid Pascal text-mode conversion and codepage pitfalls.
/// </summary>

interface

uses
  System.Classes,
  System.SysUtils;

type
  /// <summary>
  ///   Stdio transport that reads line-delimited UTF-8 messages from stdin
  ///   and writes UTF-8 lines to stdout.
  /// </summary>
  TStdioTransport = class
  strict private
    FStdInHandle: THandle;
    FStdOutHandle: THandle;
    FInputBuffer: TBytes;
    FInputClosed: Boolean;
    function FillBuffer: Boolean;
    function ExtractLine(out ALine: string): Boolean;
  public
    constructor Create;
    /// <summary>
    ///   Reads one UTF-8 line from stdin. CR/LF and CRLF are accepted as line breaks.
    /// </summary>
    /// <returns>True if a line was read, False on EOF.</returns>
    function TryReadLine(out ALine: string): Boolean;
    /// <summary>
    ///   Writes a UTF-8 line (with trailing LF) to stdout and flushes.
    /// </summary>
    procedure WriteLine(const ALine: string);
  end;

implementation

uses
  Winapi.Windows,
  MCP.Logging;

const
  READ_CHUNK_SIZE = 4096;

constructor TStdioTransport.Create;
begin
  inherited Create;
  FStdInHandle := GetStdHandle(STD_INPUT_HANDLE);
  FStdOutHandle := GetStdHandle(STD_OUTPUT_HANDLE);
  SetLength(FInputBuffer, 0);
  FInputClosed := False;
end;

function TStdioTransport.FillBuffer: Boolean;
var
  LChunk: array[0..READ_CHUNK_SIZE - 1] of Byte;
  LRead: DWORD;
  LIdx: Integer;
begin
  Result := False;
  if FInputClosed then
    Exit;
  LRead := 0;
  if not ReadFile(FStdInHandle, LChunk, READ_CHUNK_SIZE, LRead, nil) then
  begin
    FInputClosed := True;
    Exit;
  end;
  if LRead = 0 then
  begin
    FInputClosed := True;
    Exit;
  end;
  LIdx := Length(FInputBuffer);
  SetLength(FInputBuffer, LIdx + Integer(LRead));
  Move(LChunk[0], FInputBuffer[LIdx], LRead);
  Result := True;
end;

function TStdioTransport.ExtractLine(out ALine: string): Boolean;
var
  LIdx, LLineLen: Integer;
  LLineBytes: TBytes;
begin
  Result := False;
  ALine := '';
  for LIdx := 0 to Length(FInputBuffer) - 1 do
  begin
    if FInputBuffer[LIdx] = 10 then // LF
    begin
      LLineLen := LIdx;
      // Strip trailing CR
      if (LLineLen > 0) and (FInputBuffer[LLineLen - 1] = 13) then
        Dec(LLineLen);
      SetLength(LLineBytes, LLineLen);
      if LLineLen > 0 then
        Move(FInputBuffer[0], LLineBytes[0], LLineLen);
      ALine := TEncoding.UTF8.GetString(LLineBytes);
      // Remove consumed bytes including the LF
      if LIdx + 1 < Length(FInputBuffer) then
      begin
        Move(FInputBuffer[LIdx + 1], FInputBuffer[0], Length(FInputBuffer) - LIdx - 1);
        SetLength(FInputBuffer, Length(FInputBuffer) - LIdx - 1);
      end
      else
        SetLength(FInputBuffer, 0);
      Exit(True);
    end;
  end;
end;

function TStdioTransport.TryReadLine(out ALine: string): Boolean;
begin
  ALine := '';
  while True do
  begin
    if ExtractLine(ALine) then
      Exit(True);
    if FInputClosed then
    begin
      // If there are leftovers without trailing LF, return them as last line
      if Length(FInputBuffer) > 0 then
      begin
        ALine := TEncoding.UTF8.GetString(FInputBuffer);
        SetLength(FInputBuffer, 0);
        Exit(True);
      end;
      Exit(False);
    end;
    if not FillBuffer then
    begin
      if Length(FInputBuffer) > 0 then
      begin
        ALine := TEncoding.UTF8.GetString(FInputBuffer);
        SetLength(FInputBuffer, 0);
        Exit(True);
      end;
      Exit(False);
    end;
  end;
end;

procedure TStdioTransport.WriteLine(const ALine: string);
var
  LBytes: TBytes;
  LWritten: DWORD;
  LNL: Byte;
begin
  LBytes := TEncoding.UTF8.GetBytes(ALine);
  if Length(LBytes) > 0 then
    WriteFile(FStdOutHandle, LBytes[0], Length(LBytes), LWritten, nil);
  LNL := 10;
  WriteFile(FStdOutHandle, LNL, 1, LWritten, nil);
  FlushFileBuffers(FStdOutHandle);
end;

end.
