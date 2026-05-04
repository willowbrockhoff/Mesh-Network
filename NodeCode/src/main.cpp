#include <Arduino.h>
#include <NimBLEDevice.h>
#include <TinyGPSPlus.h>
#include <math.h>
#include <esp_sleep.h>

//==========================Battery Pins==========================//
// GPIO that enables VBAT measurment divider.
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
#define DISABLE_GPS false // True disables GPS usage on nodes

//========================== BLE UUIDs ==========================//
#define SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define BAT_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"
#define GPS_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef2"
#define MODE_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef3"

// Pointers to BLE server & battery/gps characteristics for updates/notifs in loop()
NimBLEServer* pServer = nullptr;
NimBLECharacteristic* batChar = nullptr;
NimBLECharacteristic* gpsChar = nullptr;
NimBLECharacteristic* modeChar = nullptr;

bool lowPowerMode = false;
bool sosMode = false;
bool bleClientConnected = false; 

// Chico test coordinates for debugging
static constexpr double FIXED_LAT = 39.73248;
static constexpr double FIXED_LNG = -121.84437;

// Recent value holders
unsigned long lastBattUpdate = 0;
unsigned long lastGpsUpdate = 0;
unsigned long gpsStartTime = 0;
float lastBatterySent = -1000.0f;
double lastLatSent = 999.0;
double lastLngSent = 999.0;
bool lastGpsSent = false;
unsigned long lastUpdate = 0; // timestamping in loop()

//========================== Power Profiles ==========================//

enum class NodeMode {
  NORMAL,
  LOW_POWER,
  SOS
};
NodeMode nodeMode = NodeMode::NORMAL;

// Overarching Power Profile
struct PowerProfile {
  esp_power_level_t bleTxPow;
  uint32_t advMinMs;          // Minimum adv. duration
  uint32_t advMaxMs;          // Maximum adv. duration
  uint32_t battPeriodMs;      // Battery period
  uint32_t gpsPeriodMs;       // GPS publishing period
  uint32_t gpsOnMs;           // GPS wake period
  uint32_t gpsOffMs;          // GPS sleep persiod
  uint32_t idleMs;            // Idle period
  bool debug;
};

PowerProfile normalProfile{
  ESP_PWR_LVL_P9, //BLE TX Power
  100,    
  200,    
  2000,   
  2000,   
  0,      // GPS (0 = always on)
  0,      // GPS (0 = always on)
  0,      
  true
};
PowerProfile* profile = &normalProfile;

PowerProfile lowPowerProfile{
  ESP_PWR_LVL_N0,  // Lower BLE TX power
  250,    // Slower adv.
  500,   
  30000,   // battery eupdates every 30s
  15000,   // GPS publishes every 15s
  10000,   // GPS on for 10s
  50000,   // GPS off for 50s
  0,    
  true
};

void applyBleProfile(const PowerProfile& p) {
  NimBLEDevice::setPower(p.bleTxPow);
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();

  uint16_t minUnits = (uint16_t)(p.advMinMs / 0.625f);
  uint16_t maxUnits = (uint16_t)(p.advMaxMs / 0.625f);
  pAdv->setMinInterval(minUnits);
  pAdv->setMaxInterval(maxUnits);
}

const char* currentModeText() {
  if (sosMode) return "SOS";
  if (lowPowerMode) return "LOW_POWER";
  return "NORMAL";
}

void applyBleProfile(const PowerProfile& p);//////////////////////////////////////////////////////////////////////////////////////

// Update node's mode when prompted, advertising node, update log
void applyMode(const char* mode) {
  if (strcmp(mode, "LOW_POWER") == 0) {
    lowPowerMode = true;
    sosMode = false;
    profile = &lowPowerProfile;
  } else if (strcmp(mode, "SOS") == 0) {
    lowPowerMode = false;
    sosMode = true;
    profile = &normalProfile;
  } else {
    lowPowerMode = false;
    sosMode = false;
    profile = &normalProfile;
  }
  
  applyBleProfile(*profile);
  // Begin advertising
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();

  // If node disconects, begin advertising again
  if (!bleClientConnected) {
    adv->start();
  }

  const char* txt = currentModeText();
  modeChar->setValue((uint8_t*)txt, strlen(txt));
  modeChar->notify();

  Serial.printf("Mode changed to: %s\n", txt);
}


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

//========================== Helpers ==========================//
// Has the battery changed enough to warrent an update?
bool batteryChanged(float newV, float oldV) {
  return fabsf(newV - oldV) >= 0.05f; // 50mv threashold
}

// Has the GPS changed enough to warrent an update?
bool gpsMoved(double newLat, double newLng, double oldLat, double oldLng) {
  return fabs(newLat - oldLat) >= 0.00005 || fabs(newLng - oldLng) >= 0.00005;
}

void lightSleepMs(uint32_t ms) {
  if(ms == 0) return;
  esp_sleep_enable_timer_wakeup((uint64_t)ms * 1000ULL);
  esp_light_sleep_start();
}

//========================== BLE Callbacks ==========================//

//BLE server callbacks. For events like (dis)connect from app
class ServerCallbacks : public NimBLEServerCallbacks {
  // Called when app connects
  void onConnect(NimBLEServer* pServer) override {
    bleClientConnected = true;
    Serial.println("BLE central connected");
  }
  // Called when app disconnects
  void onDisconnect(NimBLEServer* pServer) override {
    bleClientConnected = false;
    Serial.println("BLE central disconnected");
    NimBLEDevice::getAdvertising()->start();
    // Advertising continues after app disconnects
  }
};

// new modeCallbacks created when mode updates
class ModeCallbacks : public NimBLECharacteristicCallbacks {
  
  void onWrite(NimBLECharacteristic* pCharacteristic) override {
    std::string value = pCharacteristic->getValue();
    if (value == "LOW_POWER") {
      applyMode("LOW_POWER");
    } else if (value == "SOS") {
      applyMode("SOS");
    } else if (value == "NORMAL") {
      applyMode("NORMAL");
    } else {
      Serial.printf("Unknown mode write: %s\n", value.c_str());
    }
  }

};


void setup() {
  
  // Serial monitor for debug
  Serial.begin(115200);
  delay(1000);

  Serial.println("Starting BLE peripheral...");
  
  #if !DISABLE_GPS
  //Start GPS UART
  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX, GPS_TX);
  Serial.printf("GPS UART started. RX=%d  TX=%d @ %lu\n", GPS_RX, GPS_TX, (unsigned long)GPS_BAUD);
  #else
    Serial.println("GPS disabled on this node");
  #endif

  //========================== Characteristics ==========================//

  // Init NimBLE and set advertised device name
  NimBLEDevice::init("WilderMesh Node-01");

  // Create BLE GATT server and attach connection callbacks
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  // Create services app expects to discover
  NimBLEService* pService = pServer->createService(SERVICE_UUID);

  // Create battery characteristics: read (read on demand), notify (periph. can push updates when value changes)
  batChar = pService->createCharacteristic(
    BAT_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // Create GPS characteristics
  gpsChar = pService->createCharacteristic(
    GPS_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  modeChar = pService->createCharacteristic(
    MODE_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::WRITE
  );
  modeChar->setCallbacks(new ModeCallbacks());
  

  //Initial VBAT
  {
    float v = readBatteryVoltage();
    char buf[16];
    snprintf(buf, sizeof(buf), "%.2f", v);
    // Set characteristics as raw bytes
    batChar->setValue((uint8_t*)buf, strlen(buf));
    lastBatterySent = v;
    }

  {
  #if DISABLE_GPS
    const char* init = "DISABLED";
    gpsChar->setValue((uint8_t*)init, strlen(init));
  #else
    const char* init = "NOFIX"; // Value when GPS fails to lock position
    gpsChar->setValue((uint8_t*)init, strlen(init));
  #endif
  }

  //Initial mode value
  {
    const char* initMode = currentModeText();
    modeChar->setValue((uint8_t*)initMode, strlen(initMode));
  }

  // Start service so its avaliable over GATT
  pService->start();

  // Advertising, makes device discoverable by scan
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  // Include service UUID so scanners can filter by service. App doesnt use it rn but maybe helpful later?
  pAdv->addServiceUUID(SERVICE_UUID);
  // Enable scan responce pkt. Usually to include name or other data (in furture again)
  pAdv->setScanResponse(true);
  applyBleProfile(*profile);
  pAdv->start();
  Serial.println("BLE advertising started");
  gpsStartTime = millis();

}

void loop() {
  unsigned long now = millis();

  //========================== Feed GPS bytes to parser ==========================
  static uint32_t gpsBytes = 0;
  static int dumpLeft = 200;
  #if !DISABLE_GPS
  if(!lowPowerMode){
    while (gpsSerial.available()){
      char c = (char)gpsSerial.read();
      gps.encode(c);
      gpsBytes++;
    }
  }
  #endif
  
  //========================== Update BATT ==========================

  char buf[16];
  if (now - lastBattUpdate >= profile->battPeriodMs) {
    float v = readBatteryVoltage();
  
    if(!lowPowerMode || batteryChanged(v, lastBatterySent)) {  
        int n = snprintf(buf, sizeof(buf), "%.2f", v);  // Convert to ASCII with 2 decimals   
        batChar->setValue((uint8_t*)buf, n); //Upate characteristic value
    }
    if(bleClientConnected){
      // Send notif to any sub app. If no app connected, non-op
      batChar->notify();
    }
    if(profile->debug){
      Serial.printf("Updated BAT: %s\n", buf);
    }
    lastBattUpdate = now;
  }
  
  //========================== Update GPS ==========================
  #if !DISABLE_GPS
  if (now - lastGpsUpdate >= profile->gpsPeriodMs) {
    char gpsBuf[64];

    if(gps.location.isValid()){
      double lat = gps.location.lat();
      double lng = gps.location.lng();

      bool shouldSend = true;

      // In low power mode, only publish if data is new
      if(lowPowerMode){
        if(!gps.location.isUpdated()) {
          shouldSend = false;
        }
        // Don't send if data isn't new
        if(lastGpsSent && !gpsMoved(lat, lng, lastLatSent, lastLngSent)) {
          shouldSend = false;
        }
      }
      if(shouldSend){
        int gn = snprintf(gpsBuf, sizeof(gpsBuf), "%.6f,%.6f", gps.location.lat(), gps.location.lng());
        gpsChar->setValue((uint8_t*)gpsBuf, gn);
        if(bleClientConnected){
        gpsChar->notify();
        }
        lastLatSent = lat;
        lastLngSent = lng;
        if(profile->debug){
          Serial.printf("Updated GPS: %s (sats=%lu)\n", gpsBuf, gps.satellites.value());
        }
      }
    } else {
      // If GPS location is invalid
      const char* nofix = "NOFIX";
      gpsChar->setValue((uint8_t*)nofix, strlen(nofix));
      if(bleClientConnected){
        gpsChar->notify();
      }
      if(profile->debug){
        Serial.println("Updated GPS: NOFIX");
      }
    }
    lastGpsUpdate = now;
  }
  #endif
  
  static const char* lastModeSent = "";
  const char* modeText = currentModeText();

  if (strcmp(modeText, lastModeSent) != 0) {
    modeChar->setValue((uint8_t*)modeText, strlen(modeText));
    if (bleClientConnected) {
      modeChar->notify();
    }
    lastModeSent = modeText;
  }

 //========================== IDLE Behavior ==========================
  if (!sosMode && lowPowerMode && !bleClientConnected) {
    lightSleepMs(profile->idleMs);
  } else {
    delay(5);
  }
}