unit MCP.Tools;

/// <summary>
///   Tool-interface og registreringsmekanisme for MCP-værktøjer.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  /// <summary>
  ///   Et MCP-værktøj. Hvert værktøj eksponerer et navn, beskrivelse, JSON Schema
  ///   for parametre og en eksekveringsmetode.
  /// </summary>
  IMcpTool = interface
    ['{B7F6F4A8-2C19-4F4A-8D19-9E5B7C2C9A11}']
    function GetName: string;
    function GetDescription: string;
    /// <summary>
    ///   Returnerer et JSON Schema object der beskriver tool-parametrene.
    ///   Kalderen overtager ejerskab.
    /// </summary>
    function BuildInputSchema: TJSONObject;
    /// <summary>
    ///   Udfører værktøjet. Returnerer et MCP-content-objekt med
    ///   "content"-array og evt. "isError". Kalderen overtager ejerskab.
    /// </summary>
    /// <param name="AArguments">JSON-argumenter (kan være nil for parameterløse tools).</param>
    /// <exception cref="Exception">Ved interne fejl. Dispatcher omformer til MCP error-respons.</exception>
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

  /// <summary>
  ///   Registry for IMcpTool-instanser, slået op via navn.
  /// </summary>
  TToolRegistry = class
  strict private
    FTools: TDictionary<string, IMcpTool>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(const ATool: IMcpTool);
    function TryGet(const AName: string; out ATool: IMcpTool): Boolean;
    function Names: TArray<string>;
    /// <summary>Bygger MCP "tools/list" JSON-array. Kalderen overtager ejerskab.</summary>
    function BuildListJson: TJSONArray;
  end;

/// <summary>
///   Bygger et standard MCP tool-result med en enkelt tekstblok.
///   Kalderen overtager ejerskab.
/// </summary>
function BuildTextResult(const AText: string; AIsError: Boolean = False): TJSONObject;

/// <summary>
///   Bygger et MCP tool-result hvor teksten er en serialiseret JSON-værdi
///   (typisk pretty-printed JSON). Kalderen overtager ejerskab.
/// </summary>
function BuildJsonTextResult(AJson: TJSONValue; AIsError: Boolean = False): TJSONObject;

implementation

{ TToolRegistry }

constructor TToolRegistry.Create;
begin
  inherited;
  FTools := TDictionary<string, IMcpTool>.Create;
end;

destructor TToolRegistry.Destroy;
begin
  FTools.Free;
  inherited;
end;

procedure TToolRegistry.Register(const ATool: IMcpTool);
begin
  FTools.AddOrSetValue(ATool.GetName, ATool);
end;

function TToolRegistry.TryGet(const AName: string; out ATool: IMcpTool): Boolean;
begin
  Result := FTools.TryGetValue(AName, ATool);
end;

function TToolRegistry.Names: TArray<string>;
begin
  Result := FTools.Keys.ToArray;
end;

function TToolRegistry.BuildListJson: TJSONArray;
var
  LName: string;
  LTool: IMcpTool;
  LToolObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  try
    for LName in FTools.Keys do
    begin
      LTool := FTools[LName];
      LToolObj := TJSONObject.Create;
      LToolObj.AddPair('name', LTool.GetName);
      LToolObj.AddPair('description', LTool.GetDescription);
      LToolObj.AddPair('inputSchema', LTool.BuildInputSchema);
      Result.AddElement(LToolObj);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function BuildTextResult(const AText: string; AIsError: Boolean): TJSONObject;
var
  LContent: TJSONArray;
  LBlock: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    LContent := TJSONArray.Create;
    LBlock := TJSONObject.Create;
    LBlock.AddPair('type', 'text');
    LBlock.AddPair('text', AText);
    LContent.AddElement(LBlock);
    Result.AddPair('content', LContent);
    if AIsError then
      Result.AddPair('isError', TJSONBool.Create(True));
  except
    Result.Free;
    raise;
  end;
end;

function BuildJsonTextResult(AJson: TJSONValue; AIsError: Boolean): TJSONObject;
var
  LText: string;
begin
  if AJson = nil then
    LText := 'null'
  else
    LText := AJson.Format(2);
  AJson.Free;
  Result := BuildTextResult(LText, AIsError);
end;

end.
