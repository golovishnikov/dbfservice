unit BufferedStreamReader;

interface

uses
  System.Classes, System.SysUtils, System.Math;

type
  /// <summary>
  ///   Класс для буфиризированного чтения файла DBF.
  ///  Читает файл блоками кратными размеру записи.
  /// </summary>
  TBufferedStreamReader = class
  private
    FStream: TStream;
    FRecordLength: Integer;
    FBuffer: TBytes;
    FBufferSize: Integer; // Сколько реально байт прочитано в буфер с диска
    FBufferPos: Integer;  // Текущая позиция чтения внутри буфера
    FChankSize: Integer; // Сколько байт пытаться читать из файла
    procedure FillBuffer;
  public
    /// <summary>
    ///   Создать экземпляр класса.
    /// </summary>
    /// <param name="AStream: TStream">
    ///  Ссылка на открытый поток DBF файла.
    /// </param>
    /// <param name="StartOffset: Integer">
    ///  Длина заголовка DBF файла.
    /// </param>
    /// <param name="RecordLength: Integer">
    ///  Размер записи в DBF файле.
    /// </param>
    constructor Create(AStream: TStream; StartOffset, RecordLength: Integer);
    destructor Destroy; override;

    /// <summary>
    ///   Функция читает следующую запись. Возвращает False, если файл закончился.
    /// </summary>
    function ReadNextRecord(out RecordData: TBytes): Boolean;

    // Проверка достижения конца файла (EOF)
    function Eof: Boolean;
  end;

implementation

{ TBufferedStreamReader }

constructor TBufferedStreamReader.Create(AStream: TStream; StartOffset,
  RecordLength: Integer);
const
  TARGET_CHUNK = 1024 * 1024; // Ориентируемся на блок ~1 МБ
var
  RecordsPerBuffer: Integer;
begin
  inherited Create;
  FStream := AStream;
  FStream.Seek(StartOffset, soBeginning);
  FRecordLength := RecordLength;

  // Рассчитываем размер буфера так, чтобы он вмещал целое число записей
  RecordsPerBuffer := TARGET_CHUNK div FRecordLength;
  if RecordsPerBuffer = 0 then RecordsPerBuffer := 1;

  // Итоговый размер буфера гарантированно кратен длине записи DBF
  FChankSize := RecordsPerBuffer * FRecordLength;

  SetLength(FBuffer, FChankSize);
  FBufferSize := 0;
  FBufferPos := 0;
end;

destructor TBufferedStreamReader.Destroy;
begin

  inherited;
end;

function TBufferedStreamReader.Eof: Boolean;
var
  AvailableInBuffer: Integer;
  AvailableInStream: Int64;
begin
  // Сколько полезных байт осталось в текущем ОЗУ-буфере
  AvailableInBuffer := FBufferSize - FBufferPos;

  // Сколько байт осталось физически в потоке на диске
  AvailableInStream := FStream.Size - FStream.Position;

  // Файл логически закончился, если ни в буфере, ни в самом потоке
  // больше не хватает байт для считывания хотя бы одной полной записи!
  Result := (AvailableInBuffer < FRecordLength) and (AvailableInStream < FRecordLength);
end;

procedure TBufferedStreamReader.FillBuffer;
begin
  FBufferSize := FStream.Read(FBuffer[0], FChankSize);
  FBufferPos := 0;
end;

function TBufferedStreamReader.ReadNextRecord(out RecordData: TBytes): Boolean;
begin
  Result := False;
  if Eof then Exit;

  // Если текущий буфер исчерпан — подкачиваем следующий блок из потока
  if (FBufferSize - FBufferPos) < FRecordLength then
  begin
    FillBuffer;
    if FBufferSize = 0 then Exit; // Ничего не прочитано из потока
  end;

  // Выделяем память под возвращаемую запись, если она не выделена
  if Length(RecordData) <> FRecordLength then
    SetLength(RecordData, FRecordLength);

  // Копируем одну запись из кэша в памяти
  Move(FBuffer[FBufferPos], RecordData[0], FRecordLength);
  Inc(FBufferPos, FRecordLength);

  Result := True;
end;

end.
