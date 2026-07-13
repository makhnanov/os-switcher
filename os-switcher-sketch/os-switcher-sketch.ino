/*
 * os-switcher-sketch
 *
 * Аппаратный автовыбиратель пункта в меню GRUB. Плата (Pro Micro, ATmega32u4)
 * прикидывается USB-клавиатурой и в нужный момент сама нажимает "вниз" 4 раза
 * и Enter.
 *
 * ТРИГГЕР: срабатывание привязано не к подаче питания (на современных ПК USB
 * питается всегда, даже при выключенном компьютере), а к ПРОБУЖДЕНИЮ USB-хоста.
 * Мы ждём USBDevice.configured() — момент, когда хост завершил энумерацию нашей
 * клавиатуры (то же событие, из-за которого на Pro Micro "просыпается" один
 * задний светодиод). После USBDevice.isSuspended() (ПК выключился/уснул) триггер
 * взводится заново, поэтому скетч отрабатывает на КАЖДОЕ включение/перезагрузку.
 *
 * Работает в BIOS/UEFI/GRUB: используется BootKeyboard из библиотеки HID-Project
 * (HID boot-protocol), который понимает хост ещё до загрузки ОС.
 *
 * Индикация: задний RX-светодиод Pro Micro (пин 17, инвертированный: LOW = горит).
 */

#include <HID-Project.h>

// Пауза после энумерации USB и до нажатий. Энумерация происходит в раннем POST,
// а меню GRUB появляется позже — эту задержку надо подобрать так, чтобы нажатия
// попали в уже показанное меню GRUB, но раньше его таймаута.
const unsigned long INPUT_DELAY_MS = 60000UL;  // 60 секунд

// Период мигания индикаторного светодиода (полупериод), мс.
const unsigned long BLINK_HALF_PERIOD_MS = 500UL;

void sendKeys() {
  // 4 нажатия клавиши "вниз"
  for (int i = 0; i < 4; i++) {
    BootKeyboard.write(KEY_DOWN_ARROW);
    delay(30);
  }

  // В конце — Enter
  BootKeyboard.write(KEY_ENTER);
}

// Ждём INPUT_DELAY_MS, всё это время моргаем RX-светодиодом.
void blinkingDelay() {
  unsigned long start = millis();
  bool on = true;
  while (millis() - start < INPUT_DELAY_MS) {
    digitalWrite(LED_BUILTIN_RX, on ? LOW : HIGH);  // LOW = горит
    on = !on;
    delay(BLINK_HALF_PERIOD_MS);
  }
  digitalWrite(LED_BUILTIN_RX, HIGH);  // выключить
}

void setup() {
  BootKeyboard.begin();

  // На Pro Micro нет светодиода на пине 13 — используем задний RX-светодиод.
  pinMode(LED_BUILTIN_RX, OUTPUT);
  digitalWrite(LED_BUILTIN_RX, HIGH);  // погашен по умолчанию
}

// true = ждём срабатывания на текущее включение хоста; после срабатывания
// сбрасывается в false и снова взводится, когда хост уйдёт в suspend.
bool armed = true;

void loop() {
  // Хост не сконфигурирован: ПК выключен/уснул (suspend) ИЛИ идёт сброс шины
  // при перезагрузке. Взводим триггер заново для следующего включения.
  if (!USBDevice.configured() || USBDevice.isSuspended()) {
    armed = true;
    return;
  }

  // Хост завершил энумерацию (проснулся один светодиод) и мы ещё не срабатывали
  // на это включение — пора действовать.
  if (armed) {
    armed = false;
    blinkingDelay();
    sendKeys();
  }
}
