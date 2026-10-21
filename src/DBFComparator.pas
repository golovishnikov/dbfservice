unit DBFComparator;

interface

uses
  System.Classes,System.SysUtils, dbf_reader;

type
  // Процедуры обратного вызова (события) для отправки данных в Postgres
  TOnRecordChanged = procedure(RecNo: Integer; const NewRecordData: TBytes) of object;
  TOnTailDeleted = procedure(FromRecNo: Integer) of object;

  TDBFComparator = class
  private
    FOnRecordChanged: TOnRecordChanged;
    FOnTailDeleted: TOnTailDeleted;
    const BUFFER_SIZE = 1024 * 1024; // Размер кэш-буфера для чтения (1 МБ)
  public
    procedure CompareStreams(NewDBF, EtalDBF: TStream; const Header: TDBFHeader);
    property OnRecordChanged: TOnRecordChanged read FOnRecordChanged write FOnRecordChanged;
    property OnTailDeleted: TOnTailDeleted read FOnTailDeleted write FOnTailDeleted;
  end;

implementation

uses
  System.IOUtils, BufferedStreamReader;

{ TDBFComparator }

procedure TDBFComparator.CompareStreams(NewDBF, EtalDBF: TStream;
  const Header: TDBFHeader);
var
  CurrentRecNo: Integer;

  SingleNewRec, SingleEtalRec: TBytes;
  IsDifferent: Boolean;

  NewFile: TBufferedStreamReader;
  EtalFile: TBufferedStreamReader;
begin

  NewFile := TBufferedStreamReader.Create(NewDBF, Header.HeaderLength, Header.RecordLength);
  EtalFile := TBufferedStreamReader.Create(EtalDBF, Header.HeaderLength, Header.RecordLength);
  try

    CurrentRecNo := 1;

    // ОСНОВНОЙ ЦИКЛ: Сравнение пересекающихся частей файлов
    while not NewFile.Eof and not EtalFile.Eof do
    begin
      if not NewFile.ReadNextRecord(SingleNewRec) then
        raise Exception.Create('Не удалось прочитать запись из нового файла.');
      if not EtalFile.ReadNextRecord(SingleEtalRec) then
        raise Exception.Create('Не удалось прочитать запись из эталонного файла.');

      IsDifferent := not CompareMem(@SingleNewRec[0], @SingleEtalRec[0], Header.RecordLength);

      if IsDifferent then
      begin
        // Вызываем событие изменения. Поток-владелец получит команду и отправит UPDATE в Postgres
        if Assigned(FOnRecordChanged) then
          FOnRecordChanged(CurrentRecNo, SingleNewRec);
      end;

      Inc(CurrentRecNo);
    end;

    // Если новый файл оказался ДЛИННЕЕ (добавление записей)
    while not NewFile.Eof do
    begin
      if not NewFile.ReadNextRecord(SingleNewRec) then
        raise Exception.Create('Не удалось прочитать новую запись из нового файла.');

      // Вызываем событие добавления записи (в Postgres это уйдет как INSERT)
      if Assigned(FOnRecordChanged) then
        FOnRecordChanged(CurrentRecNo, SingleNewRec);

      Inc(CurrentRecNo);
    end;

    // Если новый файл оказался КОРОЧЕ (был PACK, записи физически удалены).
    // Или эталонный файл нулевой длины (первое копирование записей)
    if not EtalFile.Eof or (EtalDBF.Size = 0) then
    begin
      if Assigned(FOnTailDeleted) then
        FOnTailDeleted(CurrentRecNo); // Передаем стартовый индекс удаления "хвоста"
    end;
  finally
    NewFile.Free;
    EtalFile.Free;
  end;

end;

end.
