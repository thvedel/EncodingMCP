program EncodingMCPTests;

{$APPTYPE CONSOLE}

{
  Hybrid testrunner:

  - I IDE'en (med TestInsight-pluginnen aktiv): definér TESTINSIGHT i
    Project Options -> Conditional defines, og tilføj TestInsight-mappen
    til projektets search path. Resultater sendes til TestInsight-panelet.

  - Fra build.bat / kommandolinje: TESTINSIGHT er ikke defineret, og runneren
    kører som en almindelig DUnitX-konsol-runner.
}

uses
  System.SysUtils,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ENDIF }
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  MCP.Logging in '..\src\MCP.Logging.pas',
  Encoding.Types in '..\src\Encoding.Types.pas',
  Encoding.Heuristics in '..\src\Encoding.Heuristics.pas',
  Encoding.Detector in '..\src\Encoding.Detector.pas',
  Encoding.Workspace in '..\src\Encoding.Workspace.pas',
  Encoding.Cache in '..\src\Encoding.Cache.pas',
  Encoding.CacheManager in '..\src\Encoding.CacheManager.pas',
  FileIO.Reader in '..\src\FileIO.Reader.pas',
  FileIO.Writer in '..\src\FileIO.Writer.pas',
  Tests.Encoding.Detector in 'Tests.Encoding.Detector.pas',
  Tests.Encoding.Heuristics in 'Tests.Encoding.Heuristics.pas',
  Tests.FileIO.Roundtrip in 'Tests.FileIO.Roundtrip.pas';

procedure RunConsole;
var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
begin
  TDUnitX.CheckCommandLine;
  LRunner := TDUnitX.CreateRunner;
  LRunner.UseRTTI := True;
  LLogger := TDUnitXConsoleLogger.Create(True);
  LRunner.AddLogger(LLogger);
  LResults := LRunner.Execute;
  if LResults.AllPassed then
    ExitCode := 0
  else
    ExitCode := 1;
end;

begin
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    {$IFDEF TESTINSIGHT}
    RunRegisteredTests;
    {$ELSE}
    RunConsole;
    {$ENDIF}
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
