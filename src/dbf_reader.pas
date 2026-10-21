unit dbf_reader;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  // 1. Основной заголовок DBF (32 байта)
  TDBFHeader = packed record
    Version: Byte;
    LastUpdateY: Byte;
    LastUpdateM: Byte;
    LastUpdateD: Byte;
    FullRecCount: Cardinal;
    HeaderLength: Word;
    RecordLength: Word;
    Reserved1: array[0..15] of Byte;
    TransactionFlag: Byte;
    CodePageMark: Byte;
    Reserved2: array[0..1] of Byte;
  end;

  // 2. Дескриптор одного поля (32 байта)
  TDBFFieldDescriptor = packed record
    FieldName: array[0..10] of AnsiChar; // 11 байт: Имя поля (завершается 0x00)
    FieldType: AnsiChar;                // 1 байт: Тип (C-Char, N-Numeric, D-Date, L-Logical и т.д.)
    FieldOffset: Cardinal;              // 4 байта: Смещение поля в памяти (используется в FoxPro)
    FieldLength: Byte;                  // 1 байт: Длина поля в байтах
    FieldDecimal: Byte;                 // 1 байт: Количество знаков после запятой (для Numeric)
    Flags: Byte;                        // 1 байт: Флаги поля FoxPro
    AutoIncNext: Cardinal;              // 4 байта: Следующее значение AutoInc
    AutoIncStep: Byte;                  // 1 байт: Шаг AutoInc
    Reserved: array[0..7] of Byte;      // 8 байт: Резерв
  end;

  // 3. класс для хранения метаданных таблицы
  TDBFFieldInfo = class
  public
    Name: string;       // Имя поля в Unicode
    FieldType: Char;    // Тип ('C', 'N', 'D', 'L' и т.д.)
    Offset: Integer;    // Физическое смещение от начала записи (включая байт удаления!)
    Length: Integer;    // Длина поля в байтах
    Decimals: Integer;  // Точность для чисел
  end;

  TDBFSchema = TObjectList<TDBFFieldInfo>;

function ReadDbfSchema(const DbfPath: string; out Header: TDBFHeader): TDBFSchema; overload;
function ReadDbfSchema(const Stream: TStream; out Header: TDBFHeader): TDBFSchema; overload;

implementation


function ReadDbfSchema(const DbfPath: string; out Header: TDBFHeader): TDBFSchema;
var
  FS: TFileStream;
begin
  // Открываем файл в режиме чтения, не блокируя файл
  FS := TFileStream.Create(DbfPath, fmOpenRead or fmShareDenyNone);
  try
    Result := ReadDbfSchema(FS, Header);
  finally
    FS.Free;
  end;
end;

function ReadDbfSchema(const Stream: TStream; out Header: TDBFHeader): TDBFSchema;
var
  Descriptor: TDBFFieldDescriptor;
  FieldInfo: TDBFFieldInfo;
  CurrentOffset: Integer;
  Terminator: Byte;
  RawName: AnsiString;
begin
  Result := TDBFSchema.Create(True); // True = автоматическое удаление объектов из списка

  // Открываем файл в режиме чтения, не блокируя файл
  try
    Stream.Position := 0;

    // 1. Читаем основной заголовок
    Stream.ReadBuffer(Header, SizeOf(TDBFHeader));

    // В DBF первая запись всегда начинается с байта удаления (0x20 или 0x2A).
    // Поэтому первое реальное поле всегда имеет смещение 1.
    CurrentOffset := 1;

    // Позиционируем поток на начало дескрипторов полей (смещение 32)
    Stream.Seek(32, soFromBeginning);

    // 2. Читаем дескрипторы полей в цикле
    while Stream.Position < Header.HeaderLength do
    begin
      // Проверяем, не дошли ли мы до байта-терминатора (0x0D), который разделяет схему и данные
      Stream.ReadBuffer(Terminator, 1);
      if Terminator = $0D then
        Break; // Схема полей успешно прочитана

      // Возвращаем указатель на 1 байт назад, чтобы прочитать дескриптор целиком
      Stream.Seek(-1, soFromCurrent);
      Stream.ReadBuffer(Descriptor, SizeOf(TDBFFieldDescriptor));

      // Создаем объект метаданных
      FieldInfo := TDBFFieldInfo.Create;

      // Преобразуем имя поля из Ansi в Unicode-строку Delphi
      SetString(RawName, Descriptor.FieldName, StrLen(Descriptor.FieldName));
      FieldInfo.Name := string(RawName);

      FieldInfo.FieldType := Char(Descriptor.FieldType);
      FieldInfo.Length    := Descriptor.FieldLength;
      FieldInfo.Decimals  := Descriptor.FieldDecimal;

      // Накапливаем смещение. Спецификация FoxPro внутри Descriptor.FieldOffset
      // часто хранит системные данные, поэтому надежнее рассчитывать смещение вручную:
      FieldInfo.Offset    := CurrentOffset;
      CurrentOffset       := CurrentOffset + Descriptor.FieldLength;

      Result.Add(FieldInfo);
    end;

  except
    on E: Exception do
    begin
      Result.Free;
      raise Exception.CreateFmt('Ошибка парсинга структуры файла: %s', [E.Message]);
    end;
  end;
end;

end.
