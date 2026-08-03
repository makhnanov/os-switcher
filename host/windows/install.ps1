# Установка os-switcher-rebootd в Windows: копирует демон в профиль
# пользователя и вешает его на автозапуск при входе в систему.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1     # поставить
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# Права администратора НЕ нужны: всё ставится в свой профиль, задача
# планировщика регистрируется от текущего пользователя. Так и задумано —
# демону нужна пользовательская сессия, чтобы показывать уведомления
# (подробности в шапке os-switcher-rebootd.ps1).

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$TaskName = 'os-switcher-rebootd'
$InstallDir = Join-Path $env:LOCALAPPDATA 'os-switcher'
$ScriptName = 'os-switcher-rebootd.ps1'
$Target = Join-Path $InstallDir $ScriptName

function Remove-Task {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Задача '$TaskName' удалена."
    } else {
        Write-Host "Задачи '$TaskName' не было."
    }
}

if ($Uninstall) {
    Remove-Task
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Host "Каталог $InstallDir удалён."
    }
    Write-Host 'Готово. Плата продолжит выбирать ОС в GRUB — перестанет работать только перезагрузка по щелчку.'
    return
}

$source = Join-Path $PSScriptRoot $ScriptName
if (-not (Test-Path $source)) {
    throw "Не нашёл $ScriptName рядом с install.ps1 (ожидал $source)"
}

# 1. Скопировать демон в профиль. Из каталога репозитория запускать не стоит:
#    репозиторий может уехать или лежать на разделе другой ОС.
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item $source $Target -Force
Write-Host "Демон установлен: $Target"

# 2. Перерегистрировать задачу автозапуска.
Remove-Task

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Target`""

$user = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user

# ExecutionTimeLimit = 0 — задача живёт бесконечно (по умолчанию планировщик
# убил бы её через 3 дня). MultipleInstances IgnoreNew — второй экземпляр не
# нужен, порт всё равно занят первым.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# RunLevel Limited — без повышения прав: перезагрузить машину интерактивный
# пользователь может и так.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'os-switcher: перезагрузка по щелчку выключателя выбора ОС' | Out-Null
Write-Host "Задача '$TaskName' зарегистрирована (запуск при входе в систему)."

# 3. Запустить сейчас, не дожидаясь следующего входа.
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "Состояние задачи: $state"

$log = Join-Path $InstallDir 'rebootd.log'
Write-Host ''
Write-Host 'Проверить, что плата нашлась:'
Write-Host "    Get-Content '$log' -Tail 20 -Wait"
Write-Host ''
Write-Host 'Ожидаемая строка в логе: «слушаю COMx». Если там «плата не найдена» —'
Write-Host 'посмотри в диспетчере устройств, виден ли COM-порт Arduino Leonardo.'
