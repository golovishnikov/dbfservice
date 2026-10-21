unit DBFTempFiles;

interface

uses
  System.Classes, System.SysUtils, System.IOUtils;

type
  TDBFTempFiles = class
  private
    FOriginalDBFPath: string;
    FOriginalFPTPath: string;
    FTempDirPath: string;
    FTempDBFPath: string;
    FTempFPTPath: string;
    FTempDBFStream: TFileStream;
    FTempFPTStream: TFileStream;
    FHasFPT: Boolean;

    procedure CopyFile(const SrcPath, DstPath: string);
    procedure ClearDbcBacklink(TempDbfStream: TFileStream);
  public
    // В конструктор передается полный путь к оригинальному сетевому DBF
    constructor Create(const SrcDBFPath: string);
    destructor Destroy; override;
    procedure Close;

    // Свойства для доступа к открытым неблокирующим потокам во временной папке
    property TempDBFStream: TFileStream read FTempDBFStream;
    property TempFPTStream: TFileStream read FTempFPTStream;

    // имена файлов на диске
    property TempDBFPath: string read FTempDBFPath;
    property TempFPTPath: string read FTempFPTPath;

    // Флаг, определяющий, есть ли у данной таблицы мемо-файлы
    property HasFPT: Boolean read FHasFPT;

    // Путь к созданной временной папке (если понадобится для ADO)
    property TempDirPath: string read FTempDirPath;
  end;

implementation

{ TDBFTempFiles }

procedure TDBFTempFiles.ClearDbcBacklink(TempDbfStream: TFileStream);
var
  HeaderLength: Word;
  TableFlag: Byte;
  TerminatorPos: Int64;
  ScanByte: Byte;
  ZeroBuffer: TBytes;
  BytesToZero: Integer;
begin
  // 1. Читаем длину заголовка (HeaderLength)
  TempDbfStream.Position := 8;
  TempDbfStream.ReadBuffer(HeaderLength, SizeOf(HeaderLength));

  // 2. Читаем и сбрасываем флаг привязки к DBC (смещение 28)
  TempDbfStream.Position := 28;
  TempDbfStream.ReadBuffer(TableFlag, SizeOf(TableFlag));

  if (TableFlag and $01) = $01 then
  begin
    TableFlag := TableFlag and not $01; // Убираем бит привязки
    TempDbfStream.Position := 28;
    TempDbfStream.WriteBuffer(TableFlag, SizeOf(TableFlag));

    // 3. Ищем байт-терминатор 0x0D, сканируя заголовок начиная с конца описания полей (смещение 32)
    TerminatorPos := 32;
    while TerminatorPos < HeaderLength do
    begin
      TempDbfStream.Position := TerminatorPos;
      TempDbfStream.ReadBuffer(ScanByte, 1);

      if ScanByte = $0D then
        Break // Нашли терминатор схемы
      else
        Inc(TerminatorPos, 32); // Прыгаем к началу следующего дескриптора поля
    end;

    // 4. Если терминатор найден, зануляем строго ВСЁ, что идет ПОСЛЕ него
    if TerminatorPos < HeaderLength then
    begin
      // Первым байтом после полей идет бэклинк. Его позиция: TerminatorPos + 1
      // Сколько байт нужно занулить до начала данных:
      BytesToZero := HeaderLength - (TerminatorPos + 1);

      if BytesToZero > 0 then
      begin
        SetLength(ZeroBuffer, BytesToZero);
        FillChar(ZeroBuffer[0], BytesToZero, 0);

        // Пишем нули строго поверх пути к базе данных
        TempDbfStream.Position := TerminatorPos + 1;
        TempDbfStream.WriteBuffer(ZeroBuffer[0], BytesToZero);
      end;
    end;
  end;
end;

constructor TDBFTempFiles.Create(const SrcDBFPath: string);
var
  GuidDirName: string;
  TempBaseDir: string;
begin
  inherited Create;
  FOriginalDBFPath := SrcDBFPath;
  FOriginalFPTPath := ChangeFileExt(SrcDBFPath, '.fpt');
  FHasFPT := FileExists(FOriginalFPTPath);

  // 1. Формируем путь к уникальной временной подпапке (через GUID)
  TempBaseDir := TPath.GetTempPath; // Системная папка Temp (например, C:\Users\...\AppData\Local\Temp)
  GuidDirName := TPath.GetGUIDFileName(False); // Генерируем уникальное имя без скобок
  FTempDirPath := TPath.Combine(TempBaseDir, GuidDirName);

  // Создаем физическую директорию на диске
  ForceDirectories(FTempDirPath);

  // Формируем пути назначения во временной папке с сохранением оригинальных имен
  FTempDBFPath := TPath.Combine(FTempDirPath, ExtractFileName(FOriginalDBFPath));
  FTempFPTPath := TPath.Combine(FTempDirPath, ExtractFileName(FOriginalFPTPath));

  try
    // 2. Быстро изолируем DBF
    CopyFile(FOriginalDBFPath, FTempDBFPath);
    // Открываем временный файл в режиме fmShareDenyNone (чтение/запись разрешены всем, файл не заблокирован)
    FTempDBFStream := TFileStream.Create(FTempDBFPath, fmOpenReadWrite or fmShareDenyNone);
    ClearDbcBacklink(FTempDBFStream);
    FTempDBFStream.Position := 0;

    // 3. Изолируем FPT при наличии
    if FHasFPT then
    begin
      CopyFile(FOriginalFPTPath, FTempFPTPath);
      FTempFPTStream := TFileStream.Create(FTempFPTPath, fmOpenReadWrite or fmShareDenyNone);
    end else
    begin
      FTempFPTStream := nil;
    end;

  except
    on E: Exception do
    begin
      // Если на этапе создания что-то пошло не так — вызываем деструктор для зачистки того, что успели создать
      Destroy;
      raise Exception.CreateFmt('Не удалось изолировать файлы для %s. Ошибка: %s', [SrcDBFPath, E.Message]);
    end;
  end;
end;

destructor TDBFTempFiles.Destroy;
begin
  // 1. Сначала ОБЯЗАТЕЛЬНО закрываем потоки, чтобы операционная система отпустила временные файлы
  Close;

  // 2. Удаляем временные файлы и саму GUID-папку
  if DirectoryExists(FTempDirPath) then
  begin
    try
      // TDirectory.Delete с флагом True рекурсивно очищает всё содержимое папки и удаляет её саму
      TDirectory.Delete(FTempDirPath, True);
    except
      // Служба не должна падать, если ОС заблокировала кэш-файл на доли секунды, логгируем или игнорируем
    end;
  end;

  inherited Destroy;
end;

procedure TDBFTempFiles.Close;
begin
  if Assigned(FTempDBFStream) then FreeAndNil(FTempDBFStream);
  if Assigned(FTempFPTStream) then FreeAndNil(FTempFPTStream);
end;

procedure TDBFTempFiles.CopyFile(const SrcPath, DstPath: string);
var
  SrcStream, DstStream: TFileStream;
begin
  // Открываем оригинальный (сетевой) файл в режиме полного общего доступа fmShareDenyNone.
  // Это гарантирует, что мы не вызовем у FoxPro ошибку "File access denied".
  SrcStream := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    DstStream := TFileStream.Create(DstPath, fmCreate);
    try
      // Сверхбыстрое поблочное копирование средствами VCL
      DstStream.CopyFrom(SrcStream, 0);
    finally
      DstStream.Free;
    end;
  finally
    SrcStream.Free; // Сетевой файл закрывается мгновенно после копирования!
  end;
end;

end.
