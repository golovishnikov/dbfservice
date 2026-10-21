unit utils;

interface

uses
  System.Classes,System.SysUtils, dbf_reader;

type
  TFileStreamTmp = class(TFileStream)
  private
    FFileName: string;
  public
    constructor Create(SrcFileName: string);
    destructor Destroy; override;
  end;

implementation

uses
  System.IOUtils, BufferedStreamReader;

{ TFileStreamTmp }

constructor TFileStreamTmp.Create(SrcFileName: string);
var
  FS: TFileStream;
begin
  FFileName := TPath.GetTempFileName;
  inherited Create(FFileName, fmCreate);
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    Self.CopyFrom(FS, 0);
  finally
    FS.Free;
  end;
end;

destructor TFileStreamTmp.Destroy;
begin
  inherited;
  if FFileName<>'' then
    DeleteFile(FFileName);
end;

end.
