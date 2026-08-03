# os-switcher-rebootd для Windows — то же, что os-switcher-rebootd.py в Linux:
# слушает USB-serial платы и по строке "REBOOT" перезагружает машину.
#
# Установка (PowerShell от администратора):
#   Copy-Item os-switcher-rebootd.ps1 C:\ProgramData\os-switcher\
#   schtasks /Create /TN os-switcher-rebootd /RU SYSTEM /SC ONSTART /RL HIGHEST /F ^
#     /TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\os-switcher\os-switcher-rebootd.ps1"
#   schtasks /Run /TN os-switcher-rebootd
#
# ВНИМАНИЕ: не проверялось на живой Windows-машине — при первом запуске стоит
# прогнать скрипт руками в консоли и убедиться, что порт находится.

$ErrorActionPreference = 'Stop'
$HardwareId = 'VID_2341&PID_8036'   # Arduino Leonardo / Pro Micro со скетчем
$Baud = 9600                        # не 1200: 1200 бод перезагружает плату в загрузчик
$Command = 'REBOOT'
$RetrySec = 3

function Find-BoardPort {
    $dev = Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like "*$HardwareId*" -and $_.Name -match '\(COM(\d+)\)' } |
        Select-Object -First 1
    if ($null -eq $dev) { return $null }
    if ($dev.Name -match '\((COM\d+)\)') { return $Matches[1] }
    return $null
}

while ($true) {
    $portName = Find-BoardPort
    if ($null -eq $portName) {
        Write-Output "os-switcher-rebootd: плата не найдена ($HardwareId), жду"
        Start-Sleep -Seconds $RetrySec
        continue
    }

    $port = New-Object System.IO.Ports.SerialPort $portName, $Baud, 'None', 8, 'One'
    $port.NewLine = "`n"
    $port.ReadTimeout = 1000
    $port.DtrEnable = $true

    try {
        $port.Open()
        Write-Output "os-switcher-rebootd: слушаю $portName"
        while ($true) {
            try { $line = $port.ReadLine() } catch [TimeoutException] { continue }
            $line = $line.Trim()
            if ($line -like 'COUNTDOWN*') {
                # msg отправляет сообщение в сессию пользователя и работает даже
                # из-под SYSTEM. Обновлять его на месте, как notify-send в Linux,
                # нельзя — показываем один раз в начале отсчёта.
                $secs = ($line -split '\s+')[1]
                if (-not $secs) { $secs = '10' }
                & msg.exe * /time:$secs "Смена ОС: перезагрузка через $secs с. Верни выключатель, чтобы отменить."
            }
            elseif ($line -eq $Command) {
                Write-Output "os-switcher-rebootd: получена команда $Command, перезагружаюсь"
                & shutdown.exe /r /t 0
                return
            }
        }
    } catch {
        Write-Output "os-switcher-rebootd: порт отвалился ($($_.Exception.Message)), переоткрываю"
        Start-Sleep -Seconds $RetrySec
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}
