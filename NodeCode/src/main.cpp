#include <Arduino.h>
#include <NimBLEDevice.h>

// GPIO tht enables VBAT measurment divider.
// When high: devider enabled: able to read VBAT through ADC
// When low: divider disabled: saves power
static constexpr int ADC_CTRL_PIN = 37;
// ADC input pin that reads divided batt voltage
static constexpr int VBAT_PIN = 1;

// BLE UUIDs (these must match inside App main)
#define SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define BAT_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"

// Pointers to BLE server & battery characteristics for updates/notifs in loop()
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* batChar = nullptr;

// Read battery voltage using ESP32 divider. Returns VBAT in volts
float readBatteryVoltage() {
  // Enable batt measurement divider so VBAT is connected to ADC through resistor divider
  pinMode(ADC_CTRL_PIN, OUTPUT);
  digitalWrite(ADC_CTRL_PIN, HIGH);
  // Lil delay to let ADC/div settle
  delay(5);
  // Configure ADC resolution to 12 bits
  analogReadResolution(12);
  // Configure attenuation so ADC can measure higher volts
  // ADC_11db extends measureable range (roughly up to 3.3v at ADC pin)
  analogSetPinAttenuation(VBAT_PIN, ADC_11db);
  // Take raw ADC sample
  int raw = analogRead(VBAT_PIN);
  // Convert raw ADC to volts at ADC pin. Per manual specs
  float v_adc = (raw / 4095.0f) * 3.3f;
  float vbat = v_adc * 4.9f; // Board divisor
  // Disable div pin to reduce battery drain
  digitalWrite(ADC_CTRL_PIN, LOW);
  return vbat;
}

//BLE server callbacks. For events like (dis)connect from app
class ServerCallbacks : public NimBLEServerCallbacks {
  // Called when app connects
  void onConnect(NimBLEServer* pServer) override {
    Serial.println("BLE central connected");
  }
  // Called when app disconnects
  void onDisconnect(NimBLEServer* pServer) override {
    Serial.println("BLE central disconnected");
    // Advertising contunies after app disconnects
  }
};

void setup() {
  // Serial monitor for debug
  Serial.begin(115200);
  delay(1000);
  Serial.println("Starting BLE peripheral...");

  // Init NimBLE and set advertised device name
  NimBLEDevice::init("MeshNode-01");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); 
  // Create BLE GATT server and attch connection callbacks
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  // Create services app expects to discover
  NimBLEService* pService = pServer->createService(SERVICE_UUID);

  // create battery characteristics: read (read on demand), notfy (periph can push updates when value changes)
  batChar = pService->createCharacteristic(
    BAT_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // Initial characteristic values.
  //Read VBAT once and change to string
  float v = readBatteryVoltage();
  char buf[16];
  snprintf(buf, sizeof(buf), "%.2f", v);
  // Set characteristics as raw bytes
  batChar->setValue((uint8_t*)buf, strlen(buf));
  // Start service so its avaliable over GATT
  pService->start();

  // Advertising (makes device discoverable by scan)
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  // Include service UUID so scanners can filter by service. App doesnt use it rn but maybe helpful later?
  pAdv->addServiceUUID(SERVICE_UUID);
  // Enable scan responce pkt. Usually to include name or other data (in furture again)
  pAdv->setScanResponse(true);
  pAdv->start();
  Serial.println("BLE advertising started");
}
// timestamping in loop()
unsigned long lastUpdate = 0;

void loop() {
  unsigned long now = millis();
  // periodically update/notfi every 2s
  if (now - lastUpdate > 2000) {
    float v = readBatteryVoltage();
    // Convert to ASCII with 2 decimals
    char buf[16];
    int n = snprintf(buf, sizeof(buf), "%.2f", v);
    //Upate characteristic value
    batChar->setValue((uint8_t*)buf, n);
    // Send notif to any sub app
    // if no app connected, non-op
    batChar->notify(); 
    // Log for degug
    Serial.printf("Updated BAT: %s\n", buf);
    lastUpdate = now;
  }
  // Lil delay to keep loop from looping tooo much
  delay(50);
}
