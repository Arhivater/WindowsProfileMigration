# Меню принимает цифры и возвращает выбор пользователя.

function Title([string]$Value) {
    Write-Host ''
    Write-Host ('=== ' + $Value + ' ===') -ForegroundColor Cyan
}
# Разрешает ввод только целого числа в заданном диапазоне.
function Choice([string]$Prompt, [int]$Maximum, [int]$Minimum = 0) {
    if ($Maximum -lt $Minimum) { throw 'Нет доступных вариантов для выбора.' }
    while ($true) {
        $answer = Read-Host $Prompt
        if ($null -eq $answer) {
            if ($Minimum -le 0 -and $Maximum -ge 0) { return 0 }
            throw [System.OperationCanceledException]::new('Ввод завершён.')
        }
        $s = $answer.Trim()
        $n = 0
        if ([int]::TryParse($s, [ref]$n) -and $n -ge $Minimum -and $n -le $Maximum) { return $n }
        Write-Host ('Введите число от {0} до {1}.' -f $Minimum, $Maximum) -ForegroundColor Yellow
    }
}
# Любое потенциально важное действие выполняется только после выбора «1».
# 0 и 2 отменяют действие, в том числе при подтверждении удаления данных.
function Confirm([string]$Prompt) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host '  1. Да, продолжить'
    Write-Host '  2. Нет, отменить'
    Write-Host '  0. Назад / отменить'
    return ((Choice 'Выберите 0, 1 или 2' 2) -eq 1)
}
# 0 также разрешён после завершения, отмены или сбоя операции.
function Pause-Menu {
    Write-Host '0. Назад'
    Write-Host '1. Вернуться в меню'
    [void](Choice 'Введите 0 или 1' 1)
}
