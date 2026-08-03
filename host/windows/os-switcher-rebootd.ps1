# os-switcher-rebootd для Windows — то же, что host/linux/os-switcher-rebootd.py:
# слушает USB-serial платы, показывает обратный отсчёт в уведомлении и по
# строке "REBOOT" перезагружает машину.
#
# Плата шлёт по строке на событие:
#     COUNTDOWN 10   выключатель перещёлкнули, пошёл отсчёт (секунды)
#     CANCEL         вернули назад, отбой
#     REBOOT         время вышло
#
# ЗАПУСК ОТ ПОЛЬЗОВАТЕЛЯ, НЕ ОТ SYSTEM. Toast-уведомления живут в сессии
# пользователя: служба из сессии 0 их показать не может (та же беда, что с
# D-Bus в Linux, только обходится сложнее). А перезагрузка от обычного
# пользователя работает — право «Завершение работы системы» у интерактивных
# пользователей клиентской Windows есть по умолчанию. Поэтому скрипт ставится
# задачей планировщика «при входе в систему» от текущего пользователя
# (см. install.ps1) и прав администратора не требует.
# Обратная сторона: пока никто не залогинен, перезагружать некому — щелчок
# выключателя в этот момент ничего не сделает.
#
# ВНИМАНИЕ: на живой Windows-машине не проверялось. При первом запуске стоит
# прогнать руками в консоли (.\os-switcher-rebootd.ps1) и посмотреть, что порт
# находится и уведомление появляется.

$ErrorActionPreference = 'Stop'

$HardwareId = 'VID_2341&PID_8036'   # Arduino Leonardo / Pro Micro со скетчем
$Baud = 9600                        # не 1200: 1200 бод перезагружает плату в загрузчик
$RetrySec = 3
$ReadTimeoutMs = 1000               # он же шаг обновления отсчёта в уведомлении

$Title = 'Смена ОС'
$LogFile = Join-Path $env:LOCALAPPDATA 'os-switcher\rebootd.log'
$LogMaxBytes = 1MB

# AppUserModelID, от имени которого показываются тосты. Берём готовый ярлык
# Windows PowerShell: свой AppID потребовал бы ярлыка в меню «Пуск» с
# прописанным System.AppUserModel.ID, а это возня с IPropertyStore из COM.
# Цена — в уведомлении будет значок и подпись «Windows PowerShell».
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$ToastTagBase = 'os-switcher'   # к нему добавляется номер сессии: os-switcher-<N>
$ToastGroup = 'os-switcher'

function Write-Log([string]$Message) {
    $line = '{0} os-switcher-rebootd: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $LogMaxBytes)) {
            Remove-Item $LogFile -Force   # простая ротация: разросся — начали заново
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Лог — вещь необязательная, из-за него падать не будем.
    }
}

# --- уведомления ----------------------------------------------------------
# Одно живое уведомление, которое переписывается на каждом тике: тост
# создаётся с data binding ({body}), а дальше Update() подменяет текст по тегу.
# Прямой аналог notify-send -r <id> в Linux-версии.

$script:ToastReady = $null   # $null — ещё не пробовали, $false — не завелось
$script:ToastNotifier = $null
$script:CountdownToast = $null   # текущая живая плашка (отсчёт или итог)
$script:ToastSeq = 0             # версия NotificationData (растёт при каждом Update)
$script:SessionSeq = 0           # номер сессии → уникальный Tag, чтобы баннер всплывал
$script:LiveTag = $null          # Tag текущей плашки
$script:SessionActive = $false   # идёт ли сейчас сессия (от COUNTDOWN до итога)

function Initialize-Toast {
    if ($null -ne $script:ToastReady) { return $script:ToastReady }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.NotificationData, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $script:ToastNotifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
        $script:ToastReady = $true
    } catch {
        Write-Log "уведомления недоступны ($($_.Exception.Message)) — работаю молча"
        $script:ToastReady = $false
    }
    return $script:ToastReady
}

function New-ToastData([string]$Body) {
    # Значения передаём готовым словарём в конструктор: присваивание в
    # $data.Values[...] упирается в проекцию WinRT IMap<> и работает не везде.
    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $values.Add('body', $Body)
    $script:ToastSeq++
    return [Windows.UI.Notifications.NotificationData]::new($values, $script:ToastSeq)
}

# Одна живая плашка на всю сессию — и отсчёт, и итог. $NewSession=$true —
# показать свежий баннер (всплывает); $false — обновить текущий на месте (тихо).
function Show-Toast([string]$Body, [bool]$NewSession) {
    if (-not (Initialize-Toast)) { return }
    try {
        if (-not $NewSession -and $script:CountdownToast) {
            # Обновление на месте по тегу текущей сессии. Сравниваем со строкой,
            # а не с членом enum: тип NotificationUpdateResult пришлось бы
            # отдельно подгружать.
            $res = $script:ToastNotifier.Update((New-ToastData $Body), $script:LiveTag, $ToastGroup)
            if ("$res" -eq 'Succeeded') { return }
            # Плашка истекла (duration) или её закрыли — покажем свежую ниже.
        }

        # Свежий баннер. Каждой сессии — свой Tag: Windows дедуплицирует тосты по
        # паре Tag+Group и глушит повторный Show() с тем же тегом (кладёт в Центр
        # уведомлений без всплытия, пока тег не «забудется» — те самые ~10 с).
        # Новый тег на сессию => баннер всплывает всегда.
        if ($script:CountdownToast) {
            try { $script:ToastNotifier.Hide($script:CountdownToast) } catch { }
        }
        $script:SessionSeq++
        $script:LiveTag = '{0}-{1}' -f $ToastTagBase, $script:SessionSeq

        # duration='long' держит уведомление на экране ~25 секунд. Текст идёт
        # через data binding ({body} + NotificationData), поэтому & и < в теле
        # (например в сообщении об ошибке) экранировать не нужно — LoadXml их не
        # видит.
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml(@"
<toast duration='long'>
  <visual>
    <binding template='ToastGeneric'>
      <text>$Title</text>
      <text>{body}</text>
    </binding>
  </visual>
</toast>
"@)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $toast.Tag = $script:LiveTag
        $toast.Group = $ToastGroup
        $toast.Data = New-ToastData $Body
        $script:ToastNotifier.Show($toast)
        $script:CountdownToast = $toast
    } catch {
        Write-Log "уведомление не показалось: $($_.Exception.Message)"
    }
}

# Тик отсчёта. Первый тик новой сессии всплывает свежим баннером, дальше та же
# плашка обновляется на месте.
function Show-Countdown([int]$SecondsLeft) {
    $body = "Перезагрузка через $SecondsLeft с.`nВерни выключатель, чтобы отменить."
    Show-Toast $body (-not $script:SessionActive)
    $script:SessionActive = $true
}

function Hide-Countdown {
    if ($script:CountdownToast) {
        try { $script:ToastNotifier.Hide($script:CountdownToast) } catch { }
        $script:CountdownToast = $null
    }
    $script:SessionActive = $false
}

# Заменить отсчёт коротким итогом («Отменено», «Перезагружаюсь»). Пока сессия
# жива — меняем ту же плашку на месте; иначе показываем отдельным баннером.
function Show-Result([string]$Body) {
    Show-Toast $Body (-not $script:SessionActive)
    $script:SessionActive = $false
}

# --- порт и перезагрузка --------------------------------------------------

function Find-BoardPort {
    $dev = Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like "*$HardwareId*" -and $_.Name -match '\(COM\d+\)' } |
        Select-Object -First 1
    if ($null -eq $dev) { return $null }
    if ($dev.Name -match '\((COM\d+)\)') { return $Matches[1] }
    return $null
}

function Invoke-Reboot {
    Write-Log 'получена команда REBOOT, перезагружаюсь'
    Show-Result 'Перезагружаюсь…'
    try {
        # Без /f: приложениям дают закрыться штатно, как systemctl reboot.
        & shutdown.exe /r /t 0
    } catch {
        Write-Log "перезагрузка не удалась: $($_.Exception.Message)"
        Show-Result "Перезагрузка не удалась: $($_.Exception.Message)"
    }
}

# --- основной цикл --------------------------------------------------------

Write-Log "старт, ищу плату ($HardwareId)"

while ($true) {
    $portName = Find-BoardPort
    if ($null -eq $portName) {
        Write-Log 'плата не найдена, жду'
        Start-Sleep -Seconds $RetrySec
        continue
    }

    $port = New-Object System.IO.Ports.SerialPort $portName, $Baud, 'None', 8, 'One'
    $port.NewLine = "`n"
    $port.ReadTimeout = $ReadTimeoutMs
    $port.DtrEnable = $true   # без DTR плата не считает порт открытым и молчит

    $deadline = $null   # когда плата пришлёт REBOOT
    $shown = $null      # последнее показанное значение отсчёта

    try {
        $port.Open()
        Write-Log "слушаю $portName"

        while ($true) {
            $text = ''
            try {
                $line = $port.ReadLine()
                if ($line) { $text = $line.Trim() }
            } catch [System.TimeoutException] {
                # Плата молчит — это норма, просто идём тикать отсчётом.
            }

            if ($text -like 'COUNTDOWN*') {
                $secs = 10
                $parts = $text -split '\s+'
                if ($parts.Count -gt 1 -and $parts[1] -match '^\d+$') { $secs = [int]$parts[1] }
                Write-Log "пошёл отсчёт: $secs с"
                $deadline = (Get-Date).AddSeconds($secs)
                $shown = $null
            }
            elseif ($text -eq 'CANCEL') {
                Write-Log 'отсчёт отменён'
                $deadline = $null
                $shown = $null
                Show-Result 'Отменено — выключатель вернули назад.'
            }
            elseif ($text -eq 'REBOOT') {
                $deadline = $null
                Invoke-Reboot
                # Перезагрузка асинхронная: хвост не читаем, чтобы не поймать
                # повторы той же команды и не запустить её второй раз.
                return
            }
            elseif ($text) {
                Write-Log "игнорирую неизвестную строку: $text"
            }

            # Тик отсчёта. Сюда попадаем и по таймауту чтения (раз в секунду),
            # так что уведомление обновляется, даже когда плата молчит.
            if ($null -ne $deadline) {
                $left = [int][Math]::Round(($deadline - (Get-Date)).TotalSeconds)
                if ($left -lt 0) { $left = 0 }
                if ($left -ne $shown) {
                    $shown = $left
                    Show-Countdown $left
                }
            }
        }
    } catch {
        Write-Log "порт отвалился ($($_.Exception.Message)), переоткрываю"
        Hide-Countdown
        Start-Sleep -Seconds $RetrySec
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}
