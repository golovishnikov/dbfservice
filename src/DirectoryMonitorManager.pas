unit DirectoryMonitorManager;

interface

uses
  System.Classes, System.SysUtils, System.IOUtils, System.Generics.Collections,
  FolderWatcherThread, Log4D, ReplicationStatistics;

type

  TDirectoryMonitor = class
  private
    FWatcherThread: TFolderWatcherThread;
    FLogger: TLogLogger;
    FEtalonsDir: string;
    // обработочик изменения в файле.
    // Процедура вызывается из потока отслеживания изменений папки.
    // Отслеживаются только заданные файлы в папке по изменению хэша файла.
    // Поток отслеживания будет вызывать метод в порядке обнаруженных изменений.
    // В обработчик передается полный путь до файла, котрый изменился.
    procedure OnTargetFileChangedEvent(const FullPath: string);
    procedure Start;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  options, DbfDataPublisher;

{ TDirectoryMonitor }

constructor TDirectoryMonitor.Create;
begin
  FLogger := TLogLogger.GetLogger(Self.ClassName);
  FEtalonsDir := TConfigManager.GetInstance.EtalonsDirectory;
  if not DirectoryExists(FEtalonsDir) then
  try
    if not ForceDirectories(FEtalonsDir) then
    begin
      FLogger.Error('Не удается создать папку хранения эталонных файлов ' + FEtalonsDir);
      Exit;
    end;
  except
    on E: Exception do
    begin
      FLogger.Error(E.Message + ' ' + FEtalonsDir);
      Exit;
    end;
  end;
  FWatcherThread := nil;
  Start;
end;

destructor TDirectoryMonitor.Destroy;
begin
  if Assigned(FWatcherThread) then
  begin
    FWatcherThread.Terminate;
    FWatcherThread.WaitFor;
    FWatcherThread.Free;
    FWatcherThread := nil;
  end;
  inherited;
end;

procedure TDirectoryMonitor.OnTargetFileChangedEvent(const FullPath: string);
var
  DbfPublisher: TDbfDataPublisher;
begin
  DbfPublisher := TDbfDataPublisher.Create(FEtalonsDir, FullPath);
  try
    DbfPublisher.Execute;
  finally
    DbfPublisher.Free;
  end;
end;

procedure TDirectoryMonitor.Start;
var
  Files: TArray<string>;
begin
  Files := TConfigManager.GetInstance.ReplicationFileList;
  if Length(Files) > 0 then
  begin
    FWatcherThread := TFolderWatcherThread.Create(
      TConfigManager.GetInstance.ShadpwcopyDirectory,
      TConfigManager.GetInstance.ReplicationFileList,
      TConfigManager.GetInstance.DbfCheckIntervalMs,
      OnTargetFileChangedEvent
    );
    FWatcherThread.Start;
  end;
end;

end.
