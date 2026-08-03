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
 *
 * КНОПКА-ПЕРЕКЛЮЧАТЕЛЬ: двухпозиционный выключатель между пином D2 и GND
 * (полярность не важна, внешний резистор не нужен — пин подтянут внутренним
 * pull-up). Включена (замкнута) — нажимаем только Enter (первый пункт меню);
 * выключена (разомкнута) — 4 x "вниз" + Enter (альтернативная ОС).
 * Положение читается в конце 15-секундного мигания, так что переключать
 * можно, пока мигает светодиод.
 *
 * ПЕРЕЗАГРУЗКА ПО ЩЕЛЧКУ: в уже загруженной ОС плата следит за положением
 * выключателя. Если его перещёлкнули и не вернули назад за REBOOT_HOLD_MS
 * (10 с, всё это время RX-светодиод часто мигает), плата шлёт в свой
 * USB-serial строку "REBOOT". По ходу дела она же сообщает хосту "COUNTDOWN 10"
 * и "CANCEL", чтобы тот показал на экране обратный отсчёт с возможностью
 * передумать. Сервис на хосте (host/) эти строки читает и делает
 * штатную перезагрузку — а дальше уже отрабатывает GRUB-логика выше и
 * загружается ОС, соответствующая новому положению выключателя.
 * Сама плата перезагрузить ПК не может: клавиши "reboot" не существует.
 */

#include <HID-Project.h>

// Пин выключателя: второй контакт кнопки — на GND.
const int SWITCH_PIN = 2;

// Пауза после энумерации USB и до нажатий. Энумерация происходит в раннем POST,
// а меню GRUB появляется позже — эту задержку надо подобрать так, чтобы нажатия
// попали в уже показанное меню GRUB, но раньше его таймаута.
const unsigned long INPUT_DELAY_MS = 15000UL;  // 15 секунд

// Период мигания индикаторного светодиода (полупериод), мс.
const unsigned long BLINK_HALF_PERIOD_MS = 500UL;

// Локаут после срабатывания. Когда выбранная ОС начинает грузиться, её ядро
// сбрасывает USB-шину и заново энумерирует клавиатуру — без локаута этот сброс
// перевзводил бы триггер и запускал вторую итерацию уже в загруженной ОС.
// Сбросы шины в течение этого времени после нажатий игнорируются.
// Ядро сбрасывает шину обычно через 5-15 с после Enter в GRUB — 15 с впритык:
// если на этой машине сброс придёт позже, вернётся вторая итерация.
const unsigned long REARM_LOCKOUT_MS = 15000UL;  // 15 секунд

// Сколько держать выключатель в новом положении, чтобы плата попросила хост
// перезагрузиться. Вернул назад раньше — отсчёт отменяется.
const unsigned long REBOOT_HOLD_MS = 10000UL;  // 10 секунд

// Антидребезг выключателя: положение считается новым, только если продержалось
// столько миллисекунд.
const unsigned long DEBOUNCE_MS = 50UL;

// Полупериод мигания во время отсчёта до перезагрузки (частое мигание —
// визуальное отличие от медленного мигания перед нажатиями в GRUB).
const unsigned long COUNTDOWN_BLINK_MS = 100UL;

// Протокол с хостом (по одной строке на событие):
//   "COUNTDOWN <секунды>" — щёлкнули, пошёл отсчёт (хост показывает уведомление
//                           с обратным отсчётом);
//   "CANCEL"              — вернули назад, отбой;
//   "REBOOT"              — время вышло, перезагружайся.
// REBOOT шлём несколько раз: вдруг сервис только что стартовал и не успел
// открыть порт.
const char COUNTDOWN_CMD[] = "COUNTDOWN";
const char CANCEL_CMD[] = "CANCEL";
const char REBOOT_CMD[] = "REBOOT";
const int REBOOT_CMD_REPEATS = 3;
const unsigned long REBOOT_CMD_GAP_MS = 500UL;

// downPresses нажатий "вниз", затем Enter.
void sendKeys(int downPresses) {
  for (int i = 0; i < downPresses; i++) {
    BootKeyboard.write(KEY_DOWN_ARROW);
    delay(30);
  }

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

// Кнопка замкнута на GND = LOW (пин подтянут к HIGH внутренним pull-up).
bool switchIsOn() {
  return digitalRead(SWITCH_PIN) == LOW;
}

void setup() {
  BootKeyboard.begin();

  // CDC-порт для команды "REBOOT" хосту. Ждать открытия порта (while (!Serial))
  // нельзя: без запущенного сервиса скетч встал бы намертво. Пока порт никем
  // не открыт, Serial.println() просто ничего не делает.
  Serial.begin(9600);

  pinMode(SWITCH_PIN, INPUT_PULLUP);

  // На Pro Micro нет светодиода на пине 13 — используем задний RX-светодиод.
  pinMode(LED_BUILTIN_RX, OUTPUT);
  digitalWrite(LED_BUILTIN_RX, HIGH);  // погашен по умолчанию
}

// true = ждём срабатывания на текущее включение хоста; после срабатывания
// сбрасывается в false и снова взводится по сбросу USB-шины (см. loop).
bool armed = true;
bool hasFired = false;          // срабатывали ли хоть раз с подачи питания
unsigned long lastFiredAt = 0;  // millis() на момент последних нажатий

// --- слежение за выключателем в загруженной ОС ---------------------------
bool baselineSwitch = false;         // положение, считающееся "текущим"
bool stableSwitch = false;           // положение после антидребезга
bool lastRawSwitch = false;          // последнее сырое чтение пина
unsigned long lastRawChangeAt = 0;   // когда сырое чтение изменилось
bool countdownActive = false;        // идёт отсчёт до перезагрузки
unsigned long countdownStartedAt = 0;
bool rebootRequested = false;        // команда отправлена, ждём ребута хоста

// Принять текущее положение выключателя за исходное и снять отсчёт. Вызывается
// когда следить не надо или бессмысленно: ПК выключен/спит, идёт выбор в GRUB.
void resetSwitchWatch() {
  bool now = switchIsOn();
  baselineSwitch = now;
  stableSwitch = now;
  lastRawSwitch = now;
  lastRawChangeAt = millis();
  if (countdownActive || rebootRequested) {
    digitalWrite(LED_BUILTIN_RX, HIGH);  // погасить
  }
  if (countdownActive) {
    Serial.println(CANCEL_CMD);  // снять уведомление с отсчётом, если оно висит
  }
  countdownActive = false;
  rebootRequested = false;
}

// Попросить хост перезагрузиться. Строку шлём несколько раз: если сервис на
// хосте только что поднялся, первая может уйти в никуда.
void requestReboot() {
  for (int i = 0; i < REBOOT_CMD_REPEATS; i++) {
    Serial.println(REBOOT_CMD);
    delay(REBOOT_CMD_GAP_MS);
  }
  digitalWrite(LED_BUILTIN_RX, LOW);  // ровно горит = команда ушла
  rebootRequested = true;
  // Если ребута так и не случилось (сервис не запущен), не долбим хост
  // бесконечно: новое положение становится исходным, следующий отсчёт
  // начнётся только со следующего щелчка.
  baselineSwitch = stableSwitch;
}

// Опрос выключателя без блокировок: вызывается из loop() на каждой итерации.
void updateSwitchWatch() {
  bool raw = switchIsOn();
  if (raw != lastRawSwitch) {
    lastRawSwitch = raw;
    lastRawChangeAt = millis();
  } else if (millis() - lastRawChangeAt >= DEBOUNCE_MS) {
    stableSwitch = raw;
  }

  if (rebootRequested) {
    return;  // команда уже ушла, ждём как хост уйдёт в перезагрузку
  }

  if (stableSwitch == baselineSwitch) {
    if (countdownActive) {  // вернули назад — отбой
      countdownActive = false;
      digitalWrite(LED_BUILTIN_RX, HIGH);
      Serial.println(CANCEL_CMD);
    }
    return;
  }

  if (!countdownActive) {
    countdownActive = true;
    countdownStartedAt = millis();
    // Хосту — чтобы показал уведомление с обратным отсчётом. Длительность
    // сообщаем мы: хост не должен знать про REBOOT_HOLD_MS.
    Serial.print(COUNTDOWN_CMD);
    Serial.print(' ');
    Serial.println(REBOOT_HOLD_MS / 1000UL);
  }

  if (millis() - countdownStartedAt >= REBOOT_HOLD_MS) {
    requestReboot();
    return;
  }

  // Частое мигание на всё время отсчёта: "щёлкни обратно, если передумал".
  static unsigned long lastToggleAt = 0;
  static bool ledOn = false;
  if (millis() - lastToggleAt >= COUNTDOWN_BLINK_MS) {
    lastToggleAt = millis();
    ledOn = !ledOn;
    digitalWrite(LED_BUILTIN_RX, ledOn ? LOW : HIGH);
  }
}

void loop() {
  // Сброс USB-шины: включение из выключенного состояния или перезагрузка —
  // в обоих случаях хост сбрасывает шину и энумерирует нас заново. Перевзводим
  // триггер, но не раньше локаута: сброс, который делает ядро ОС при загрузке
  // сразу после наших нажатий, срабатыванием считаться не должен.
  // Suspend сам по себе триггер НЕ перевзводит: при выходе из сна (S3) шина
  // просыпается без сброса, и печатать в рабочий стол нам не надо.
  if (!USBDevice.configured()) {
    if (!hasFired || millis() - lastFiredAt > REARM_LOCKOUT_MS) {
      armed = true;
    }
    // ПК выключается/перезагружается: щелчки выключателя сейчас не считаем,
    // положение на момент включения станет исходным.
    resetSwitchWatch();
    return;
  }

  if (USBDevice.isSuspended()) {
    resetSwitchWatch();  // спит — некому перезагружаться
    return;
  }

  // Хост завершил энумерацию (проснулся один светодиод) и мы ещё не срабатывали
  // на это включение — пора действовать.
  if (armed) {
    armed = false;
    blinkingDelay();
    // Кнопка включена — только Enter (первый пункт меню);
    // выключена — 4 x "вниз" + Enter (альтернативная ОС).
    sendKeys(switchIsOn() ? 0 : 4);
    hasFired = true;
    lastFiredAt = millis();  // локаут отсчитываем от момента нажатий
    // Положение, которым мы только что выбрали пункт меню, — исходное:
    // щелчок во время мигания уже учтён и перезагрузку требовать не должен.
    resetSwitchWatch();
    return;
  }

  // ОС загружена (или грузится) — следим за щелчком выключателя.
  updateSwitchWatch();
}
