unit options;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  System.Generics.Collections;

type
  TConfigManager = class
  class var FInstance: TConfigManager;
  private
    FDatabaseAliases: TStringList; // Список алиасов баз данных, с полными путями до них
    FPort: string; // Порт, который слушает сервис
    FLock: TCriticalSection; // Объект блокировки доступаа к данным
    FFileList: TStringList; // Список файлов для синхронизации
    FDataDirectory: string; // Папкаразмещения данных сервиса
    FDbfRootDir: string; // корневая папка размещения DBF файлов программы
    FDbfCheckIntervalMs: Cardinal; // Интервал проверки изменений в файлах
    FVolumeChar: Char; // Буква диска, на котором размещены файлы DBF
    FUpdateURL: string; // Адрес для отпарвки изменений в файлах
    FUpdateKey: string; // ключ авторизации в запросах на обновление данных

    function GetAliases: TArray<string>;
    function GetAliasePath(AAlias: string): string;
    function GetEtalonsDirectory: string;
    function GetDataDir: string;
    function GetDbfRootDir: string;
    function GetReplicationFileList: TArray<string>;
    function GetShadpwcopyDirectory: string;
    function GetVolumeChar: Char;
    function GetDbfCheckIntervalMs: Cardinal;
    function GetUpdateKey: string;
    function GetUpdateURL: string;
  public
    constructor Create(const AIniPath: string);
    destructor Destroy; override;

    // Получение единственного экземпляра
    class function GetInstance: TConfigManager;
    class procedure Initialize(const AIniPath: string);

    // Методы доступа
    function GetConnectionString(const AAlias: string): string;
    function GetConnectionStringByPath(const APath: string): string;
    property Port: string read FPort;
    // Список алиасов баз данных и папок "свободных" файлов
    property Aliases: TArray<string> read GetAliases;
    // Папка размещения файлов
    property AliasePath[AAlias: string]: string read GetAliasePath;
    // Папка размещения DBF файлов
    property DbfRootDir: string read GetDbfRootDir;
    // Список отслеживаемых файлов
    property ReplicationFileList: TArray<string> read GetReplicationFileList;
    // папка хранения DBF, содержимое которых синхронизировано с сервером
    property EtalonsDirectory: string read GetEtalonsDirectory;
    // папка для монтирования теневой копии
    property ShadpwcopyDirectory: string read GetShadpwcopyDirectory;
    // буква диска, на котором лежит база DBF
    property VolumeChar: Char read GetVolumeChar;
    // папка для хранения данных
    property DataDir: string read GetDataDir;
    // интервал проверки изменений
    property DbfCheckIntervalMs: Cardinal read GetDbfCheckIntervalMs;
    // Адрес для отпарвки изменений в файлах
    property UpdateURL: string read GetUpdateURL;
    // ключ авторизации в запросах на обновление данных
    property UpdateKey: string read GetUpdateKey;
  end;

function AppIniFile: string;

implementation

uses
  System.IOUtils;


function AppIniFile: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

{ TConfigManager }

constructor TConfigManager.Create(const AIniPath: string);
var
  Alias: string;
  Value: string;
  Ini: TIniFile;
  I: Integer;
begin
  FDatabaseAliases := TStringList.Create;
  FDatabaseAliases.CaseSensitive := False;
  FVolumeChar := #0;
  FLock := TCriticalSection.Create;
  FFileList := TStringList.Create;

  Ini := TIniFile.Create(AIniPath);
  try
    // Читаем настройки сервера
    FPort := Ini.ReadString('options', 'port', '8080');
    FDataDirectory := Ini.ReadString('options', 'DataDir', 'data');
    FDbfRootDir := Ini.ReadString('options', 'DbfRootDir', 'data');
    FDbfCheckIntervalMs := Ini.ReadInteger('options', 'DbfCheckIntervalMs', 60000);
    FUpdateURL := Ini.ReadString('options', 'UpdateURL', '');
    FUpdateKey := Ini.ReadString('options', 'UpdateKey', '');
    // Имя диска, где лежит база данных фокспро
    if (FDbfRootDir.Length > 1) and (FDbfRootDir.Chars[1] = ':') then
      FVolumeChar := FDbfRootDir.Chars[0]
    else
      FVolumeChar := ParamStr(0).Chars[0];

    // Вычитываем все алиасы из секции [databases]
    Ini.ReadSectionValues('databases', FDatabaseAliases);

    // Патчим пути в алиасах, добавляя корневую папку
    for I := 0 to FDatabaseAliases.Count - 1 do
    begin
      Alias := FDatabaseAliases.Names[I];
      Value := FDatabaseAliases.ValueFromIndex[I];
      if TPath.IsRelativePath(Value) then
        FDatabaseAliases.ValueFromIndex[I] := TPath.Combine(FDbfRootDir, Value);
    end;

    // прочитать список файлов, изменение которых нужно отслеживать
    Ini.ReadSection('replication', FFileList);
    // И надо дописать корневую папку для всех имен файлов
    for I := 0 to FFileList.Count - 1 do
      FFileList[I] := TPath.Combine(FDbfRootDir, FFileList[I]);
  finally
    Ini.Free;
  end;
end;

destructor TConfigManager.Destroy;
begin
  FDatabaseAliases.Free;
  FFileList.Free;
  FLock.Free;
  inherited;
end;

function TConfigManager.GetAliasePath(AAlias: string): string;
begin
  FLock.Enter;
  try
    Result := FDatabaseAliases.Values[AAlias];
    if (Result <> '') and not DirectoryExists(Result) then
      Result := '';
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetAliases: TArray<string>;
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FDatabaseAliases.Count);
    for I := 0 to FDatabaseAliases.Count - 1 do
      Result[I] := FDatabaseAliases.Names[I];
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetConnectionString(const AAlias: string): string;
var
  Path: string;
begin
  FLock.Enter;
  try
    Path := FDatabaseAliases.Values[AAlias];
  finally
    FLock.Leave;
  end;

  Result := GetConnectionStringByPath(Path);
end;

function TConfigManager.GetConnectionStringByPath(const APath: string): string;
begin
  if APath <> '' then
    // Формируем готовую строку для ADO и VFPOLEDB
    Result := Format('Provider=VFPOLEDB;Data Source=%s;Collating Sequence=RUSSIAN;Trim Trailing Blanks=True;', [APath])
  else
    Result := '';
end;

function TConfigManager.GetDataDir: string;
begin
  FLock.Enter;
  try
    Result := FDataDirectory;
    if TPath.IsRelativePath(Result) then
      Result := TPath.Combine(ExtractFilePath(ParamStr(0)), Result);
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetDbfCheckIntervalMs: Cardinal;
begin
  FLock.Enter;
  try
    Result := FDbfCheckIntervalMs;
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetDbfRootDir: string;
begin
  FLock.Enter;
  try
    Result := FDbfRootDir;
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetEtalonsDirectory: string;
begin
  FLock.Enter;
  try
    Result := TPath.Combine(FDataDirectory, 'etalons');
    if TPath.IsRelativePath(Result) then
      Result := TPath.Combine(ExtractFilePath(ParamStr(0)), Result);
  finally
    FLock.Leave;
  end;
end;

class function TConfigManager.GetInstance: TConfigManager;
begin
  Result := FInstance;
end;

function TConfigManager.GetReplicationFileList: TArray<string>;
begin
  FLock.Enter;
  try
    Result := FFileList.ToStringArray;
  finally
    FLock.Leave;
  end;

end;

function TConfigManager.GetShadpwcopyDirectory: string;
begin
  FLock.Enter;
  try
    Result := TPath.Combine(FDataDirectory, 'shadowcopy');
    if TPath.IsRelativePath(Result) then
      Result := TPath.Combine(ExtractFilePath(ParamStr(0)), Result);
  finally
    FLock.Leave;
  end;

end;

function TConfigManager.GetUpdateKey: string;
begin
  FLock.Enter;
  try
    Result := FUpdateKey;
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetUpdateURL: string;
begin
  FLock.Enter;
  try
    Result := FUpdateURL;
  finally
    FLock.Leave;
  end;
end;

function TConfigManager.GetVolumeChar: Char;
begin
  FLock.Enter;
  try
    Result := FVolumeChar;
  finally
    FLock.Leave;
  end;

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
  begin
    TConfigManager.FInstance.Free;
    TConfigManager.FInstance := nil;
  end;

end.
