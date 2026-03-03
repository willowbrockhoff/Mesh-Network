#include <Arduino.h>
#include <NimBLEDevice.h>
#include <TinyGPSPlus.h>

//==========================Battery Pins==========================//
// GPIO tht enables VBAT measurment divider.
// When high: devider enabled: able to read VBAT through ADC
// When low: divider disabled: saves power
static constexpr int ADC_CTRL_PIN = 37;
// ADC input pin that reads divided batt voltage
static constexpr int VBAT_PIN = 1;

//==========================GPS UART Pins==========================//
static constexpr int GPS_RX = 47; // 47 is ESP32 TX
static constexpr int GPS_TX = 48; // 48 is ESP32 RX
static constexpr uint32_t GPS_BAUD = 9600;  // bits per second at which GPS TX data

TinyGPSPlus gps;
HardwareSerial gpsSerial(1);

//========================== BLE UUIDs ==========================//
#define SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define BAT_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"
#define GPS_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef2"

// Pointers to BLE server & battery/gps characteristics for updates/notifs in loop()
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* batChar = nullptr;
NimBLECharacteristic* gpsChar = nullptr;

// Read battery voltage using ESP32 divider. Returns VBAT in volts
float readBatteryVoltage() {
  
  // Enable batt measurement divider so VBAT is connected to ADC through resistor divider
  pinMode(ADC_CTRL_PIN, OUTPUT);
  digitalWrite(ADC_CTRL_PIN, HIGH);
  delay(5);   // Lil delay to let ADC/div settle
  analogReadResolution(12);   // Configure ADC resolution to 12 bits
  
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

  //Start GPS UART
  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX, GPS_TX);
  Serial.printf("GPS UART started. RX=%d  TX=%d @ %lu\n", GPS_RX, GPS_TX, (unsigned long)GPS_BAUD);

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

  //create GPS characteristics
  gpsChar = pService->createCharacteristic(
    GPS_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // Initial characteristic values.
  //Initial VBAT
  {
    float v = readBatteryVoltage();
    char buf[16];
    snprintf(buf, sizeof(buf), "%.2f", v);
    // Set characteristics as raw bytes
    batChar->setValue((uint8_t*)buf, strlen(buf));
    }
  // Initial GPS value
  {
    const char* init = "NOFIX";
    gpsChar->setValue((uint8_t*)init, strlen(init));
  }
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
  //========================== Feed GPS bytes to parser ==========================
  static uint32_t gpsBytes = 0;
  static int dumpLeft = 200;
  while (gpsSerial.available()){
    char c = (char)gpsSerial.read();
    gps.encode(c);
    gpsBytes++;

    if(dumpLeft > 0){
      Serial.write(c);
      dumpLeft--;
      if(dumpLeft == 0){
        Serial.println("\n----end raw dump----");
      }
    }
  }
  //========================== Update BAT & GPS every 2s ==========================
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

    char gpsBuf[64];

    //Debugging
    Serial.printf("gpsBytes=%lu charsProcessed=%lu sentences=%lu failed=%lu\n",
              (unsigned long)gpsBytes,
              (unsigned long)gps.charsProcessed(),
              (unsigned long)gps.sentencesWithFix(),
              (unsigned long)gps.failedChecksum());

    
    if(gps.location.isValid()){ //could use gps.location.isUpdated() later for low power?
      int gn = snprintf(gpsBuf, sizeof(gpsBuf), "%.6f,%.6f", gps.location.lat(), gps.location.lng());
      gpsChar->setValue((uint8_t*)gpsBuf, gn);
      gpsChar->notify();
      Serial.printf("Updated GPS: %s (sats=%lu)\n", gpsBuf, gps.satellites.value());
    }else{
      const char* nofix = "NOFIX";
      gpsChar->setValue((uint8_t*)nofix, strlen(nofix));
      gpsChar->notify();
      Serial.println("Updated GPS: NOFIX");
    }


    lastUpdate = now;
  }
  // Lil delay to keep loop from looping tooo much
  //delay(5);
}
