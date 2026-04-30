unit Tests.Encoding.Detector;

interface

uses
  DUnitX.TestFramework,
  Encoding.Types;

type
  [TestFixture]
  TEncodingDetectorTests = class
  public
    [Test]
    procedure DetectBom_Utf8;
    [Test]
    procedure DetectBom_Utf16Le;
    [Test]
    procedure DetectBom_Utf16Be;
    [Test]
    procedure DetectBom_NoBom;
    [Test]
    procedure DetectEncoding_PureAscii;
    [Test]
    procedure DetectEncoding_ValidUtf8;
    [Test]
    procedure DetectEncoding_Windows1252DanishChars;
    [Test]
    procedure DetectEncoding_Windows1252Euro;
    [Test]
    procedure DetectEncoding_Iso88591NoC1;
    [Test]
    procedure DetectEncoding_EmptyFile;
    [Test]
    procedure DetectLineEnding_CRLF;
    [Test]
    procedure DetectLineEnding_LF;
    [Test]
    procedure DetectLineEnding_Mixed;
  end;

implementation

uses
  System.SysUtils,
  Encoding.Detector;

procedure TEncodingDetectorTests.DetectBom_Utf8;
var
  LBytes: TBytes;
  LBom: TBomInfo;
begin
  LBytes := TBytes.Create($EF, $BB, $BF, $48, $69);
  LBom := DetectBom(LBytes);
  Assert.IsTrue(LBom.Detected);
  Assert.AreEqual(TEncodingId.Utf8, LBom.EncodingId);
  Assert.AreEqual(3, LBom.BomLength);
end;

procedure TEncodingDetectorTests.DetectBom_Utf16Le;
var
  LBytes: TBytes;
  LBom: TBomInfo;
begin
  LBytes := TBytes.Create($FF, $FE, $48, $00, $69, $00);
  LBom := DetectBom(LBytes);
  Assert.IsTrue(LBom.Detected);
  Assert.AreEqual(TEncodingId.Utf16Le, LBom.EncodingId);
  Assert.AreEqual(2, LBom.BomLength);
end;

procedure TEncodingDetectorTests.DetectBom_Utf16Be;
var
  LBytes: TBytes;
  LBom: TBomInfo;
begin
  LBytes := TBytes.Create($FE, $FF, $00, $48, $00, $69);
  LBom := DetectBom(LBytes);
  Assert.IsTrue(LBom.Detected);
  Assert.AreEqual(TEncodingId.Utf16Be, LBom.EncodingId);
end;

procedure TEncodingDetectorTests.DetectBom_NoBom;
var
  LBytes: TBytes;
  LBom: TBomInfo;
begin
  LBytes := TBytes.Create($48, $65, $6C, $6C, $6F);
  LBom := DetectBom(LBytes);
  Assert.IsFalse(LBom.Detected);
end;

procedure TEncodingDetectorTests.DetectEncoding_PureAscii;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  LBytes := TBytes.Create($48, $65, $6C, $6C, $6F);
  LResult := DetectEncoding(LBytes);
  Assert.AreEqual(TEncodingId.Ascii, LResult.Id);
  Assert.IsFalse(LResult.HasBom);
  Assert.IsTrue(LResult.Confidence > 0.95);
end;

procedure TEncodingDetectorTests.DetectEncoding_ValidUtf8;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  // 'Hej' + UTF-8 'æ' (C3 A6) + 'ø' (C3 B8)
  LBytes := TBytes.Create($48, $65, $6A, $20, $C3, $A6, $C3, $B8);
  LResult := DetectEncoding(LBytes);
  Assert.AreEqual(TEncodingId.Utf8, LResult.Id);
  Assert.IsFalse(LResult.HasBom);
  Assert.IsTrue(LResult.Confidence > 0.9);
end;

procedure TEncodingDetectorTests.DetectEncoding_Windows1252DanishChars;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  // 'Hej ' + æøå (E6 F8 E5) i Windows-1252
  LBytes := TBytes.Create($48, $65, $6A, $20, $E6, $F8, $E5);
  LResult := DetectEncoding(LBytes);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.Id);
  Assert.IsFalse(LResult.HasBom);
end;

procedure TEncodingDetectorTests.DetectEncoding_Windows1252Euro;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  // 'Pris: ' + Euro (0x80 i Windows-1252) + ' 100'
  LBytes := TBytes.Create($50, $72, $69, $73, $3A, $20, $80, $20, $31, $30, $30);
  LResult := DetectEncoding(LBytes);
  Assert.AreEqual(TEncodingId.Windows1252, LResult.Id);
  Assert.IsTrue(LResult.Confidence > 0.8,
    Format('Expected high confidence for clear Windows-1252 marker, got %f',
    [LResult.Confidence]));
end;

procedure TEncodingDetectorTests.DetectEncoding_Iso88591NoC1;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  // Kun 0xA0..0xFF tegn - ingen C1-zone bytes
  // 'café' = 63 61 66 E9 i Latin-1
  LBytes := TBytes.Create($63, $61, $66, $E9);
  LResult := DetectEncoding(LBytes);
  // Med danske/europæiske tegn under 0xA0 forventer vi enten Win1252 eller ISO-8859-x
  Assert.IsTrue(
    (LResult.Id = TEncodingId.Windows1252) or
    (LResult.Id = TEncodingId.Iso88591) or
    (LResult.Id = TEncodingId.Iso885915),
    Format('Unexpected encoding: %s', [LResult.Name]));
end;

procedure TEncodingDetectorTests.DetectEncoding_EmptyFile;
var
  LBytes: TBytes;
  LResult: TDetectedEncoding;
begin
  SetLength(LBytes, 0);
  LResult := DetectEncoding(LBytes);
  Assert.AreEqual(TEncodingId.Utf8, LResult.Id);
end;

procedure TEncodingDetectorTests.DetectLineEnding_CRLF;
var
  LBytes: TBytes;
begin
  LBytes := TBytes.Create($48, $0D, $0A, $69, $0D, $0A);
  Assert.AreEqual(TLineEnding.CrLf, DetectLineEnding(LBytes));
end;

procedure TEncodingDetectorTests.DetectLineEnding_LF;
var
  LBytes: TBytes;
begin
  LBytes := TBytes.Create($48, $0A, $69, $0A);
  Assert.AreEqual(TLineEnding.Lf, DetectLineEnding(LBytes));
end;

procedure TEncodingDetectorTests.DetectLineEnding_Mixed;
var
  LBytes: TBytes;
begin
  LBytes := TBytes.Create($48, $0D, $0A, $69, $0A, $6A);
  Assert.AreEqual(TLineEnding.Mixed, DetectLineEnding(LBytes));
end;

initialization
  TDUnitX.RegisterTestFixture(TEncodingDetectorTests);

end.
