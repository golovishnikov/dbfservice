unit options;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs;

type
  TConfigManager = class
  class var FInstance: TConfigManager;
  private
    FDatabaseAliases: TStringList;
    FPort: string;
    FLock: TCriticalSection; // Для потокобезопасности
  public
    constructor Create(const AIniPath: string);
    destructor Destroy; override;

    // Получение единственного экземпляра
    class function GetInstance: TConfigManager;
    class procedure Initialize(const AIniPath: string);

    // Методы доступа
    function GetConnectionString(const AAlias: string): string;
    property Port: string read FPort;
  end;

function AppIniFile: string;

implementation


function AppIniFile: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

{ TConfigManager }

constructor TConfigManager.Create(const AIniPath: string);
var
  Ini: TIniFile;
begin
  FDatabaseAliases := TStringList.Create;
  FDatabaseAliases.CaseSensitive := False;
  FLock := TCriticalSection.Create;

  Ini := TIniFile.Create(AIniPath);
  try
    // Читаем настройки сервера
    FPort := Ini.ReadString('settings', 'port', '8080');

    // Вычитываем все алиасы из секции [databases]
    Ini.ReadSectionValues('databases', FDatabaseAliases);
  finally
    Ini.Free;
  end;
end;

destructor TConfigManager.Destroy;
begin
  FDatabaseAliases.Free;
  FLock.Free;
  inherited;
end;

function TConfigManager.GetConnectionString(const AAlias: string): string;
var
  Path: string;
begin
  Result := '';
  FLock.Enter;
  try
    Path := FDatabaseAliases.Values[AAlias];
  finally
    FLock.Leave;
  end;

  if Path <> '' then
  begin
    // Формируем готовую строку для ADO и VFPOLEDB
    Result := Format('Provider=VFPOLEDB;Data Source=%s;Collating Sequence=RUSSIAN;Trim Trailing Blanks=True;', [Path]);
  end;
end;

class function TConfigManager.GetInstance: TConfigManager;
begin
  Result := FInstance;
end;

class procedure TConfigManager.Initialize(const AIniPath: string);
begin
  if not Assigned(TConfigManager.FInstance) then
    TConfigManager.FInstance := TConfigManager.Create(AIniPath);
end;


initialization
  TConfigManager.FInstance := nil;

finalization
  if Assigned(TConfigManager.FInstance) then
    TConfigManager.FInstance.Free;

end.
