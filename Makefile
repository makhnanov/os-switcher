# os-switcher — сборка и прошивка через arduino-cli.
#
# Цели:
#   make            — собрать и прошить (то же, что make flash)
#   make build      — только собрать скетч
#   make flash      — собрать и прошить (порт определяется автоматически,
#                     можно задать вручную: make flash PORT=/dev/ttyACM0)
#   make ports      — показать подключённые платы
#   make clean      — удалить артефакты сборки

CLI    ?= /opt/arduino-ide/resources/app/lib/backend/resources/arduino-cli
FQBN   ?= arduino:avr:leonardo
SKETCH ?= os-switcher-sketch
PORT   ?= $(firstword $(wildcard /dev/ttyACM*))

.PHONY: all build flash ports clean

all: flash

build:
	"$(CLI)" compile --fqbn $(FQBN) $(SKETCH)

flash: build
	@if [ -z "$(PORT)" ]; then \
		echo "Плата не найдена (нет /dev/ttyACM*). Подключи её или укажи PORT=..."; \
		exit 1; \
	fi
	"$(CLI)" upload -p $(PORT) --fqbn $(FQBN) $(SKETCH)

ports:
	"$(CLI)" board list

clean:
	"$(CLI)" cache clean
	rm -rf $(SKETCH)/build
