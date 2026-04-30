unit MCP.Logging;

/// <summary>
///   Stderr-baseret logging. Må aldrig skrive til stdout, da stdout er reserveret
///   til MCP-protokolbeskeder.
/// </summary>

interface

{$SCOPEDENUMS ON}

type
  TLogLevel = (Debug, Info, Warning, Error);

  /// <summary>
  ///   Statisk logger der skriver til stderr med tidsstempel og niveau.
  /// </summary>
  TLog = class
  strict private
    class var FMinLevel: TLogLevel;
    class procedure WriteLine(ALevel: TLogLevel; const AMessage: string); static;
  public
    class constructor Create;
    /// <summary>Sætter minimums-loglevel. Beskeder under dette niveau ignoreres.</summary>
    class procedure SetMinLevel(ALevel: TLogLevel); static;
    class procedure Debug(const AMessage: string); overload; static;
    class procedure Debug(const AFormat: string; const AArgs: array of const); overload; static;
    class procedure Info(const AMessage: string); overload; static;
    class procedure Info(const AFormat: string; const AArgs: array of const); overload; static;
    class procedure Warning(const AMessage: string); overload; static;
    class procedure Warning(const AFormat: string; const AArgs: array of const); overload; static;
    class procedure Error(const AMessage: string); overload; static;
    class procedure Error(const AFormat: string; const AArgs: array of const); overload; static;
  end;

implementation

uses
  System.SysUtils,
  Winapi.Windows;

{ TLog }

class constructor TLog.Create;
begin
  FMinLevel := TLogLevel.Info;
end;

class procedure TLog.SetMinLevel(ALevel: TLogLevel);
begin
  FMinLevel := ALevel;
end;

class procedure TLog.WriteLine(ALevel: TLogLevel; const AMessage: string);
const
  LEVEL_NAMES: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
var
  LLine: string;
  LBytes: TBytes;
  LWritten: DWORD;
  LHandle: THandle;
begin
  if ALevel < FMinLevel then
    Exit;
  LLine := Format('[%s] [%s] %s'#10,
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), LEVEL_NAMES[ALevel], AMessage]);
  LBytes := TEncoding.UTF8.GetBytes(LLine);
  LHandle := GetStdHandle(STD_ERROR_HANDLE);
  if (LHandle <> 0) and (LHandle <> INVALID_HANDLE_VALUE) and (Length(LBytes) > 0) then
    WriteFile(LHandle, LBytes[0], Length(LBytes), LWritten, nil);
end;

class procedure TLog.Debug(const AMessage: string);
begin
  WriteLine(TLogLevel.Debug, AMessage);
end;

class procedure TLog.Debug(const AFormat: string; const AArgs: array of const);
begin
  WriteLine(TLogLevel.Debug, Format(AFormat, AArgs));
end;

class procedure TLog.Info(const AMessage: string);
begin
  WriteLine(TLogLevel.Info, AMessage);
end;

class procedure TLog.Info(const AFormat: string; const AArgs: array of const);
begin
  WriteLine(TLogLevel.Info, Format(AFormat, AArgs));
end;

class procedure TLog.Warning(const AMessage: string);
begin
  WriteLine(TLogLevel.Warning, AMessage);
end;

class procedure TLog.Warning(const AFormat: string; const AArgs: array of const);
begin
  WriteLine(TLogLevel.Warning, Format(AFormat, AArgs));
end;

class procedure TLog.Error(const AMessage: string);
begin
  WriteLine(TLogLevel.Error, AMessage);
end;

class procedure TLog.Error(const AFormat: string; const AArgs: array of const);
begin
  WriteLine(TLogLevel.Error, Format(AFormat, AArgs));
end;

end.
