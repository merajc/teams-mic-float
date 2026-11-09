// Teams Mic Button for Arduino Uno
// Communicates with TeamsMicFloat on macOS via USB Serial (115200 baud)

const int BUTTON_PIN = 2;       // Optional external button (wired between Pin 2 and GND)
const int LED_PIN = 13;         // Built-in LED on Pin 13

// Button debounce tracking for external button
int lastButtonReading = HIGH;
int buttonState = HIGH;
unsigned long lastDebounceTime = 0;
const unsigned long DEBOUNCE_DELAY = 50; // ms

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // Send boot banner and notify the host that button/reset was triggered
  Serial.println("V1 READY app=teams-mic-button");
  Serial.println("TOGGLE");
}

void loop() {
  // 1. Check external button on Pin 2 (if present)
  int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonReading) {
    lastDebounceTime = millis();
  }

  if ((millis() - lastDebounceTime) > DEBOUNCE_DELAY) {
    if (reading != buttonState) {
      buttonState = reading;
      // Button pressed (active LOW with pullup)
      if (buttonState == LOW) {
        Serial.println("TOGGLE");
      }
    }
  }
  lastButtonReading = reading;

  // 2. Read incoming state updates from TeamsMicFloat
  if (Serial.available() > 0) {
    String line = Serial.readStringUntil('\n');
    line.trim();

    if (line == "MUTED") {
      digitalWrite(LED_PIN, HIGH); // LED ON when muted
    } else if (line == "UNMUTED") {
      digitalWrite(LED_PIN, LOW);  // LED OFF when live
    } else if (line == "PING") {
      Serial.println("PONG");
    }
  }
}

