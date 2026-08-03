# os-switcher — сборка и прошивка через arduino-cli.
#
# Цели:
#   make            — собрать и прошить (то же, что make flash)
#   make build      — только собрать скетч
#   make flash      — собрать и прошить (порт определяется автоматически,
#                     можно задать вручную: make flash PORT=/dev/ttyACM0)
#   make ports      — показать подключённые платы
#   make clean      — удалить артефакты сборки
#
#   make install-service   — поставить сервис перезагрузки по щелчку (sudo)
#   make uninstall-service — снять его (sudo)
#   make service-logs      — журнал сервиса

CLI     ?= /opt/arduino-ide/resources/app/lib/backend/resources/arduino-cli
FQBN    ?= arduino:avr:leonardo
SKETCH  ?= os-switcher-sketch
PORT    ?= $(firstword $(wildcard /dev/ttyACM*))
SERVICE ?= os-switcher-rebootd

.PHONY: all build flash ports clean install-service uninstall-service service-logs

all: flash

build:
	"$(CLI)" compile --fqbn $(FQBN) $(SKETCH)

# Сервис держит порт открытым, а прошивка дёргает его на 1200 бод и ждёт
# появления загрузчика — на время upload сервис останавливаем.
flash: build
	@if [ -z "$(PORT)" ]; then \
		echo "Плата не найдена (нет /dev/ttyACM*). Подключи её или укажи PORT=..."; \
		exit 1; \
	fi; \
	WAS_RUNNING=; \
	if systemctl is-active --quiet $(SERVICE) 2>/dev/null; then \
		echo "Останавливаю $(SERVICE) на время прошивки (нужен sudo)"; \
		sudo systemctl stop $(SERVICE) && WAS_RUNNING=1; \
	fi; \
	echo "\"$(CLI)\" upload -p $(PORT) --fqbn $(FQBN) $(SKETCH)"; \
	"$(CLI)" upload -p $(PORT) --fqbn $(FQBN) $(SKETCH); \
	STATUS=$$?; \
	if [ -n "$$WAS_RUNNING" ]; then \
		sudo systemctl start $(SERVICE) && echo "$(SERVICE) запущен обратно"; \
	fi; \
	exit $$STATUS

ports:
	"$(CLI)" board list

clean:
	"$(CLI)" cache clean
	rm -rf $(SKETCH)/build

install-service:
	@python3 -c "import serial" 2>/dev/null || { \
		echo "Нужен pyserial: sudo apt install python3-serial"; exit 1; }
	sudo install -m 755 host/linux/os-switcher-rebootd.py /usr/local/bin/$(SERVICE)
	sudo install -m 644 host/linux/os-switcher-rebootd.service /etc/systemd/system/$(SERVICE).service
	sudo install -m 644 host/linux/99-os-switcher.rules /etc/udev/rules.d/99-os-switcher.rules
	sudo udevadm control --reload-rules
	sudo udevadm trigger --subsystem-match=tty
	sudo systemctl daemon-reload
	sudo systemctl enable --now $(SERVICE)
	@systemctl --no-pager --lines=0 status $(SERVICE) | head -n 3

uninstall-service:
	-sudo systemctl disable --now $(SERVICE)
	sudo rm -f /etc/systemd/system/$(SERVICE).service /usr/local/bin/$(SERVICE) \
		/etc/udev/rules.d/99-os-switcher.rules
	sudo systemctl daemon-reload
	sudo udevadm control --reload-rules

service-logs:
	journalctl -u $(SERVICE) -n 50 --no-pager
