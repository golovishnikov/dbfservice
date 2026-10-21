unit DbfDataPublisher;

interface

uses
  System.Classes, System.SysUtils, dbf_reader, XSuperObject,
  System.Generics.Collections, Data.Win.ADODB, Data.DB;

type
  /// <summary>
  ///   Класс выполняющий сверку DBF файла с эталоном и выполняющий
  ///   отправку изменений по http протоколу на указанный в конфиге адрес.
  ///  Логика отправки полностью реализована в классе. Экземпляр сервиса 
  ///  сам решает что, куда и в каком виде отправлять.
  /// </summary>
  TDbfDataPublisher = class
  private
    // данные глобальные переменные нужны для обработки файла.
    // они инициализируются в методе Execute,
    // использутся в методах обработки событий
    FConnection: TADOConnection; // подключение к папке анализируемого файла
    FQuery: TADOQuery; // курсор для чтения анализируемого файла
    FSchema: TDBFSchema; // Схема DBF (описание поде)
    FFieldTypes: TDictionary<string, TFieldType>;
    FFieldNames: TStringList;

    // Это обычные переменные
    FEtalonsDir: string; // Папка храненя эталонных файлов
    FNewFileName: string; // Полный путь до файла, который анализируем
    FNewFileNameShort: string; // Только имя файла, который анализируем
    FHeader: TDBFHeader; // Заголовок DBF
    FFearstComparation: Boolean; // Первое сравнение (эталон отсуствует)
    FUpdateBatch: ISuperObject; // Пакет обновления
    // Обработка события изменения записи: вставка, удаление, изменение.
    procedure OnRecordChanged(RecNo: Integer; const NewRecordData: TBytes);
    // Обработа события удаления последних записей.
    // В метод передается номер строки, начиная с которой нужно удалять данные.
    procedure OnTailDeleted(FromRecNo: Integer);
    // Название таблицы в новой БД (имя файла без разрешения)
    function TableName: string;
    // Прочитать указанную запись из таблицы через OLE
    function SelectRecord(RecNo: Integer): ISuperObject;
    // Закрыть открытые ресурсы
    procedure Close;
    // Отправка данных в новую базу
    procedure SendUpdate;
    // мониторинг отправки данных
    procedure OnSend(Sender: TObject; Writing: Boolean; const Buffer: Pointer; Len: Integer);
  public
    /// <summary>
    ///   Конструктор.
    /// </summary>
    /// <param name="EtalonsDir: string">
    /// Папка размещения эталонных файлов, с которыми сравнивать.
    ///  После сравнения эталон будет заменен на новый файл.
    /// </param>
    /// <param name="NewFilename: string">
    /// Полный путь до файла, изменения по которому нужно найти и отправить 
    ///  в сервис, принимающий изменения.
    /// </param>
    constructor Create(EtalonsDir, NewFilename: string);
    destructor Destroy; override;

    procedure Execute;
  end;


implementation

uses
  DBFTempFiles, DBFComparator, System.IOUtils, Log4D, ReplicationStatistics,
  options, dbf_export, Winapi.ADOInt, httpsend;

{ TDbfDataPublisher }

procedure TDbfDataPublisher.Close;
begin
  if Assigned(FSchema) then
    FreeAndNil(FSchema);
  if Assigned(FQuery) then
    FreeAndNil(FQuery);
  if Assigned(FConnection) then
    FreeAndNil(FConnection);
  FFieldTypes.Clear;
  FFieldNames.Clear;
end;

constructor TDbfDataPublisher.Create(EtalonsDir, NewFilename: string);
begin
  FEtalonsDir := EtalonsDir;
  FNewFileName := NewFilename;
  FNewFileNameShort := ExtractFileName(FNewFileName);
  FSchema := nil;
  FQuery := nil;
  FConnection := nil;
  FFieldTypes := TDictionary<string,TFieldType>.Create;
  FFieldNames := TStringList.Create;
  FUpdateBatch := SO();
  FUpdateBatch.S['table'] := ChangeFileExt(FNewFileNameShort, '').ToLower;
end;

destructor TDbfDataPublisher.Destroy;
begin
  Close;
  FFieldTypes.Free;
  FFieldNames.Free;
  inherited;
end;

procedure TDbfDataPublisher.Execute;
var
  EtalonFilename: string;
  EtalonFile: TStream;
  NewFile: TFileStream;
  Comparator: TDBFComparator;
begin
  FUpdateBatch := SO();
  FUpdateBatch.S['table'] := ChangeFileExt(FNewFileNameShort, '').ToLower;

  // открываем эталонный файл
  EtalonFilename := TPath.Combine(FEtalonsDir, ExtractFileName(FNewFileName));

  // Копируем и открываем временный файл
  NewFile := TFileStream.Create(FNewFileName, fmOpenRead or fmShareDenyNone);
  try
    FConnection := TADOConnection.Create(nil);
    FConnection.ConnectionString := TConfigManager.GetInstance.GetConnectionStringByPath(ExtractFilePath(FNewFileName));
    FConnection.LoginPrompt := False;
    FConnection.Open;
    FConnection.Execute('SET NULL OFF');
    FConnection.Execute('SET DELETED ON');

    FQuery := TADOQuery.Create(nil);
    FQuery.Connection := FConnection;
    FQuery.CursorLocation := clUseServer;
    FQuery.LockType := ltReadOnly;
    FQuery.SQL.Text := TDataExporter.GetSafeSelectSQL(FConnection, TableName, FFieldTypes);
    FQuery.Open;

    try
      // открываем эталонный файл
      if FileExists(EtalonFilename) then
        EtalonFile := TFileStream.Create(EtalonFilename, fmOpenReadWrite)
      else
        EtalonFile := TMemoryStream.Create; // пустой поток, т.к. файла нет
      FFearstComparation := EtalonFile.Size = 0;
      try
        // TODO схема данных не используется, т.к. решили читать данные из DBF запросами.
        FSchema := dbf_reader.ReadDbfSchema(NewFile, FHeader);
        // Создаем компаратор данных файла с эталоном (сравниваем только DBF)
        Comparator := TDBFComparator.Create;
        Comparator.OnRecordChanged := OnRecordChanged;
        Comparator.OnTailDeleted := OnTailDeleted;
        // Запускаем сравнение
        Comparator.CompareStreams(NewFile, EtalonFile, FHeader);
        // Отправка изменений на сервер, после сравнения все данные должны быть записаны в JSON объект
        // в методе OnRecordChanged выполняется промежуточная отправка данных
        SendUpdate;
      finally
        EtalonFile.Free;
      end;
      FQuery.Close;
      FConnection.Close;
      // Если копирование прошло удачно, то удаляем эталон, заменяя его новым файлом
      if FileExists(EtalonFilename) then
        DeleteFile(EtalonFilename);
      TFile.Copy(FNewFileName, EtalonFilename, True);
    finally
      Close;
    end;
  finally
    NewFile.Free;
  end;

end;

procedure TDbfDataPublisher.OnRecordChanged(RecNo: Integer;
  const NewRecordData: TBytes);
const
  // отправлять пачки изменений не более 1000 записей удаления или изменения
  MaxBatchLength = 1000;
begin
  // сохранение статистики
  if not FFearstComparation then
  begin
    if NewRecordData[0] = $2A then // или Ord('*')
      TReplicationStatsManager.GetInstance.RegisterDelete(FNewFileNameShort)
    else
      TReplicationStatsManager.GetInstance.RegisterUpsert(FNewFileNameShort);
  end;
  // проверяем, удалена ли запись
  if NewRecordData[0] = $2A then // или Ord('*')
  begin
    FUpdateBatch.A['delete'].Add(RecNo);
  end
  else
  begin
    FUpdateBatch.A['update'].Add(SelectRecord(RecNo));
  end;
  if (FUpdateBatch.A['update'].Length >= MaxBatchLength) or (FUpdateBatch.A['delete'].Length >= MaxBatchLength) then
    SendUpdate;
end;

procedure TDbfDataPublisher.OnSend(Sender: TObject; Writing: Boolean;
  const Buffer: Pointer; Len: Integer);
var
  B: TBytes;
  S: string;
begin
  setlength(B, len);
  move(Buffer^, pointer(B)^, len);
  S := TEncoding.UTF8.GetString(B);
  if Writing then
    S := '-> ' + S
  else
    S := '<- ' + S;
  TLogLogger.GetLogger(Self.ClassName).Debug(S);
end;

procedure TDbfDataPublisher.OnTailDeleted(FromRecNo: Integer);
begin
  if not FFearstComparation then
    TReplicationStatsManager.GetInstance.RegisterTailDelete(FNewFileNameShort);
  FUpdateBatch.I['delete_tail'] := FromRecNo;
end;

function TDbfDataPublisher.SelectRecord(RecNo: Integer): ISuperObject;
begin
  // Перемещаемся на нужную запись
  FQuery.Recordset.Move(RecNo-1, OleVariant(adBookmarkFirst));
  FQuery.Resync([]);
  Result := TDataExporter.RowToJson(FQuery, FFieldTypes, FFieldNames);
end;

procedure TDbfDataPublisher.SendUpdate;
var
  Client: THTTPSend;
  SS: TStringStream;
  UpdateKey: string;
  UpdateURL: string;
  S: string;
begin
  if (FUpdateBatch.A['update'].Length = 0)
    and (FUpdateBatch.A['delete'].Length = 0)
    and (FUpdateBatch.I['delete_tail'] = 0)
  then
    Exit;
  TLogLogger.GetLogger(Self.ClassName).Debug(Format('%s: update: %d, deleted: %d, tail: %d', [
    TableName,  FUpdateBatch.A['update'].Length, FUpdateBatch.A['delete'].Length, FUpdateBatch.I['delete_tail']]));

  UpdateURL := TConfigManager.GetInstance.UpdateURL;
  if UpdateURL.IsEmpty then
    raise Exception.Create('Не указан адрес для отправки изменений UpdateURL.');
  UpdateKey := TConfigManager.GetInstance.UpdateKey;
  if UpdateKey.IsEmpty then
    raise Exception.Create('Не указан API ключ для отправки изменений UpdateKey.');
  Client := THTTPSend.Create();
  try
//    Client.Sock.OnMonitor := OnSend;
    Client.MimeType := 'application/json';
    Client.UserAgent := 'DBFService';
    Client.Headers.Add('X-API-Key: ' + UpdateKey);
    Client.Timeout := 90000;
    SS := TStringStream.Create(FUpdateBatch.AsJSON(), TEncoding.UTF8);
    try
      Client.Document.CopyFrom(SS, -1);
    finally
      SS.Free;
    end;
    if Client.HTTPMethod('POST', UpdateURL) then
    begin
      if Client.ResultCode <> 200 then
      begin
        S := '';
        SS := TStringStream.Create('', TEncoding.UTF8);
        try
          try
            SS.CopyFrom(Client.Document, -1);
            S := SS.DataString;
          except
          end;
        finally
          SS.Free;
        end;
        raise Exception.Create(IntToStr(Client.ResultCode) + ': ' + UTF8ToString(Client.ResultString) + ': ' + S);
      end;
      // В случае успешной отправки удалим из пачки отправленные записи
      FUpdateBatch.Remove('update');
      FUpdateBatch.Remove('delete');
      FUpdateBatch.Remove('delete_tail');
    end
    else
      raise Exception.Create(IntToStr(Client.Sock.LastError) + ': ' + Client.Sock.LastErrorDesc);
  finally
    Client.Free;
  end;
end;

function TDbfDataPublisher.TableName: string;
begin
  if Assigned(FUpdateBatch) then
    Result := FUpdateBatch.S['table']
  else
    Result := '';
end;

end.
