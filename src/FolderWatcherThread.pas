unit FolderWatcherThread;

interface

uses
  System.Classes, System.SysUtils, Winapi.Windows, System.Generics.Collections,
  System.Hash, ActiveX;
type
  /// <summary>
  /// Локальный слепок метаданных DBF-файла для контроля изменений в памяти сервиса
  /// </summary>
  TFileState = record
    /// <summary>
    ///   Хэш содержимого файла, для отслеживания изменений
    /// </summary>
    FileHash: Cardinal;
  end;

  /// <summary>
  /// Определение типа события для передачи имени изменившегося файла в очередь
  /// </summary>
  TOnFileChangedEvent = procedure(const FullPath: string) of object;

  /// <summary>
  ///   Тред для отслеживания изменений в списке файлов.
  ///  Создает теневую копию диска,
  ///  сравнивает контрольные суммы файлов с эталонными (хранимыми в памяти),
  ///  запускает процесс обработки изменений,
  ///  запоминает контрольную сумму.
  ///
  ///  Экземпляр класса нужно уничтожать самостоятельно, обязательно дождавшись завершения потока.
  ///
  ///    FWatcherThread.Terminate;
  ///    FWatcherThread.WaitFor;
  ///    FWatcherThread.Free;
  ///    FWatcherThread := nil;
  ///
  /// </summary>
  TFolderWatcherThread = class(TThread)
  private
    FVolumeChar: Char; // диск, на котором лежат файлы
    FShadowcopy: string; // куда монтировать теневую копию
    FFileList: TDictionary<string, TFileState>; // список файлов, которы мониторить
    FOnFileChanged: TOnFileChangedEvent; // метод, вызываемый, если файл изменился
    FCheckInterval: Cardinal; // период проверки изменений
    // Выполняет проверку изменений по списку файлов
    procedure CheckFolderChanges;
    // Проверяет, изменилась ли контрольная сумма файла
    function ReadFileState(FileName: string; out FileState: TFileState): Boolean;
    // Обработчик ошибок, возникающих при работе с теневой копией.
    procedure OnShadowError(Error: string);
  protected
    procedure Execute; override;
  public
    /// <summary>
    ///   Конструктор.
    /// </summary>
    /// <param name="Shadowcopy: string;">
    ///  Полный путь до папки, в которую монитровать теневую копию.
    /// </param>
    /// <param name="AllowedFiles: TArray<string>;">
    ///  Полные пути до файлов, которые нужно отслеживать.
    ///  Все файлы должны размещаться на одном разделе.
    /// </param>
    /// <param name="CheckInterval: Cardinal;">
    ///  Интервал в миллесекундах, через который повторять выполнение проверки.
    /// </param>
    /// <param name="OnChangedEvent: TOnFileChangedEvent">
    ///  Обработчик изменений в файлах
    /// </param>
    constructor Create(
      const Shadowcopy: string;
      const AllowedFiles: TArray<string>;
      const CheckInterval: Cardinal;
      OnChangedEvent: TOnFileChangedEvent);
    destructor Destroy; override;
  end;

implementation

uses
  dbf_reader, System.Generics.Defaults, ReplicationStatistics, Log4D,
  WinShadowCopy, System.IOUtils, System.Math;

{ TFolderWatcherThread }

procedure TFolderWatcherThread.CheckFolderChanges;
var
  Pair: TPair<string, TFileState>;
  FileState: TFileState;
  StartTime: Cardinal;
  SC: TWinShadowCopy;
  Filename: string;
begin
  StartTime := GetTickCount;
  // Создание теневой копии
  SC := TWinShadowCopy.Create(FVolumeChar, FShadowcopy, OnShadowError);
  try
    // фиксируем статистику
    TReplicationStatsManager.GetInstance.RegisterTimeOperation('create_shadowcopy', GetTickCount - StartTime);
    TReplicationStatsManager.GetInstance.SaveToFile;
    // Обход списка файлов
    for Pair in FFileList do
    begin
      // путь до файла в теневой копии
      Filename := Tpath.Combine(SC.ShadowPath, Pair.Key);
      // считаем контрольную сумму
      if ReadFileState(Filename, FileState) then
        if (Pair.Value.FileHash <> FileState.FileHash) then
        begin
          if Assigned(FOnFileChanged) then
          begin
            StartTime := GetTickCount;
            try
              FOnFileChanged(Filename);
              // если успешно обработали изменения файла, то запоминаем контрольную сумму
              FFileList.Items[Pair.Key] := FileState;
            except
              on E: Exception do
                TLogLogger.GetLogger(Self.ClassName).Error('Ошибка проверки изменений в файле ' + Pair.Key + sLineBreak + E.Message);
            end;
            TReplicationStatsManager.GetInstance.RegisterTimeOperation('replication_'+ExtractFileName(Pair.Key), GetTickCount - StartTime);
          end;
          TReplicationStatsManager.GetInstance.SaveToFile;
        end;
    end;
  finally
    SC.Free;
  end;
end;

constructor TFolderWatcherThread.Create(
  const Shadowcopy: string;
  const AllowedFiles: TArray<string>;
  const CheckInterval: Cardinal; OnChangedEvent: TOnFileChangedEvent);
var
  FN, FileName: string;
  FileState: TFileState;
begin
  // Создаем поток в приостановленном состоянии, чтобы безопасно инициализировать данные
  inherited Create(True);
  FreeOnTerminate := False;

  FOnFileChanged := OnChangedEvent;
  FCheckInterval := CheckInterval;
  FShadowcopy := Shadowcopy;
  FVolumeChar := #0;

  // Заполняем белый список файлов для этой папки (в нижнем регистре для корректного сравнения)
  FFileList := TDictionary<string,TFileState>.Create();
  FileState.FileHash := 0;
  for FN in AllowedFiles do
  begin
    FileName := FN;
    if (FileName.Length > 2) and (FileName.Chars[1] = ':') then
    begin
      if (FVolumeChar = #0) then
        FVolumeChar := FileName.Chars[0];
      FileName := FileName.Substring(3);
    end;
    FFileList.AddOrSetValue(FileName, FileState);
  end;

end;

destructor TFolderWatcherThread.Destroy;
begin
  FFileList.Free;
  inherited;
end;

procedure TFolderWatcherThread.Execute;
const
  // на какое время усыплять поток
  MinInterval = 1000;
var
  SleepInterval: Cardinal;
begin
  CoInitialize(nil);
  try
    // запоминаем интервал, через который нужно проверить состояние файлов
    SleepInterval := FCheckInterval;
    // Основной цикл потока
    while not Terminated do
    begin
      // усыпляем поток на некоторое время
      Sleep(Min(SleepInterval, MinInterval));
      // если поток получил сигнал прерывания, то заканчиваем цикл
      if Terminated then Break;
      // уменьшаем интервал ожидания до запуска проверки изменений
      Dec(SleepInterval, MinInterval);
      // если время ожидания закончилось
      if SleepInterval <= 0 then
      begin
        // поять взводим время ожидания до заданного времени
        SleepInterval := FCheckInterval;
        try
          // и выполняем проверку
          CheckFolderChanges;
        except
          on E: Exception do
            TLogLogger.GetLogger(ClassName).Error(E.Message);
        end;
        if Terminated then Break;
      end;
    end;
  finally
    CoUninitialize;
  end;
end;

procedure TFolderWatcherThread.OnShadowError(Error: string);
begin
  TLogLogger.GetLogger(ClassName).Error(Error);
end;

function TFolderWatcherThread.ReadFileState(FileName: string; out FileState: TFileState): Boolean;

const CHUNK_SIZE = 1024 * 1024; // 1 Мегабайт
var
  FS: TFileStream;
  Buffer: TBytes;
  BytesRead: Integer;
  StartTime: Cardinal;
begin
  StartTime := GetTickCount;
  Result := False;
  if not FileExists(FileName) then Exit;
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buffer, CHUNK_SIZE);

      // Инициализируем стартовое значение хэша Bob Jenkins
      FileState.FileHash := 0;

      // Потоковое чтение файла блоками
      repeat
        BytesRead := FS.Read(Buffer[0], CHUNK_SIZE);
        if BytesRead > 0 then
        begin
          // Накапливаем хэш, передавая текущее промежуточное значение Result как Seed (третий параметр)
          FileState.FileHash := THashBobJenkins.GetHashValue(Buffer[0], BytesRead, FileState.FileHash);
        end;
      until BytesRead < CHUNK_SIZE;
      Result := True;
      TReplicationStatsManager.GetInstance.RegisterTimeOperation('calc_hash_'+ExtractFileName(FileName), GetTickCount - StartTime);
    finally
      FS.Free;
    end;
  except
    // подавляем ошибку
  end;
end;

end.
