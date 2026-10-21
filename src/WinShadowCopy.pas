unit WinShadowCopy;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils;

type
  TOnError = procedure(Error: string) of object;

  /// <summary>
  ///   Класс управления теневыми копиями разделов.
  ///  Создает теневую копию указанного раздела и монтирует в указанную папку.
  ///  Папка не должна существовать или должна быть пустой.
  ///  Копия создается при создании экземпляра класса, удаляется при уничтожении экземпляра класса.
  /// </summary>
  TWinShadowCopy = class
  private
    FVolumeChar: Char;
    FShadowGuid: string;
    FLocalExposePath: string;
    FIsMounted: Boolean;
    FOnError: TOnError;
    // выполнить консольную программу и вернуть результат выполнения
    function ExecuteCmd(const CmdLine: string; out Output: string): Boolean;
    // извлечь GUID теневой копии из вывода консольной программы
    function ParseGuidFromOutput(const Output: string): string;
  public
    /// <summary>
    ///   Конструктор.
    /// </summary>
    /// <param name="VolumeChar: Char">
    /// Имя диска, копию которого нужно сделать
    /// </param>
    /// <param name="LocalExposePath: string">
    /// Полный путь до папки, в которую смонтировать теневую копию
    /// </param>
    /// <param name="OnError: TOnError">
    /// Метод для обработки ошибок, возникающих при выполнении консольных команд.
    ///  В консоли выполняются дейсвия по созданию, монтированию и удалению теневых копий.
    /// </param>
    constructor Create(VolumeChar: Char; const LocalExposePath: string; OnError: TOnError);
    /// <summary>
    ///   Деструктор.
    ///  Удаляет созданную теневую копию раздела.
    /// </summary>
    destructor Destroy; override;

    /// <summary>
    ///   Выполнено ли монтирование теневой копии.
    /// </summary>
    property IsMounted: Boolean read FIsMounted;
    /// <summary>
    ///   Полный путь до папки монтирования теневой копии.
    /// </summary>
    property ShadowPath: string read FLocalExposePath;
  end;

implementation

constructor TWinShadowCopy.Create(VolumeChar: Char;
  const LocalExposePath: string; OnError: TOnError);
var
  Output: string;
  Cmd: string;
  ExeDir: string;
begin
  inherited Create;
  FOnError := OnError;
  FVolumeChar := UpCase(VolumeChar);
  FLocalExposePath := IncludeTrailingPathDelimiter(LocalExposePath);
  FIsMounted := False;

  // Убеждаемся, что папка для монтирования пуста и существует
  if DirectoryExists(FLocalExposePath) then
    TDirectory.Delete(FLocalExposePath, True);
  ForceDirectories(FLocalExposePath);

  ExeDir := ExtractFilePath(ParamStr(0));

  // 1. Создаем теневую копию.
  Cmd := Format('"%svshadow.exe" -p -nw %s:', [ExeDir, FVolumeChar]);

  if ExecuteCmd(Cmd, Output) then
  begin
    FShadowGuid := ParseGuidFromOutput(Output);

    if FShadowGuid <> '' then
    begin
      // 2. Монтируем (экспонируем) созданный снимок в нашу локальную папку
      Cmd := Format('"%svshadow.exe" -el=%s,%s', [ExeDir, FShadowGuid, ExcludeTrailingPathDelimiter(FLocalExposePath)]);
      if ExecuteCmd(Cmd, Output) then
        FIsMounted := True
      else
        raise Exception.Create(Output);
    end;
  end
  else
    raise Exception.Create(Output);
  if not FIsMounted then
    raise Exception.Create('Не удалось инициализировать теневой снимок диска.');
end;

destructor TWinShadowCopy.Destroy;
var
  Cmd: string;
  ExeDir: string;
  Output: string;
begin
  ExeDir := ExtractFilePath(ParamStr(0));

  // При штатном закрытии — размонтируем и удаляем снимок вручную
  if FIsMounted and (FShadowGuid <> '') then
  begin
    Cmd := Format('"%svshadow.exe" -ds=%s', [ExeDir, FShadowGuid]);
    ExecuteCmd(Cmd, Output);
  end;

  // Очищаем локальную временную папку ссылки
  if DirectoryExists(FLocalExposePath) then
    try
      TDirectory.Delete(FLocalExposePath, True);
    except
      on E: Exception do
        if Assigned(FOnError) then
          FOnError(E.Message);
    end;

  inherited;
end;

// Вспомогательная функция скрытого запуска vshadow.exe через WinAPI CreateProcess
function TWinShadowCopy.ExecuteCmd(const CmdLine: string; out Output: string): Boolean;
var
  SecAttributes: TSecurityAttributes;
  ReadPipe, WriteHandle: THandle;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  AnsiOut: AnsiString;
  CmdBuf: string;
  ExitCode: DWORD; // Переменная для хранения кода возврата процесса
begin
  Result := False;
  Output := '';
  CmdBuf := CmdLine; // Переносим в модифицируемую переменную для CreateProcess

  SecAttributes.nLength := SizeOf(TSecurityAttributes);
  SecAttributes.bInheritHandle := True;
  SecAttributes.lpSecurityDescriptor := nil;

  if CreatePipe(ReadPipe, WriteHandle, @SecAttributes, 0) then
  begin
    FillChar(StartupInfo, SizeOf(TStartupInfo), 0);
    StartupInfo.cb := SizeOf(TStartupInfo);
    StartupInfo.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    StartupInfo.wShowWindow := SW_HIDE; // Скрываем консольное окно
    StartupInfo.hStdOutput := WriteHandle;
    StartupInfo.hStdError := WriteHandle;

    if CreateProcess(nil, PChar(CmdBuf), nil, nil, True, 0, nil, nil, StartupInfo, ProcessInfo) then
    begin
      // Закрываем этот хэндл записи СРАЗУ, чтобы наш цикл ReadFile не завис намертво
      // при ожидании окончания работы процесса
      CloseHandle(WriteHandle);

      // Читаем весь текстовый вывод утилиты из Pipe
      while ReadFile(ReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and (BytesRead > 0) do
      begin
        Buffer[BytesRead] := #0;
        AnsiOut := AnsiOut + AnsiString(Buffer);
      end;

      Output := string(AnsiOut);

      // Ждем, пока процесс физически завершит свою работу в ОС
      WaitForSingleObject(ProcessInfo.hProcess, INFINITE);

      // МАГИЯ ПЕРЕХВАТА: Запрашиваем у Windows код возврата закрывшегося процесса
      GetExitCodeProcess(ProcessInfo.hProcess, ExitCode);

      CloseHandle(ProcessInfo.hProcess);
      CloseHandle(ProcessInfo.hThread);

      // Проверяем код возврата: если он равен 0, то команда выполнена успешно
      if ExitCode = 0 then
        Result := True
      else
      begin
        Result := False;
        // Если код не 0, можно сразу дополнить лог или вывести ошибку
        Output := Format('[СИСТЕМНАЯ ОШИБКА]: %s (ExitCode) = %d', [CmdLine, ExitCode]) + sLineBreak + Output;
        if Assigned(FOnError) then
          FOnError(Output);
      end;
    end
    else
    begin
      // СЮДА МЫ ПОПАДАЕМ, ЕСЛИ ПРОЦЕСС НЕ ЗАПУСТИЛСЯ В ПРИНЦИПЕ
      Result := False;

      // Закрываем хэндл записи, так как процесс не создался
      CloseHandle(WriteHandle);

      // Извлекаем код ошибки Windows и переводим его в текст
      Output := Format('[КРИТИЧЕСКАЯ ОШИБКА ОС]: %s.' + sLineBreak +
                       'Код ошибки Windows: %d (%s)', [CmdLine, GetLastError, SysErrorMessage(GetLastError)]);
      if Assigned(FOnError) then
        FOnError(Output);
    end;

    CloseHandle(ReadPipe);
  end;
end;


function TWinShadowCopy.ParseGuidFromOutput(const Output: string): string;
var
  Lines: TStringList;
  I: Integer;
  PosStart, PosEnd: Integer;
  TargetLine: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      TargetLine := Lines[I];

      // Ищем маркер начала GUID строки
      PosStart := Pos('SNAPSHOT ID =', UpperCase(TargetLine));
      if PosStart > 0 then
      begin
        // Сдвигаем указатель на начало самого GUID (на символ '{')
        Inc(PosStart, 13);
        Result := Trim(Copy(TargetLine, PosStart, Length(TargetLine)));

        // Магия исправления: ищем закрывающую фигурную скобку '}'
        PosEnd := Pos('}', Result);
        if PosEnd > 0 then
        begin
          // Обрезаем всё лишнее (включая пробелы и те самые три точки ' ...')
          Result := Copy(Result, 1, PosEnd);
          Break;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

end.

