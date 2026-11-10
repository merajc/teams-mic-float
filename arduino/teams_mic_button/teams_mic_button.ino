// Teams Mic Button & MAX7219 LED Matrix Display for Arduino Uno
// Communicates with TeamsMicFloat on macOS via USB Serial (115200 baud)

// --- Pin Definitions ---
const int BUTTON_PIN = 2;   // External push button input (Pin 2 with INPUT_PULLUP)
const int LED_PIN    = 13;  // Built-in LED on Pin 13

// MAX7219 8x8 LED Matrix Pins
const int DIN_PIN = 8;      // Green -> Pin 8
const int CS_PIN  = 9;      // Yellow -> Pin 9
const int CLK_PIN = 10;     // Orange -> Pin 10

// --- MAX7219 Register Addresses ---
const byte MAX7219_REG_NOOP        = 0x00;
const byte MAX7219_REG_DIGIT0      = 0x01;
const byte MAX7219_REG_DECODEMODE  = 0x09;
const byte MAX7219_REG_INTENSITY   = 0x0A;
const byte MAX7219_REG_SCANLIMIT   = 0x0B;
const byte MAX7219_REG_SHUTDOWN    = 0x0C;
const byte MAX7219_REG_DISPLAYTEST = 0x0F;

// --- Theme Selection ---
// 1 = Theme 1: Retro Microphone (Live) vs Slashed Microphone (Muted)
// 2 = Theme 2: Status Letters ("ON" vs "M")
// 3 = Theme 3: Checkmark (Live) vs Giant "X" (Muted) [ACTIVE]
#define THEME_SELECTION 3

// --- Bitmaps (8x8) ---
#if THEME_SELECTION == 1
// Theme 1: Retro Microphone (Live) vs Slashed Microphone (Muted)
const byte BITMAP_UNMUTED[8] = {
  B00111100, // . . ■ ■ ■ ■ . .  (mic top)
  B00100100, // . . ■ . . ■ . .  (grill)
  B00111100, // . . ■ ■ ■ ■ . .  (mic body)
  B01011010, // . ■ . ■ ■ . ■ .  (stand cradle)
  B01000010, // . ■ . . . . ■ .  (cradle arms)
  B00111100, // . . ■ ■ ■ ■ . .  (cradle base)
  B00011000, // . . . ■ ■ . . .  (stem)
  B01111110  // . ■ ■ ■ ■ ■ ■ .  (desk stand)
};

const byte BITMAP_MUTED[8] = {
  B10111100, // ■ . ■ ■ ■ ■ . .  (slash start)
  B01100100, // . ■ ■ . . ■ . .  (\)
  B00111100, // . . ■ ■ ■ ■ . .   (\)
  B01011010, // . ■ . ■ ■ . ■ .    (\)
  B01001010, // . ■ . . ■ . ■ .     (\)
  B00111100, // . . ■ ■ ■ ■ . .      (\)
  B00011010, // . . . ■ ■ . ■ .       (\)
  B01111111  // . ■ ■ ■ ■ ■ ■ ■  (slash end)
};

#elif THEME_SELECTION == 2
// Theme 2: "ON" vs "M"
const byte BITMAP_UNMUTED[8] = {
  B01101001, // . ■ ■ . ■ . . ■
  B10011101, // ■ . . ■ ■ ■ . ■
  B10011011, // ■ . . ■ ■ . ■ ■
  B10011011, // ■ . . ■ ■ . ■ ■
  B10011001, // ■ . . ■ ■ . . ■
  B01101001, // . ■ ■ . ■ . . ■
  B00000000, // . . . . . . . .
  B00000000  // . . . . . . . .
};

const byte BITMAP_MUTED[8] = {
  B10000001, // ■ . . . . . . ■
  B11000011, // ■ ■ . . . . ■ ■
  B10100101, // ■ . ■ . . ■ . ■
  B10011001, // ■ . . ■ ■ . . ■
  B10000001, // ■ . . . . . . ■
  B10000001, // ■ . . . . . . ■
  B10000001, // ■ . . . . . . ■
  B00000000  // . . . . . . . .
};

#else
// Theme 3: Checkmark (Live) vs Giant "X" (Muted)
const byte BITMAP_UNMUTED[8] = {
  B00000001, // . . . . . . . ■
  B00000011, // . . . . . . ■ ■
  B00000110, // . . . . . ■ ■ .
  B10001100, // ■ . . . ■ ■ . .
  B11011000, // ■ ■ . ■ ■ . . .
  B01110000, // . ■ ■ ■ . . . .
  B00100000, // . . ■ . . . . .
  B00000000  // . . . . . . . .
};

const byte BITMAP_MUTED[8] = {
  B11000011, // ■ ■ . . . . ■ ■
  B01100110, // . ■ ■ . . ■ ■ .
  B00111100, // . . ■ ■ ■ ■ . .
  B00011000, // . . . ■ ■ . . .
  B00011000, // . . . ■ ■ . . .
  B00111100, // . . ■ ■ ■ ■ . .
  B01100110, // . ■ ■ . . ■ ■ .
  B11000011  // ■ ■ . . . . ■ ■
};
#endif

// Idle / Offline: subtle 2x2 standby dot in the center
const byte BITMAP_IDLE[8] = {
  B00000000,
  B00000000,
  B00000000,
  B00011000,
  B00011000,
  B00000000,
  B00000000,
  B00000000
};

// --- Low-Level MAX7219 Functions ---
void maxTransfer(byte address, byte data) {
  digitalWrite(CS_PIN, LOW);
  shiftOut(DIN_PIN, CLK_PIN, MSBFIRST, address);
  shiftOut(DIN_PIN, CLK_PIN, MSBFIRST, data);
  digitalWrite(CS_PIN, HIGH);
}

void displayBitmap(const byte bitmap[8]) {
  for (int row = 0; row < 8; row++) {
    maxTransfer(row + 1, bitmap[row]);
  }
}

void clearMatrix() {
  for (int row = 1; row <= 8; row++) {
    maxTransfer(row, 0x00);
  }
}

void initMatrix() {
  pinMode(DIN_PIN, OUTPUT);
  pinMode(CLK_PIN, OUTPUT);
  pinMode(CS_PIN, OUTPUT);
  digitalWrite(CS_PIN, HIGH);

  maxTransfer(MAX7219_REG_DISPLAYTEST, 0x00); // Normal operation (no test)
  maxTransfer(MAX7219_REG_DECODEMODE,  0x00); // No decode for LED matrix
  maxTransfer(MAX7219_REG_SCANLIMIT,   0x07); // Display all 8 rows
  maxTransfer(MAX7219_REG_INTENSITY,   0x04); // Brightness: 0x00 (dim) to 0x0F (max)
  maxTransfer(MAX7219_REG_SHUTDOWN,    0x01); // Wake up from shutdown

  displayBitmap(BITMAP_IDLE);
}

// --- Ground Sink Pins ---
// Pins 3, 4, and 5 are driven LOW so that a button wired between Pin 2 and ANY adjacent pin
// (including Pin 5, Pin 4, or regular GND) immediately works with zero fuss.
const int GND_SINK_PINS[] = {3, 4, 5};
const int NUM_GND_SINKS = 3;

// --- Button Debouncing State ---
int lastButtonReading = HIGH;
unsigned long lastToggleTime = 0;
const unsigned long BUTTON_LOCKOUT_MS = 250; // Prevents contact bounce (<1ms instant response)

// --- Non-Blocking Serial Buffer & State ---
String serialBuffer = "";
bool isMuted = false;

void handleCommand(const String& cmd) {
  if (cmd == "MUTED") {
    isMuted = true;
    digitalWrite(LED_PIN, HIGH);
    displayBitmap(BITMAP_MUTED);
  } else if (cmd == "UNMUTED") {
    isMuted = false;
    digitalWrite(LED_PIN, LOW);
    displayBitmap(BITMAP_UNMUTED);
  } else if (cmd == "OFF" || cmd == "IDLE") {
    isMuted = false;
    digitalWrite(LED_PIN, LOW);
    displayBitmap(BITMAP_IDLE);
  } else if (cmd == "PING") {
    Serial.println("PONG");
  }
}

void setup() {
  Serial.begin(115200);

  // Configure Pins 3, 4, and 5 as ground sinks (LOW)
  for (int i = 0; i < NUM_GND_SINKS; i++) {
    pinMode(GND_SINK_PINS[i], OUTPUT);
    digitalWrite(GND_SINK_PINS[i], LOW);
  }

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  initMatrix();

  // Announce boot and notify host (also covers onboard RESET button clicks)
  Serial.println("V1 READY app=teams-mic-button display=max7219");
  Serial.println("TOGGLE");
}

void loop() {
  // 1. Instant Edge-Triggered Button Sensing (<1ms response, 250ms lockout)
  int reading = digitalRead(BUTTON_PIN);
  unsigned long now = millis();

  if (reading == LOW && lastButtonReading == HIGH && (now - lastToggleTime > BUTTON_LOCKOUT_MS)) {
    lastToggleTime = now;
    digitalWrite(LED_PIN, HIGH); // Visual feedback on click
    Serial.println("TOGGLE");
  } else if (reading == HIGH && lastButtonReading == LOW) {
    // Restore LED state to mute status once button is released
    digitalWrite(LED_PIN, isMuted ? HIGH : LOW);
  }
  lastButtonReading = reading;

  // 2. Non-blocking Serial Command Processing (never stalls button loop)
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n') {
      serialBuffer.trim();
      if (serialBuffer.length() > 0) {
        handleCommand(serialBuffer);
      }
      serialBuffer = "";
    } else if (c != '\r') {
      serialBuffer += c;
    }
  }
}
