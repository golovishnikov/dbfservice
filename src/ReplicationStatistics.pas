unit ReplicationStatistics;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.IniFiles, System.Math,
  System.SyncObjs;

type
  /// <summary>
  /// Показатель для замера временных характеристик операций
  /// </summary>
  TTimeMetric = record
    Id: string;
    Count: Int64;
    MinTimeMs: Cardinal;
    MaxTimeMs: Cardinal;
    TotalTimeMs: Int64;
    function GetAvgTimeMs: Double;
  end;
  PTimeMetric = ^TTimeMetric;

  /// <summary>
  /// Показатель для фиксации изменений в конкретных файлах
  /// </summary>
  TChangeMetric = record
    Id: string; // Обычно имя файла (например, "dterapia.dbf")
    UpsertCount: Int64;   // Новые или измененные записи
    DeleteCount: Int64;   // Мягкие удаления (DELETE)
    TailDeleteCount: Int64; // Физические удаления хвоста таблицы (PACK)
  end;
  PChangeMetric = ^TChangeMetric;

  /// <summary>
  /// Класс накопления, хранения и персистентности показателей репликации
  /// </summary>
  TReplicationStatsManager = class
  class var FInstance: TReplicationStatsManager;
  private
    FLock: TCriticalSection;
    FMetricsFilename: string; // Файл для хранения статистики
    FTimeMetrics: TStringList;   // Список объектов TTimeMetric
    FChangeMetrics: TStringList; // Список объектов TChangeMetric

    procedure LoadMetrics;
    procedure ClearMetrics;
  public
    constructor Create(const AliasName: string);
    destructor Destroy; override;
    class function GetInstance: TReplicationStatsManager;

    // Методы для изменения временных показателей
    procedure RegisterTimeOperation(const MetricId: string; ExecutionTimeMs: Cardinal);

    // Методы для изменения показателей модификации данных
    procedure RegisterUpsert(const FileId: string; Count: Int64 = 1);
    procedure RegisterDelete(const FileId: string; Count: Int64 = 1);
    procedure RegisterTailDelete(const FileId: string; Count: Int64 = 1);

    // Метод принудительного сохранения статистики на диск
    procedure SaveToFile;
  end;

implementation

uses
  options;

{ TTimeMetric }

function TTimeMetric.GetAvgTimeMs: Double;
begin
  if Count > 0 then
    Result := TotalTimeMs / Count
  else
    Result := 0.0;
end;

{ TReplicationStatsManager }

constructor TReplicationStatsManager.Create(const AliasName: string);
var
  MetricsDir: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;

  MetricsDir := TConfigManager.FInstance.DataDir;
  MetricsDir := TPath.Combine(MetricsDir, 'metrics');
  FMetricsFilename := TPath.Combine(MetricsDir, AliasName+ '.ini');
  ForceDirectories(MetricsDir);

  // Инициализируем списки-хранилища для быстрой работы по ключу-идентификатору
  FTimeMetrics := TStringList.Create;
  FTimeMetrics.Sorted := True;
  FTimeMetrics.Duplicates := dupIgnore;

  FChangeMetrics := TStringList.Create;
  FChangeMetrics.Sorted := True;
  FChangeMetrics.Duplicates := dupIgnore;

  // Автоматически вычитываем старые показатели с диска (если они существуют)
  LoadMetrics;
end;

destructor TReplicationStatsManager.Destroy;
begin
  // Автоматически сохраняем накопленные данные перед закрытием экземпляра класса
  SaveToFile;
  ClearMetrics;
  FTimeMetrics.Free;
  FChangeMetrics.Free;
  FLock.Free;
  inherited;
end;

class function TReplicationStatsManager.GetInstance: TReplicationStatsManager;
begin
  if not Assigned(TReplicationStatsManager.FInstance) then
    TReplicationStatsManager.FInstance := TReplicationStatsManager.Create('all');
  Result := TReplicationStatsManager.FInstance;
end;

procedure TReplicationStatsManager.ClearMetrics;
var
  I: Integer;
begin
  for I := 0 to FTimeMetrics.Count - 1 do
    Dispose(PTimeMetric(FTimeMetrics.Objects[I]));

  for I := 0 to FChangeMetrics.Count - 1 do
    Dispose(PChangeMetric(FChangeMetrics.Objects[I]));
end;

// Потокобезопасный (в рамках вызова) апдейт временных метрик
procedure TReplicationStatsManager.RegisterTimeOperation(const MetricId: string; ExecutionTimeMs: Cardinal);
var
  Idx: Integer;
  PMetric: ^TTimeMetric;
begin
  FLock.Enter;
  try
    Idx := FTimeMetrics.IndexOf(MetricId);
    if Idx < 0 then
    begin
      // Если показатель запрашивается впервые — инициализируем структуру
      New(PMetric);
      PMetric^.Id := MetricId;
      PMetric^.Count := 1;
      PMetric^.MinTimeMs := ExecutionTimeMs;
      PMetric^.MaxTimeMs := ExecutionTimeMs;
      PMetric^.TotalTimeMs := ExecutionTimeMs;
      FTimeMetrics.AddObject(MetricId, TObject(PMetric));
    end
    else
    begin
      // Если показатель уже существует — обновляем его агрегаты
      PMetric := Pointer(FTimeMetrics.Objects[Idx]);
      Inc(PMetric^.Count);
      PMetric^.MinTimeMs := Min(PMetric^.MinTimeMs, ExecutionTimeMs);
      PMetric^.MaxTimeMs := Max(PMetric^.MaxTimeMs, ExecutionTimeMs);
      PMetric^.TotalTimeMs := PMetric^.TotalTimeMs + ExecutionTimeMs;
    end;
  finally
    FLock.Leave;
  end;
end;

// Вспомогательная функция для получения или создания количественной метрики
function GetOrCreateChangeMetric(List: TStringList; const FileId: string): Pointer;
var
  Idx: Integer;
  PMetric: ^TChangeMetric;
begin
  Idx := List.IndexOf(FileId);
  if Idx < 0 then
  begin
    New(PMetric);
    PMetric^.Id := FileId;
    PMetric^.UpsertCount := 0;
    PMetric^.DeleteCount := 0;
    PMetric^.TailDeleteCount := 0;
    List.AddObject(FileId, TObject(PMetric));
    Result := PMetric;
  end
  else
    Result := List.Objects[Idx];
end;

procedure TReplicationStatsManager.RegisterUpsert(const FileId: string; Count: Int64);
var
  P: ^TChangeMetric;
begin
  FLock.Enter;
  try
    P := GetOrCreateChangeMetric(FChangeMetrics, FileId);
    Inc(P^.UpsertCount, Count);
  finally
    FLock.Leave;
  end;
end;

procedure TReplicationStatsManager.RegisterDelete(const FileId: string; Count: Int64);
var
  P: ^TChangeMetric;
begin
  FLock.Enter;
  try
    P := GetOrCreateChangeMetric(FChangeMetrics, FileId);
    Inc(P^.DeleteCount, Count);
  finally
    FLock.Leave;
  end;
end;

procedure TReplicationStatsManager.RegisterTailDelete(const FileId: string; Count: Int64);
var
  P: ^TChangeMetric;
begin
  FLock.Enter;
  try
    P := GetOrCreateChangeMetric(FChangeMetrics, FileId);
    Inc(P^.TailDeleteCount, Count);
  finally
    FLock.Leave;
  end;
end;

procedure TReplicationStatsManager.SaveToFile;
var
  Ini: TMemIniFile;
  I: Integer;
  PTime: ^TTimeMetric;
  PChange: ^TChangeMetric;
begin
  FLock.Enter;
  try
    // Используем TMemIniFile для быстрой пакетной записи в буфер ОЗУ
    Ini := TMemIniFile.Create(FMetricsFilename, TEncoding.UTF8);
    try
      // 1. Сохраняем временные метрики
      for I := 0 to FTimeMetrics.Count - 1 do
      begin
        PTime := Pointer(FTimeMetrics.Objects[I]);
        Ini.WriteString(PTime^.Id, 'Count', IntToStr(PTime^.Count));
        Ini.WriteInteger(PTime^.Id, 'MinTimeMs', PTime^.MinTimeMs);
        Ini.WriteInteger(PTime^.Id, 'MaxTimeMs', PTime^.MaxTimeMs);
        Ini.WriteString(PTime^.Id, 'TotalTimeMs', IntToStr(PTime^.TotalTimeMs));
        Ini.WriteFloat(PTime^.Id, 'AvgTimeMs', PTime^.GetAvgTimeMs);
      end;

      // 2. Сохраняем количественные метрики файлов
      for I := 0 to FChangeMetrics.Count - 1 do
      begin
        PChange := Pointer(FChangeMetrics.Objects[I]);
        // Создаем уникальную секцию для каждого отслеживаемого файла
        Ini.WriteString('File_' + PChange^.Id, 'UpsertCount', IntToStr(PChange^.UpsertCount));
        Ini.WriteString('File_' + PChange^.Id, 'DeleteCount', IntToStr(PChange^.DeleteCount));
        Ini.WriteString('File_' + PChange^.Id, 'TailDeleteCount', IntToStr(PChange^.TailDeleteCount));
      end;

      Ini.UpdateFile; // Физически сбрасываем буфер на диск
    finally
      Ini.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TReplicationStatsManager.LoadMetrics;
var
  Ini: TMemIniFile;
  Sections: TStringList;
  I: Integer;
  SecName: string;
  PTime: ^TTimeMetric;
  PChange: ^TChangeMetric;
begin
  if not FileExists(FMetricsFilename) then Exit;

  Sections := TStringList.Create;
  Ini := TMemIniFile.Create(FMetricsFilename, TEncoding.UTF8);
  try
    Ini.ReadSections(Sections);
    for I := 0 to Sections.Count - 1 do
    begin
      SecName := Sections[I];

      // Разделяем загрузку по маске префикса секции
      if SecName.StartsWith('File_') then
      begin
        New(PChange);
        PChange^.Id := Copy(SecName, 6, Length(SecName)); // Отсекаем префикс 'File_'
        PChange^.UpsertCount := StrToInt64Def(Ini.ReadString(SecName, 'UpsertCount', '0'), 0);
        PChange^.DeleteCount := StrToInt64Def(Ini.ReadString(SecName, 'DeleteCount', '0'), 0);
        PChange^.TailDeleteCount := StrToInt64Def(Ini.ReadString(SecName, 'TailDeleteCount', '0'), 0);
        FChangeMetrics.AddObject(PChange^.Id, TObject(PChange));
      end
      else
      begin
        New(PTime);
        PTime^.Id := SecName;
        PTime^.Count := StrToInt64Def(Ini.ReadString(SecName, 'Count', '0'), 0);
        PTime^.MinTimeMs := Ini.ReadInteger(SecName, 'MinTimeMs', 0);
        PTime^.MaxTimeMs := Ini.ReadInteger(SecName, 'MaxTimeMs', 0);
        PTime^.TotalTimeMs := StrToInt64Def(Ini.ReadString(SecName, 'TotalTimeMs', '0'), 0);
        FTimeMetrics.AddObject(PTime^.Id, TObject(PTime));
      end;
    end;
  finally
    Ini.Free;
    Sections.Free;
  end;
end;

initialization
  TReplicationStatsManager.FInstance := nil;

finalization
  if Assigned(TReplicationStatsManager.FInstance) then
  begin
    TReplicationStatsManager.FInstance.Free;
    TReplicationStatsManager.FInstance := nil;
  end;

end.

