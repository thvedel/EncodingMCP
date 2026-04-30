program EncodingMCP;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MCP.Logging in 'src\MCP.Logging.pas',
  MCP.Stdio in 'src\MCP.Stdio.pas',
  MCP.Protocol in 'src\MCP.Protocol.pas',
  MCP.Tools in 'src\MCP.Tools.pas',
  MCP.Server in 'src\MCP.Server.pas',
  Encoding.Types in 'src\Encoding.Types.pas',
  Encoding.Heuristics in 'src\Encoding.Heuristics.pas',
  Encoding.Detector in 'src\Encoding.Detector.pas',
  Encoding.Workspace in 'src\Encoding.Workspace.pas',
  Encoding.Cache in 'src\Encoding.Cache.pas',
  Encoding.CacheManager in 'src\Encoding.CacheManager.pas',
  FileIO.Reader in 'src\FileIO.Reader.pas',
  FileIO.Writer in 'src\FileIO.Writer.pas',
  Tools.ReadFile in 'src\Tools.ReadFile.pas',
  Tools.WriteFile in 'src\Tools.WriteFile.pas',
  Tools.DetectEncoding in 'src\Tools.DetectEncoding.pas',
  Tools.SetOverride in 'src\Tools.SetOverride.pas';

procedure ConfigureLogging;
var
  LEnvLevel: string;
begin
  LEnvLevel := GetEnvironmentVariable('ENCODING_MCP_LOG_LEVEL').ToLower;
  if LEnvLevel = 'debug' then
    TLog.SetMinLevel(TLogLevel.Debug)
  else if LEnvLevel = 'warning' then
    TLog.SetMinLevel(TLogLevel.Warning)
  else if LEnvLevel = 'error' then
    TLog.SetMinLevel(TLogLevel.Error)
  else
    TLog.SetMinLevel(TLogLevel.Info);
end;

procedure RegisterTools(ARegistry: TToolRegistry; ACacheManager: TCacheManager);
begin
  ARegistry.Register(TReadFileTool.Create(ACacheManager));
  ARegistry.Register(TWriteFileTool.Create(ACacheManager));
  ARegistry.Register(TDetectEncodingTool.Create(ACacheManager));
  ARegistry.Register(TSetOverrideTool.Create(ACacheManager));
end;

var
  LRegistry: TToolRegistry;
  LCacheManager: TCacheManager;
  LServer: TMcpServer;

begin
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  ConfigureLogging;
  try
    LCacheManager := TCacheManager.Create;
    try
      LRegistry := TToolRegistry.Create;
      try
        RegisterTools(LRegistry, LCacheManager);
        LServer := TMcpServer.Create(LRegistry);
        try
          LServer.Run;
        finally
          LServer.Free;
        end;
      finally
        LRegistry.Free;
      end;
    finally
      LCacheManager.Free;
    end;
  except
    on E: Exception do
    begin
      TLog.Error('Fatal: %s: %s', [E.ClassName, E.Message]);
      ExitCode := 1;
    end;
  end;
end.
