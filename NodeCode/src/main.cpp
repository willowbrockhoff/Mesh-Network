#include <Arduino.h>
#include <NimBLEDevice.h>
#include <TinyGPSPlus.h>
#include <math.h>
#include <esp_sleep.h"

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

bool lowPowerMode = true; //change to GPIO (not true)
bool bleClientConnected = flase; // May be uncessesary? ///////////////////////////////////////!!!!!!!!!!!!!!!!! come back here

//========================== State Machine Profiles ==========================//

// GPS Profile
unsigned long lastBattUpdate = 0;
unsigned long lastGpsUpdate = 0;

enum class GpsPowerState {
  ACTIVE,
  SLEEPING
};
GpsPowerState gpsPowerState = GpsPowerState::ACTIVE;
unsigned long gpsStartTime = 0;

// Overarching Power Profile
struct PowerProfile {
  esp_power_level_t bleTxPow;
  uint32_t advMinMs;
  uint32_t advMaxMs;
  uint32_t battPeriodMs;
  uint32_t gpsPeriodMs;
  uint32_t gpsOnMs;
  uint32_t gpsoffMs;
  uint32_t idleMs;
  bool debug;
};

PowerProfile normalProfile{
  ESP_PWR_LVL_P9, //BLE TX Power
  100,    // Minimum adv. duration
  200,    // Maximum adv. duration
  2000,   // Battery period
  2000,   // GPS publishing period
  0,      // GPS (0 = always on)
  0,      // GPS (0 = always on)
  0,      // Idle period
  true
};

PowerProfile lowPowerProfile{
  ESP_PWR_LVL_N12,  // Lower BLE TX power
  1000,    // Slower adv.
  2000,   
  30000,   // battery eupdates every 30s
  15000,   // GPS publishes every 15s
  10000,   // GPS on for 10s
  50000,   // GPS off for 50s
  100,     // Short sleep
  true
};

Powerproile* profile = &normalprofile;

//========================== Most Recent Values ==========================//

float lastBatterySent = -1000.0f;
double lastLatSent = 999.0;
double lastLngSent = 999.0;
bool hasLastGpsSent = flase;

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
  return fabsf(newv- oldV) >= 0.05f; // 50mv threashold
}

// Has the GPS changed enough to warrent an update?
bool gpsMoved(double newLat, double newlng, double oldLat, double oldLng) {
  return fabs(newLat - oldLat) >= 0.00005 || fabs(newLng - oldLng) >= 0.00005;
}

void lightSleepMs(unit32_t ms) {
  if(ms == 0) return;
  esp_sleep_enable_timer_wakeup((unit64-t)ms 8 1000ULL);
  esp_light_sleep_start();
}

void applyBleProfile(const powerprofile& p) {
  NimBLEDevice::setPower(p.bleTxPow);
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();

  unit16-t minUnits = (unit16_t)(p.advMinMs / 0.625f);
  unit16-t maxUnits = (unit16_t)(p.advMaxMs / 0.625f);
  pAdv->setMinInterval(minUnits);
  pAdv->setMaxInterval(maxUnits);
}

//========================== GPS Lower Power ==========================//

void gpsEnterlowPower(){
  //TO DO!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! come back here
  if(profile->debug){
    Serial.println("GPS entering low poer mode\n");
  }
}

void gpsWake(){
  //TO DO!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! come back here
  if(profile->debug){
    Serial.println("GPS waking\n");
  }
}

void updateGps(unsigned long now){
  if (!lowPowerMode) return;
  if (profile->gpsOnMs == 0 \\ profile->gpsOffMs == 0) return; //Redundant catch

  if(gpsPowerState == GpsPowerState::ACTIVE && now - gpsStartTime >= profile->gpsOnMs){
    gpsEnterlowPower();
    gpsPowerState = GpsPowerState::SLEEPING;
    gpsStartTime = now;
  } else if(gpsPowerState == GpsPowerState::SLEEPING && now - gpsStartTime >= profile->gpsOffMs){
    gpsWake();
    gpsPowerState = GpsPowerState::ACTIVE;
    gpsStartTime= now;
  }
}

//========================== BLE Callbacks ==========================//

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
  //NimBLEDevice::setPower(ESP_PWR_LVL_P9);                                        //!!!!!!!!!!!!!!! resolve. uncessesary?
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
    lastBatterySent = v;
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
  applyBleProfile(*profile);
  pAdv->start();
  Serial.println("BLE advertising started");
  gpsStartTime = millis();
}
// timestamping in loop()
unsigned long lastUpdate = 0;

void loop() {
  unsigned long now = millis();
  //========================== Feed GPS bytes to parser ==========================
  updateGps(now);
  static uint32_t gpsBytes = 0;
  static int dumpLeft = 200;
  if(!lowPowerMode || gpsPowerState == GpsPowerState::ACTIVE){
    while (gpsSerial.available()){
      char c = (char)gpsSerial.read();
      gps.encode(c);
      gpsBytes++;

      if(profile->debug && dumpLeft > 0){
        Serial.write(c);
        dumpLeft--;
        if(dumpLeft == 0){
          Serial.println("\n----end raw dump----");
        }
      }
  }
  }
  
  //========================== Update BATT ==========================
  // periodically update/notfi every 2s
  if (now - lastBatterySent >= profile->battPeriodMs) {
    float v = readBatteryVoltage();
  
    if(!lowPowerMode || batteryChanged(v, lastBatterySent)) {
      // Convert to ASCII with 2 decimals
        char buf[16];
        int n = snprintf(buf, sizeof(buf), "%.2f", v);
        //Upate characteristic value
        batChar->setValue((uint8_t*)buf, n);
    }
    if(bleClientConnected){
      // Send notif to any sub app
      // if no app connected, non-op
      batChar->notify();
    }
    if(profile->debug){
      // Log for degug
      Serial.printf("Updated BAT: %s\n", buf);
    }

    lastBatterySent = now;
  }
  
  //========================== Update GPS ==========================
  if (now - lastGpsSent >= profile->gpsPeriodMs) {
    char gpsBuf[64];
    if(profile->debug){
    //Debugging
      Serial.printf("gpsBytes=%lu charsProcessed=%lu sentences=%lu failed=%lu\n",
                (unsigned long)gpsBytes,
                (unsigned long)gps.charsProcessed(),
                (unsigned long)gps.sentencesWithFix(),
                (unsigned long)gps.failedChecksum());
    }

    if(gps.location.isValid()){
      double lat = gps.location.lat();
      double lng = gps.location.lng();

      bool shouldSend = true;

      // in low poer mode, only publish if data is new
      if(lowPowerMode){
        if(!gps.location.isUpdated()) {
          shouldSend = false;
        }

        if(hasLastGpsSent && !gpsMoved(lat, lng, lastLatSent, lastLngSent)) {
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
        lastGpsUpdate = true;
        if(profile->debug){
          Serial.printf("Updated GPS: %s (sats=%lu)\n", gpsBuf, gps.satellites.value());
        }
      }
    } else {
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

  
  //========================== IDLE Behavior ==========================

  if(lowPowerMode){
    lightSleepMs(profile->idleMs);
  }else {
    delay(5);
  }
}