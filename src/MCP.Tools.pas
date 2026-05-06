unit MCP.Tools;

/// <summary>
///   Tool interface and registration mechanism for MCP tools.
/// </summary>

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  /// <summary>
  ///   An MCP tool. Each tool exposes a name, description, JSON Schema
  ///   for parameters, and an execution method.
  /// </summary>
  IMcpTool = interface
    ['{B7F6F4A8-2C19-4F4A-8D19-9E5B7C2C9A11}']
    function GetName: string;
    function GetDescription: string;
    /// <summary>
    ///   Returns a JSON Schema object describing the tool parameters.
    ///   The caller takes ownership.
    /// </summary>
    function BuildInputSchema: TJSONObject;
    /// <summary>
    ///   Executes the tool. Returns an MCP content object with
    ///   "content" array and optional "isError". The caller takes ownership.
    /// </summary>
    /// <param name="AArguments">JSON arguments (may be nil for parameterless tools).</param>
    /// <exception cref="Exception">On internal errors. Dispatcher converts to MCP error response.</exception>
    function Execute(AArguments: TJSONObject): TJSONObject;
  end;

  /// <summary>
  ///   Registry for IMcpTool instances, looked up by name.
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
    /// <summary>Builds the MCP "tools/list" JSON array. The caller takes ownership.</summary>
    function BuildListJson: TJSONArray;
  end;

/// <summary>
///   Builds a standard MCP tool result with a single text block.
///   The caller takes ownership.
/// </summary>
function BuildTextResult(const AText: string; AIsError: Boolean = False): TJSONObject;

/// <summary>
///   Builds an MCP tool result where the text is a serialized JSON value
///   (typically pretty-printed JSON). The caller takes ownership.
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
