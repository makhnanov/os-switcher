#!/usr/bin/env python3
"""os-switcher-rebootd — слушает USB-serial платы и перезагружает машину.

Плата (см. os-switcher-sketch) шлёт по строке на событие:

    COUNTDOWN 10   выключатель перещёлкнули, пошёл отсчёт (секунды)
    CANCEL         вернули назад, отбой
    REBOOT         время вышло

На COUNTDOWN сервис показывает уведомление с обратным отсчётом («перезагрузка
через N с, верни выключатель, чтобы отменить»), обновляя его раз в секунду;
на CANCEL — гасит; на REBOOT — делает штатную перезагрузку.

Уведомления идут через notify-send. Сервис работает от root, а шина
уведомлений — в сессии пользователя, поэтому активная графическая сессия
ищется через loginctl, и notify-send запускается от её владельца. Нет сессии
или notify-send — сервис просто работает без уведомлений.

Переменные окружения:
  OS_SWITCHER_PORT_GLOB  — шаблон пути к порту
  OS_SWITCHER_BAUD       — скорость (НЕ 1200: на ATmega32u4 открытие порта на
                           1200 бод перезагружает плату в загрузчик)
  OS_SWITCHER_REBOOT_CMD — команда перезагрузки (для сухого прогона удобно
                           подставить echo)
"""

import glob
import os
import shlex
import shutil
import subprocess
import sys
import time

import serial

PORT_GLOB = os.environ.get(
    "OS_SWITCHER_PORT_GLOB", "/dev/serial/by-id/*Arduino*Leonardo*"
)
BAUD = int(os.environ.get("OS_SWITCHER_BAUD", "9600"))
REBOOT_CMD = shlex.split(os.environ.get("OS_SWITCHER_REBOOT_CMD", "systemctl reboot"))
RETRY_SEC = 3
READ_TIMEOUT_SEC = 1  # он же шаг обновления отсчёта в уведомлении

APP_NAME = "os-switcher"
TITLE = "Смена ОС"


def log(msg):
    print(f"os-switcher-rebootd: {msg}", flush=True)


def find_port():
    ports = sorted(glob.glob(PORT_GLOB))
    return ports[0] if ports else None


class Notifier:
    """Одно живое уведомление, которое переписывается на каждом тике.

    notify-send -p печатает id уведомления, notify-send -r <id> заменяет его же,
    поэтому отсчёт тикает на месте, а не сыплет десять уведомлений подряд.
    """

    def __init__(self):
        self.notif_id = None
        self.available = shutil.which("notify-send") is not None
        if not self.available:
            log("notify-send не найден — работаю без уведомлений")
        # Сессию ищем не здесь, а в начале каждого отсчёта: при старте на
        # загрузке графической сессии ещё нет, да и пользователь мог смениться.
        self.session = None

    @staticmethod
    def _find_graphical_session():
        """(uid, имя пользователя) активной графической сессии или None."""
        try:
            listing = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                capture_output=True, text=True, timeout=5,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            return None

        for line in listing.splitlines():
            fields = line.split()
            if not fields:
                continue
            try:
                shown = subprocess.run(
                    ["loginctl", "show-session", fields[0],
                     "-p", "Active", "-p", "Type", "-p", "User", "-p", "Name"],
                    capture_output=True, text=True, timeout=5,
                ).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            props = dict(
                kv.split("=", 1) for kv in shown.splitlines() if "=" in kv
            )
            if props.get("Active") == "yes" and props.get("Type") in ("x11", "wayland"):
                return props.get("User"), props.get("Name")
        return None

    def _notify_send(self, args):
        """notify-send от имени владельца сессии; возвращает stdout или ''."""
        if not self.available or self.session is None:
            return ""
        uid, user = self.session
        cmd = ["notify-send", "-a", APP_NAME] + args
        if str(os.geteuid()) != str(uid):
            # Из-под root — переключиться в сессию пользователя и её шину.
            cmd = [
                "sudo", "-u", user, "env",
                f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus",
                f"XDG_RUNTIME_DIR=/run/user/{uid}",
            ] + cmd
        try:
            done = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError) as exc:
            log(f"уведомление не показалось: {exc}")
            return ""
        if done.returncode != 0:
            log(f"notify-send вернул {done.returncode}: {done.stderr.strip()}")
        return done.stdout

    def tick(self, seconds_left):
        """Показать/обновить уведомление с обратным отсчётом."""
        args = ["-u", "critical", "-t", "0", "-p"]
        if self.notif_id:
            args += ["-r", str(self.notif_id)]
        else:
            # Начало отсчёта — перепроверить, в какой сессии сейчас пользователь.
            self.session = self._find_graphical_session()
            if self.available and self.session is None:
                log("активная графическая сессия не найдена — без уведомлений")
        args += [TITLE, f"Перезагрузка через {seconds_left} с.\n"
                        f"Верни выключатель, чтобы отменить."]
        out = self._notify_send(args).strip()
        if out.isdigit():
            self.notif_id = int(out)

    def finish(self, text, urgency="normal", timeout_ms=4000):
        """Заменить отсчёт коротким итоговым уведомлением."""
        if self.notif_id is None:
            return
        args = ["-u", urgency, "-t", str(timeout_ms), "-r", str(self.notif_id),
                TITLE, text]
        self._notify_send(args)
        self.notif_id = None


def do_reboot(notifier):
    log(f"получена команда REBOOT, выполняю: {' '.join(REBOOT_CMD)}")
    notifier.finish("Перезагружаюсь…", urgency="critical", timeout_ms=10000)
    try:
        subprocess.run(REBOOT_CMD, check=True)
    except Exception as exc:  # noqa: BLE001 — сервис не должен падать из-за этого
        log(f"перезагрузка не удалась: {exc}")
        notifier.finish(f"Перезагрузка не удалась: {exc}", urgency="critical")


def serve(port, notifier):
    log(f"слушаю {port}")
    deadline = None  # время, когда плата пришлёт REBOOT
    shown = None     # последнее показанное значение отсчёта
    with serial.Serial(port, BAUD, timeout=READ_TIMEOUT_SEC) as ser:
        while True:
            line = ser.readline()
            text = line.decode("ascii", errors="replace").strip() if line else ""

            if text.startswith("COUNTDOWN"):
                parts = text.split()
                seconds = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 10
                log(f"пошёл отсчёт: {seconds} с")
                deadline = time.monotonic() + seconds
                shown = None
            elif text == "CANCEL":
                log("отсчёт отменён")
                deadline = None
                shown = None
                notifier.finish("Отменено — выключатель вернули назад.")
            elif text == "REBOOT":
                deadline = None
                do_reboot(notifier)
                # Перезагрузка асинхронная: не читаем хвост, чтобы не поймать
                # повторы той же команды и не запускать её второй раз.
                return
            elif text:
                log(f"игнорирую неизвестную строку: {text!r}")

            # Тик отсчёта. Сюда попадаем и по таймауту чтения (раз в секунду),
            # так что уведомление обновляется, даже когда плата молчит.
            if deadline is not None:
                left = max(0, int(round(deadline - time.monotonic())))
                if left != shown:
                    shown = left
                    notifier.tick(left)


def main():
    notifier = Notifier()
    while True:
        port = find_port()
        if port is None:
            log(f"плата не найдена ({PORT_GLOB}), жду")
        else:
            try:
                serve(port, notifier)
                return 0
            except serial.SerialException as exc:
                log(f"порт отвалился ({exc}), переоткрываю")
            except OSError as exc:
                log(f"ошибка ввода-вывода ({exc}), переоткрываю")
        time.sleep(RETRY_SEC)


if __name__ == "__main__":
    sys.exit(main())
