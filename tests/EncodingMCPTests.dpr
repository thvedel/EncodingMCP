program EncodingMCPTests;

{$APPTYPE CONSOLE}

{
  Hybrid test runner:

  - In the IDE (with the TestInsight plugin active): define TESTINSIGHT in
    Project Options -> Conditional defines, and add the TestInsight folder
    to the project search path. Results are sent to the TestInsight panel.

  - From build.bat / command line: TESTINSIGHT is not defined, and the runner
    operates as a standard DUnitX console runner.
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
