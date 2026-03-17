#include <Arduino.h>
#include <WiFi.h>
#include <NTPClient.h>
#include <WiFiUdp.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BluetoothA2DP.h>
#include <SPIFFS.h>
#include <FS.h>
#include <Wire.h>
#include <Adafruit_DRV2605.h>
#include <driver/i2s.h>
#include <esp_gap_bt_api.h>
#include <esp_gap_ble_api.h>
#include <esp_system.h>
#include <math.h>

// --- BLE UUIDs (match app contract) ---
#define SERVICE_UUID               "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define ALARM_CHARACTERISTIC_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define INTENSITY_CHAR_UUID        "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define EFFECT_CHAR_UUID           "beb5483e-36e1-4688-b7f5-ea07361b26aa"
#define STATUS_CHAR_UUID           "beb5483e-36e1-4688-b7f5-ea07361b26ab"
#define WAKE_EFFECT_CHAR_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26ac"
#define ALARM_STATE_CHAR_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26ad"
#define ALARM_CONTROL_CHAR_UUID    "beb5483e-36e1-4688-b7f5-ea07361b26ae"
#define SPEAKER_VOLUME_CHAR_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26b0"
#define SPEAKER_CONTROL_CHAR_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26b1"
#define RINGTONE_SELECT_CHAR_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26b2"
#define VOICE_UPLOAD_CHAR_UUID     "beb5483e-36e1-4688-b7f5-ea07361b26b3"
#define TIME_SYNC_CHAR_UUID        "beb5483e-36e1-4688-b7f5-ea07361b26b4"
#define BATTERY_LEVEL_CHAR_UUID    "beb5483e-36e1-4688-b7f5-ea07361b26b5"

#define STATUS_DRV2605L  0x01
#define STATUS_AUDIO     0x02

#define SPEAKER_CMD_STOP            0x00
#define SPEAKER_CMD_TEST_TONE       0x01
#define SPEAKER_CMD_ALARM_SOUND_OFF 0x02
#define SPEAKER_CMD_ALARM_SOUND_ON  0x03
#define SPEAKER_CMD_PLAY_UPLOADED   0x04

#define VOICE_UPLOAD_CMD_BEGIN      0x01
#define VOICE_UPLOAD_CMD_CHUNK      0x02
#define VOICE_UPLOAD_CMD_END        0x03

// --- Hybrid hardware profile ---
#if defined(TARGET_BOARD_ADAFRUIT_FEATHER_ESP32_V2)
static constexpr const char *BOARD_NAME = "Adafruit Feather ESP32 V2";
static constexpr int HW_I2C_SDA = 22;
static constexpr int HW_I2C_SCL = 20;
static constexpr bool HAS_BATTERY_MONITOR = true;
static constexpr int BATTERY_MONITOR_PIN = 35;
#elif defined(TARGET_BOARD_ESP32_WROOM_32E)
static constexpr const char *BOARD_NAME = "ESP32-WROOM-32E";
static constexpr int HW_I2C_SDA = 21;
static constexpr int HW_I2C_SCL = 22;
static constexpr bool HAS_BATTERY_MONITOR = false;
#else
static constexpr const char *BOARD_NAME = "Original ESP32";
static constexpr int HW_I2C_SDA = 21;
static constexpr int HW_I2C_SCL = 22;
static constexpr bool HAS_BATTERY_MONITOR = false;
#endif

// Feather ESP32 V2 and generic original ESP32 modules both use the same wiring here.
static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int I2S_BCLK_PIN = 26;
static constexpr int I2S_LRCLK_PIN = 27;
static constexpr int I2S_DOUT_PIN = 25; // ESP32 -> MAX98357A DIN
static constexpr uint32_t DEFAULT_RINGTONE_SAMPLE_RATE = 8000;
static constexpr uint32_t UPLOADED_VOICE_SAMPLE_RATE = 24000;
static constexpr uint8_t DEFAULT_WAKE_EFFECT_ID = 1;
static constexpr uint8_t CUSTOM_EFFECT_SINE_RAMP = 124;
static constexpr unsigned long CUSTOM_HAPTIC_CYCLE_MS = 60000;
static constexpr unsigned long CUSTOM_HAPTIC_UPDATE_INTERVAL_MS = 40;

static constexpr const char *BLE_NAME_PREFIX = "Awaken-Control";
static constexpr const char *A2DP_NAME_PREFIX = "Awaken-Stream-Hybrid";
static constexpr uint8_t A2DP_STARTUP_VOLUME = 55; // 0..127
char bleName[32] = {0};
char a2dpName[40] = {0};

// Keep this aligned with your environment.
const char* ssid = "BOSCO";
const char* password = "Yadagjb0ys!";
WiFiUDP ntpUDP;
NTPClient timeClient(ntpUDP, "pool.ntp.org", -18000);

class HybridA2DPSink : public BluetoothA2DPSinkQueued {
public:
    void setOutputActive(bool active) {
        set_i2s_active(active);
    }
};

HybridA2DPSink a2dpSink;
Adafruit_DRV2605 drv;

BLECharacteristic *pStatusCharacteristic = nullptr;
BLECharacteristic *pAlarmStateChar = nullptr;
BLECharacteristic *pBatteryLevelChar = nullptr;

uint8_t moduleStatus = STATUS_AUDIO;
uint8_t alarmState = 0;
constexpr uint8_t BATTERY_LEVEL_UNAVAILABLE = 0xFF;
constexpr unsigned long BATTERY_SAMPLE_INTERVAL_MS = 60000;
uint8_t batteryLevelPercent = BATTERY_LEVEL_UNAVAILABLE;
uint8_t vibrationIntensity = 64;
uint8_t wakeEffectId = DEFAULT_WAKE_EFFECT_ID;
uint8_t speakerVolume = 55; // app-facing 0..100
bool alarmSoundEnabled = true;

long alarmHour = -1;
long alarmMinute = -1;
bool alarmIsSet = false;
bool alarmIsTriggered = false;
bool alarmFiring = false;
bool hasValidTime = false;
bool hasAppTime = false;
unsigned long alarmDeadlineMs = 0;
unsigned long appTimeSyncMillis = 0;
uint32_t appTimeSyncSecOfDay = 0;

const char* uploadedVoiceFile = "/voice_alarm.pcm";
const char* defaultRingtoneFile = "/ringtone0.pcm";
static constexpr bool STREAMING_ALARM_MODE = false;
bool uploadedVoiceReady = false;
uint32_t uploadedVoiceSampleRate = UPLOADED_VOICE_SAMPLE_RATE;
bool voiceUploadActive = false;
uint32_t uploadedVoiceExpectedBytes = 0;
uint32_t uploadedVoiceReceivedBytes = 0;
File uploadedVoiceHandle;
File playbackFileHandle;
bool playbackLoopEnabled = false;
bool playbackActive = false;
volatile bool localAudioOwnsI2S = false;
bool a2dpConnected = false;
esp_a2d_audio_state_t a2dpAudioState = ESP_A2D_AUDIO_STATE_REMOTE_SUSPEND;
unsigned long lastA2dpConnectableRefreshMs = 0;
unsigned long lastA2dpPlayKickMs = 0;
unsigned long alarmTriggeredAtMs = 0;
unsigned long lastAlarmHapticPulseMs = 0;
unsigned long lastAlarmFallbackToneMs = 0;
unsigned long lastBatterySampleMs = 0;
uint8_t currentDrvMode = 0xFF;
bool customHapticActive = false;
bool customHapticLoop = false;
unsigned long customHapticStartMs = 0;
unsigned long customHapticLastUpdateMs = 0;
bool namesInitialized = false;

bool isCustomHapticEffect(uint8_t effectId);
void ensureDrvMode(uint8_t mode);
void stopHaptics();
void playStandardHapticEffect(uint8_t effectId);
void startCustomHapticPattern(bool shouldLoop);
void stopCustomHapticPattern();
bool serviceCustomHapticPattern();
void serviceAlarmHaptics();
void initHaptics();
void initBatteryMonitor();
void serviceBatteryMonitor();
uint8_t readBatteryLevelPercent();
void updateBatteryLevelCharacteristic(bool notifySubscribers);

bool isCustomHapticEffect(uint8_t effectId) {
    return effectId == CUSTOM_EFFECT_SINE_RAMP;
}

void ensureDrvMode(uint8_t mode) {
    if (!(moduleStatus & STATUS_DRV2605L)) return;
    if (currentDrvMode == mode) return;
    drv.setMode(mode);
    delay(10);
    currentDrvMode = mode;
}

void stopHaptics() {
    customHapticActive = false;
    customHapticLoop = false;
    if (!(moduleStatus & STATUS_DRV2605L)) return;
    ensureDrvMode(DRV2605_MODE_REALTIME);
    drv.setRealtimeValue(0);
}

void playStandardHapticEffect(uint8_t effectId) {
    if (!(moduleStatus & STATUS_DRV2605L)) return;
    stopCustomHapticPattern();
    ensureDrvMode(DRV2605_MODE_INTTRIG);
    drv.setWaveform(0, effectId);
    drv.setWaveform(1, 0);
    drv.go();
    delay(10);
}

void startCustomHapticPattern(bool shouldLoop) {
    if (!(moduleStatus & STATUS_DRV2605L)) return;
    customHapticActive = true;
    customHapticLoop = shouldLoop;
    customHapticStartMs = millis();
    customHapticLastUpdateMs = 0;
    ensureDrvMode(DRV2605_MODE_REALTIME);
    drv.setRealtimeValue(0);
}

void stopCustomHapticPattern() {
    if (!(moduleStatus & STATUS_DRV2605L)) {
        customHapticActive = false;
        customHapticLoop = false;
        return;
    }
    if (!customHapticActive) return;
    customHapticActive = false;
    customHapticLoop = false;
    ensureDrvMode(DRV2605_MODE_REALTIME);
    drv.setRealtimeValue(0);
}

bool serviceCustomHapticPattern() {
    if (!(moduleStatus & STATUS_DRV2605L) || !customHapticActive) return false;

    unsigned long now = millis();
    if (customHapticLastUpdateMs != 0 &&
        now - customHapticLastUpdateMs < CUSTOM_HAPTIC_UPDATE_INTERVAL_MS) {
        return true;
    }

    unsigned long elapsed = now - customHapticStartMs;
    if (!customHapticLoop && elapsed >= CUSTOM_HAPTIC_CYCLE_MS) {
        stopCustomHapticPattern();
        return false;
    }
    if (customHapticLoop) {
        elapsed %= CUSTOM_HAPTIC_CYCLE_MS;
    }

    float phase = ((2.0f * M_PI * elapsed) / CUSTOM_HAPTIC_CYCLE_MS) - (M_PI / 2.0f);
    float normalized = (sinf(phase) + 1.0f) * 0.5f;
    uint8_t intensity = (uint8_t)roundf(normalized * 127.0f);

    ensureDrvMode(DRV2605_MODE_REALTIME);
    drv.setRealtimeValue(intensity);
    customHapticLastUpdateMs = now;
    return true;
}

void serviceAlarmHaptics() {
    if (!(moduleStatus & STATUS_DRV2605L) || !alarmFiring) return;

    if (isCustomHapticEffect(wakeEffectId)) {
        if (!customHapticActive) startCustomHapticPattern(true);
        serviceCustomHapticPattern();
        return;
    }

    if (customHapticActive) stopCustomHapticPattern();

    unsigned long now = millis();
    if (now - lastAlarmHapticPulseMs > 2500) {
        playStandardHapticEffect(wakeEffectId);
        lastAlarmHapticPulseMs = now;
    }
}

void initHaptics() {
    Wire.begin(HW_I2C_SDA, HW_I2C_SCL);
    Serial.print("I2C configured: SDA=");
    Serial.print(HW_I2C_SDA);
    Serial.print(" SCL=");
    Serial.println(HW_I2C_SCL);

    Serial.println("Initializing DRV2605L...");
    if (drv.begin()) {
        drv.selectLibrary(1);
        drv.setMode(DRV2605_MODE_INTTRIG);
        currentDrvMode = DRV2605_MODE_INTTRIG;
        drv.setWaveform(0, DEFAULT_WAKE_EFFECT_ID);
        drv.setWaveform(1, 0);
        drv.go();
        moduleStatus |= STATUS_DRV2605L;
        Serial.println("DRV2605L ready");
    } else {
        Serial.println("DRV2605L not found — continuing without haptics");
    }
}

uint8_t readBatteryLevelPercent() {
    if (!HAS_BATTERY_MONITOR) return BATTERY_LEVEL_UNAVAILABLE;

    uint32_t millivolts = analogReadMilliVolts(BATTERY_MONITOR_PIN);
    if (millivolts == 0) return BATTERY_LEVEL_UNAVAILABLE;

    float batteryVolts = (millivolts * 2.0f) / 1000.0f;
    if (batteryVolts <= 3.2f) return 0;
    if (batteryVolts >= 4.2f) return 100;
    return (uint8_t)roundf((batteryVolts - 3.2f) * 100.0f);
}

void updateBatteryLevelCharacteristic(bool notifySubscribers) {
    uint8_t latest = readBatteryLevelPercent();
    bool changed = latest != batteryLevelPercent;
    batteryLevelPercent = latest;

    if (!pBatteryLevelChar) return;
    pBatteryLevelChar->setValue(&batteryLevelPercent, 1);
    if (notifySubscribers && changed) {
        pBatteryLevelChar->notify();
    }
}

void initBatteryMonitor() {
    if (HAS_BATTERY_MONITOR) {
        pinMode(BATTERY_MONITOR_PIN, INPUT);
        analogSetPinAttenuation(BATTERY_MONITOR_PIN, ADC_11db);
    }
    updateBatteryLevelCharacteristic(false);
    lastBatterySampleMs = millis();
}

void serviceBatteryMonitor() {
    unsigned long now = millis();
    if (lastBatterySampleMs != 0 && now - lastBatterySampleMs < BATTERY_SAMPLE_INTERVAL_MS) {
        return;
    }
    updateBatteryLevelCharacteristic(true);
    lastBatterySampleMs = now;
}

void acquireI2SForLocalPlayback(uint32_t sampleRate) {
    if (a2dpConnected) {
        a2dpSink.setOutputActive(false);
    }
    localAudioOwnsI2S = true;
    delay(20); // let any in-flight A2DP write finish
    esp_err_t err = i2s_set_clk(
        I2S_PORT,
        sampleRate,
        I2S_BITS_PER_SAMPLE_16BIT,
        I2S_CHANNEL_STEREO
    );
    if (err != ESP_OK) {
        Serial.print("i2s_set_clk(local) failed err=");
        Serial.println((int)err);
    }
}

void releaseI2SToA2DP() {
    i2s_zero_dma_buffer(I2S_PORT);
    esp_err_t err = i2s_set_clk(
        I2S_PORT,
        44100,
        I2S_BITS_PER_SAMPLE_16BIT,
        I2S_CHANNEL_STEREO
    );
    if (err != ESP_OK) {
        Serial.print("i2s_set_clk(a2dp) failed err=");
        Serial.println((int)err);
    }
    localAudioOwnsI2S = false;
    if (a2dpConnected) {
        a2dpSink.setOutputActive(true);
    }
}

void initDeviceNames() {
    if (namesInitialized) return;
    uint8_t btMac[6] = {0};
    esp_read_mac(btMac, ESP_MAC_BT);
    snprintf(bleName, sizeof(bleName), "%s-%02X%02X", BLE_NAME_PREFIX, btMac[4], btMac[5]);
    snprintf(a2dpName, sizeof(a2dpName), "%s-%02X%02X", A2DP_NAME_PREFIX, btMac[4], btMac[5]);
    namesInitialized = true;
}

void onA2dpConnectionStateChanged(esp_a2d_connection_state_t state, void *) {
    a2dpConnected = (state == ESP_A2D_CONNECTION_STATE_CONNECTED);
    Serial.print("A2DP connection state: ");
    Serial.println(a2dpSink.to_str(state));
}

void onA2dpAudioStateChanged(esp_a2d_audio_state_t state, void *) {
    a2dpAudioState = state;
    Serial.print("A2DP audio state: ");
    Serial.println(a2dpSink.to_str(state));
}

void notifyAlarmState(uint8_t state) {
    alarmState = state;
    if (pAlarmStateChar) {
        pAlarmStateChar->setValue(&alarmState, 1);
        pAlarmStateChar->notify();
    }
}

static uint8_t mapPercentToA2dpVolume(uint8_t percent) {
    uint8_t clamped = percent > 100 ? 100 : percent;
    return clamped;
}

void syncTimeAndDisconnectWiFi() {
    Serial.print("Connecting to ");
    Serial.println(ssid);
    WiFi.begin(ssid, password);

    int attempts = 0;
    const int maxAttempts = 12;
    while (WiFi.status() != WL_CONNECTED && attempts < maxAttempts) {
        delay(1000);
        attempts++;
        Serial.print("WiFi attempt ");
        Serial.print(attempts);
        Serial.print("/");
        Serial.print(maxAttempts);
        Serial.print(" status=");
        Serial.println(WiFi.status());
    }

    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("WiFi connected — syncing NTP time");
        timeClient.begin();

        bool gotTime = false;
        for (int i = 0; i < 5; i++) {
            if (timeClient.forceUpdate()) {
                gotTime = true;
                break;
            }
            delay(500);
        }

        if (gotTime) {
            hasValidTime = true;
            Serial.print("NTP time synced: ");
            Serial.println(timeClient.getFormattedTime());
        } else {
            Serial.println("NTP sync failed");
        }

        // Disconnect WiFi to free the radio for BLE + A2DP.
        // NTPClient keeps time via its cached offset + millis().
        WiFi.disconnect(true);
        WiFi.mode(WIFI_OFF);
        Serial.println("WiFi off — radio freed for Bluetooth");
    } else {
        Serial.println("WiFi failed — alarm time trigger disabled");
        WiFi.disconnect(true);
        WiFi.mode(WIFI_OFF);
    }
}

void stopSpeakerOutput() {
    if (!a2dpConnected || localAudioOwnsI2S) {
        i2s_zero_dma_buffer(I2S_PORT);
    }
}

void stopFilePlayback() {
    if (playbackFileHandle) {
        playbackFileHandle.close();
    }
    playbackActive = false;
    playbackLoopEnabled = false;
    if (localAudioOwnsI2S) {
        releaseI2SToA2DP();
    }
}

bool startFilePlayback(const char* filePath, bool loopPlayback, uint32_t sampleRate) {
    stopFilePlayback();
    acquireI2SForLocalPlayback(sampleRate);
    playbackFileHandle = SPIFFS.open(filePath, "r");
    if (!playbackFileHandle) {
        Serial.print("Failed to open audio file: ");
        Serial.println(filePath);
        return false;
    }

    playbackLoopEnabled = loopPlayback;
    playbackActive = true;
    return true;
}

void serviceFilePlayback() {
    if (!playbackActive || !playbackFileHandle) return;

    int16_t monoBuf[256];
    int16_t stereoBuf[512];
    size_t bytesWritten;
    int16_t amplitude = (int16_t)((int32_t)32767 * speakerVolume / 100);

    size_t bytesRead = playbackFileHandle.read((uint8_t*)monoBuf, sizeof(monoBuf));
    if (bytesRead == 0) {
        if (playbackLoopEnabled && alarmFiring) {
            playbackFileHandle.seek(0);
            return;
        }
        stopFilePlayback();
        stopSpeakerOutput();
        return;
    }

    int samples = bytesRead / (int)sizeof(int16_t);
    for (int i = 0; i < samples; i++) {
        int16_t scaled = (int16_t)((int32_t)monoBuf[i] * amplitude / 32767);
        stereoBuf[i * 2] = scaled;
        stereoBuf[i * 2 + 1] = scaled;
    }

    i2s_write(I2S_PORT, stereoBuf, samples * 2 * sizeof(int16_t), &bytesWritten, pdMS_TO_TICKS(10));
}

bool parseAlarmTime(const std::string &raw, long &outHour, long &outMinute) {
    if (raw.empty()) return false;
    String value(raw.c_str());
    value.trim();
    int pipeIdx = value.indexOf('|');
    if (pipeIdx >= 0) {
        value = value.substring(0, pipeIdx);
        value.trim();
    }

    int colon = value.indexOf(':');
    if (colon < 1 || colon > 2) return false;
    if (value.length() < colon + 3) return false;

    long hour = value.substring(0, colon).toInt();
    long minute = value.substring(colon + 1, colon + 3).toInt();
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return false;

    outHour = hour;
    outMinute = minute;
    return true;
}

bool parseAlarmDelaySeconds(const std::string &raw, unsigned long &outDelaySec) {
    String value(raw.c_str());
    value.trim();
    int pipeIdx = value.indexOf('|');
    if (pipeIdx < 0) return false;
    if (pipeIdx + 1 >= value.length()) return false;

    String delayPart = value.substring(pipeIdx + 1);
    delayPart.trim();
    if (delayPart.length() == 0) return false;

    long parsed = delayPart.toInt();
    if (parsed <= 0) return false;
    outDelaySec = (unsigned long)parsed;
    return true;
}

bool parseHms(const std::string &raw, uint32_t &secOfDay) {
    String value(raw.c_str());
    value.trim();
    int c1 = value.indexOf(':');
    if (c1 < 1) return false;
    int c2 = value.indexOf(':', c1 + 1);
    if (c2 < 0) c2 = value.length();
    if (c2 <= c1 + 1) return false;

    long hour = value.substring(0, c1).toInt();
    long minute = value.substring(c1 + 1, c2).toInt();
    long second = 0;
    if (c2 < value.length() - 1) {
        second = value.substring(c2 + 1).toInt();
    }

    if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
        return false;
    }

    secOfDay = (uint32_t)(hour * 3600 + minute * 60 + second);
    return true;
}

bool getAppTimeHm(int &hour, int &minute) {
    if (!hasAppTime) return false;
    unsigned long elapsedSec = (millis() - appTimeSyncMillis) / 1000UL;
    uint32_t secOfDay = (appTimeSyncSecOfDay + elapsedSec) % 86400UL;
    hour = (int)(secOfDay / 3600UL);
    minute = (int)((secOfDay % 3600UL) / 60UL);
    return true;
}

void playSpeakerTone(uint16_t frequencyHz, uint16_t durationMs) {
    if (speakerVolume == 0 || frequencyHz == 0 || durationMs == 0) return;
    bool needRelease = !localAudioOwnsI2S;
    if (needRelease) acquireI2SForLocalPlayback(DEFAULT_RINGTONE_SAMPLE_RATE);

    const uint32_t sampleRate = DEFAULT_RINGTONE_SAMPLE_RATE;
    int totalSamples = (sampleRate * durationMs) / 1000;
    float phaseInc = (2.0f * (float)M_PI * (float)frequencyHz) / (float)sampleRate;
    float phase = 0.0f;
    int16_t amplitude = (int16_t)((int32_t)28000 * speakerVolume / 100);

    int16_t buf[512]; // stereo interleaved
    size_t bytesWritten;
    int written = 0;

    while (written < totalSamples) {
        int chunk = totalSamples - written;
        if (chunk > 256) chunk = 256;

        for (int i = 0; i < chunk; i++) {
            int16_t sample = (int16_t)(sinf(phase) * amplitude);
            buf[i * 2] = sample;
            buf[i * 2 + 1] = sample;
            phase += phaseInc;
            if (phase >= 2.0f * (float)M_PI) phase -= 2.0f * (float)M_PI;
        }

        i2s_write(I2S_PORT, buf, chunk * 2 * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        written += chunk;
    }

    if (needRelease) releaseI2SToA2DP();
}

void triggerAlarm() {
    if (alarmFiring) return;
    Serial.println("ALARM triggered");
    alarmIsTriggered = true;
    alarmFiring = true;
    alarmTriggeredAtMs = millis();
    lastAlarmHapticPulseMs = 0;
    lastAlarmFallbackToneMs = 0;
    if (isCustomHapticEffect(wakeEffectId)) {
        startCustomHapticPattern(true);
    } else {
        stopCustomHapticPattern();
    }
    notifyAlarmState(1);

    if (STREAMING_ALARM_MODE) {
        // Streaming-first mode: app/phone should play alarm audio over A2DP.
        // Keep BLE alarm state active, but don't start local PCM playback.
        stopFilePlayback();
        Serial.println("Alarm firing: waiting for phone/A2DP stream");
        if (a2dpConnected) {
            a2dpSink.play();
            lastA2dpPlayKickMs = millis();
            Serial.println("Alarm firing: sent AVRCP play");
        }
    } else if (alarmSoundEnabled) {
        if (uploadedVoiceReady) {
            startFilePlayback(uploadedVoiceFile, true, uploadedVoiceSampleRate);
        } else if (!startFilePlayback(defaultRingtoneFile, true, DEFAULT_RINGTONE_SAMPLE_RATE)) {
            playSpeakerTone(880, 120);
            lastAlarmFallbackToneMs = millis();
            Serial.println("Alarm fallback ringtone missing; using tone fallback");
        }
    }
}

void stopAlarm() {
    alarmFiring = false;
    alarmIsSet = false;
    alarmIsTriggered = false;
    alarmDeadlineMs = 0;
    notifyAlarmState(0);
    stopFilePlayback();
    stopSpeakerOutput();
    stopHaptics();
    alarmTriggeredAtMs = 0;
    lastAlarmHapticPulseMs = 0;
    lastAlarmFallbackToneMs = 0;
    Serial.println("Alarm stopped");
}

void snoozeAlarm() {
    alarmFiring = false;
    alarmMinute += 5;
    if (alarmMinute >= 60) {
        alarmMinute -= 60;
        alarmHour = (alarmHour + 1) % 24;
    }
    alarmIsTriggered = false;
    alarmDeadlineMs = millis() + (5UL * 60UL * 1000UL);
    notifyAlarmState(0);
    stopFilePlayback();
    stopSpeakerOutput();
    stopHaptics();
    alarmTriggeredAtMs = 0;
    lastAlarmHapticPulseMs = 0;
    lastAlarmFallbackToneMs = 0;
    Serial.print("Snoozed. Next alarm: ");
    Serial.print(alarmHour);
    Serial.print(":");
    Serial.println(alarmMinute);
}

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer *) override {
        Serial.println("BLE client connected");
    }

    void onConnect(BLEServer *, esp_ble_gatts_cb_param_t *param) override {
        if (!param) return;
        // Looser BLE intervals leave more airtime for A2DP (Classic BT audio).
        esp_ble_conn_update_params_t connParams = {};
        memcpy(connParams.bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
        connParams.latency = 0;
        connParams.min_int = 0x18; // 30 ms
        connParams.max_int = 0x30; // 60 ms
        connParams.timeout = 400;  // 4 s supervision timeout
        esp_err_t err = esp_ble_gap_update_conn_params(&connParams);
        if (err != ESP_OK) {
            Serial.print("BLE conn param update failed: ");
            Serial.println((int)err);
        }
    }

    void onDisconnect(BLEServer *server) override {
        Serial.println("BLE client disconnected");
        server->getAdvertising()->start();
    }
};

class AlarmCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        long newHour = -1;
        long newMinute = -1;
        unsigned long delaySec = 0;
        if (parseAlarmTime(value, newHour, newMinute)) {
            alarmHour = newHour;
            alarmMinute = newMinute;
            alarmIsSet = true;
            alarmIsTriggered = false;
            if (parseAlarmDelaySeconds(value, delaySec)) {
                alarmDeadlineMs = millis() + (delaySec * 1000UL);
            } else {
                alarmDeadlineMs = 0;
            }
            Serial.print("Alarm set for: ");
            if (alarmHour < 10) Serial.print("0");
            Serial.print(alarmHour);
            Serial.print(":");
            if (alarmMinute < 10) Serial.print("0");
            Serial.println(alarmMinute);
            if (!hasValidTime && alarmDeadlineMs > 0) {
                Serial.print("Alarm fallback countdown sec=");
                Serial.println(delaySec);
            }
        } else {
            Serial.print("Alarm write parse failed: '");
            Serial.print(String(value.c_str()));
            Serial.println("'");
        }
    }
};

class IntensityCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        if (!(moduleStatus & STATUS_DRV2605L)) return;

        std::string value = pChar->getValue();
        if (value.empty()) return;

        vibrationIntensity = (uint8_t)value[0];
        stopCustomHapticPattern();
        if (vibrationIntensity == 0) {
            stopHaptics();
            if (alarmFiring || alarmIsTriggered) {
                stopAlarm();
            }
            Serial.println("Motor stopped");
        } else {
            ensureDrvMode(DRV2605_MODE_REALTIME);
            drv.setRealtimeValue(vibrationIntensity);
            Serial.print("Vibration intensity: ");
            Serial.println(vibrationIntensity);
        }
    }
};

class EffectCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        if (!(moduleStatus & STATUS_DRV2605L)) return;

        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t effectId = (uint8_t)value[0];
        if (isCustomHapticEffect(effectId)) {
            startCustomHapticPattern(false);
            Serial.println("Playing custom sine ramp effect");
        } else if (effectId >= 1 && effectId <= 123) {
            playStandardHapticEffect(effectId);
            Serial.print("Playing effect: ");
            Serial.println(effectId);
        }
    }
};

class WakeEffectCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t effectId = (uint8_t)value[0];
        if (isCustomHapticEffect(effectId) || (effectId >= 1 && effectId <= 123)) {
            wakeEffectId = effectId;
            Serial.print("Wake effect set to: ");
            Serial.println(wakeEffectId);
        }
    }
};

class AlarmControlCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t cmd = (uint8_t)value[0];
        if (cmd == 0) {
            Serial.println("Alarm control: stop");
            stopAlarm();
        } else if (cmd == 1) {
            Serial.println("Alarm control: snooze");
            snoozeAlarm();
        } else {
            Serial.print("Alarm control unknown cmd=");
            Serial.println(cmd);
        }
    }
};

class SpeakerVolumeCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t requested = (uint8_t)value[0];
        if (requested > 100) requested = 100;
        speakerVolume = requested;
        a2dpSink.set_volume(mapPercentToA2dpVolume(speakerVolume));
        pChar->setValue(&speakerVolume, 1);
        Serial.print("Speaker volume=");
        Serial.print(speakerVolume);
        Serial.println("%");
    }
};

class SpeakerControlCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t cmd = (uint8_t)value[0];

        if (cmd == SPEAKER_CMD_STOP) {
            stopFilePlayback();
            stopSpeakerOutput();
            if (alarmFiring || alarmIsTriggered) {
                stopAlarm();
            }
            return;
        }

        if (cmd == SPEAKER_CMD_TEST_TONE) {
            uint16_t freq = 880;
            if (value.length() >= 3) {
                freq = (uint16_t)((uint8_t)value[1]) | ((uint16_t)((uint8_t)value[2]) << 8);
                if (freq < 100) freq = 100;
                if (freq > 5000) freq = 5000;
            }
            playSpeakerTone(freq, 280);
            return;
        }

        if (cmd == SPEAKER_CMD_ALARM_SOUND_OFF) {
            alarmSoundEnabled = false;
            stopFilePlayback();
            stopSpeakerOutput();
            return;
        }

        if (cmd == SPEAKER_CMD_ALARM_SOUND_ON) {
            alarmSoundEnabled = true;
            if (alarmFiring && !STREAMING_ALARM_MODE) {
                if (uploadedVoiceReady) {
                    startFilePlayback(uploadedVoiceFile, true, uploadedVoiceSampleRate);
                } else {
                    startFilePlayback(defaultRingtoneFile, true, DEFAULT_RINGTONE_SAMPLE_RATE);
                }
            }
            return;
        }

        if (cmd == SPEAKER_CMD_PLAY_UPLOADED) {
            if (uploadedVoiceReady) {
                startFilePlayback(uploadedVoiceFile, false, uploadedVoiceSampleRate);
            } else {
                playSpeakerTone(880, 240);
            }
            return;
        }
    }
};

class VoiceUploadCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t cmd = (uint8_t)value[0];

        if (cmd == VOICE_UPLOAD_CMD_BEGIN) {
            if (uploadedVoiceHandle) uploadedVoiceHandle.close();
            stopFilePlayback();
            uploadedVoiceExpectedBytes = 0;
            uploadedVoiceReceivedBytes = 0;
            uploadedVoiceReady = false;
            voiceUploadActive = false;

            if (value.length() >= 5) {
                uploadedVoiceExpectedBytes =
                    ((uint32_t)(uint8_t)value[1]) |
                    ((uint32_t)(uint8_t)value[2] << 8) |
                    ((uint32_t)(uint8_t)value[3] << 16) |
                    ((uint32_t)(uint8_t)value[4] << 24);
            }
            uploadedVoiceSampleRate = UPLOADED_VOICE_SAMPLE_RATE;
            if (value.length() >= 9) {
                uploadedVoiceSampleRate =
                    ((uint32_t)(uint8_t)value[5]) |
                    ((uint32_t)(uint8_t)value[6] << 8) |
                    ((uint32_t)(uint8_t)value[7] << 16) |
                    ((uint32_t)(uint8_t)value[8] << 24);
            }

            uploadedVoiceHandle = SPIFFS.open(uploadedVoiceFile, "w");
            if (!uploadedVoiceHandle) {
                Serial.println("Voice upload start failed: could not open file");
                return;
            }

            voiceUploadActive = true;
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_CHUNK) {
            if (!voiceUploadActive || !uploadedVoiceHandle) return;
            if (value.length() <= 1) return;

            size_t wrote = uploadedVoiceHandle.write((const uint8_t*)&value[1], value.length() - 1);
            uploadedVoiceReceivedBytes += wrote;
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_END) {
            if (uploadedVoiceHandle) uploadedVoiceHandle.close();
            voiceUploadActive = false;
            uploadedVoiceReady = uploadedVoiceReceivedBytes > 0;
            Serial.print("Voice upload done bytes=");
            Serial.print(uploadedVoiceReceivedBytes);
            Serial.print(" expected=");
            Serial.print(uploadedVoiceExpectedBytes);
            Serial.print(" sampleRate=");
            Serial.println(uploadedVoiceSampleRate);
            return;
        }
    }
};

class TimeSyncCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;
        uint32_t secOfDay = 0;
        if (!parseHms(value, secOfDay)) {
            Serial.print("Time sync parse failed: '");
            Serial.print(String(value.c_str()));
            Serial.println("'");
            return;
        }

        appTimeSyncSecOfDay = secOfDay;
        appTimeSyncMillis = millis();
        hasAppTime = true;
        int hh = (int)(secOfDay / 3600UL);
        int mm = (int)((secOfDay % 3600UL) / 60UL);
        int ss = (int)(secOfDay % 60UL);
        Serial.printf("App time synced: %02d:%02d:%02d\n", hh, mm, ss);
    }
};

void setupBle() {
    BLEDevice::init(bleName);
    BLEServer *server = BLEDevice::createServer();
    server->setCallbacks(new MyServerCallbacks());

    BLEService *service = server->createService(BLEUUID(SERVICE_UUID), 40);

    BLECharacteristic *alarmChar = service->createCharacteristic(
        ALARM_CHARACTERISTIC_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    alarmChar->setCallbacks(new AlarmCallback());

    BLECharacteristic *intensityChar = service->createCharacteristic(
        INTENSITY_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    intensityChar->setCallbacks(new IntensityCallback());

    BLECharacteristic *effectChar = service->createCharacteristic(
        EFFECT_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    effectChar->setCallbacks(new EffectCallback());

    BLECharacteristic *wakeEffectChar = service->createCharacteristic(
        WAKE_EFFECT_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    wakeEffectChar->setCallbacks(new WakeEffectCallback());

    service->createCharacteristic(RINGTONE_SELECT_CHAR_UUID,
                                  BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);

    pStatusCharacteristic = service->createCharacteristic(
        STATUS_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
    pStatusCharacteristic->setValue(&moduleStatus, 1);

    pBatteryLevelChar = service->createCharacteristic(
        BATTERY_LEVEL_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    pBatteryLevelChar->addDescriptor(new BLE2902());
    pBatteryLevelChar->setValue(&batteryLevelPercent, 1);

    pAlarmStateChar = service->createCharacteristic(
        ALARM_STATE_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    pAlarmStateChar->addDescriptor(new BLE2902());
    pAlarmStateChar->setValue(&alarmState, 1);

    BLECharacteristic *alarmControlChar = service->createCharacteristic(
        ALARM_CONTROL_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    alarmControlChar->setCallbacks(new AlarmControlCallback());

    BLECharacteristic *speakerVolumeChar = service->createCharacteristic(
        SPEAKER_VOLUME_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    speakerVolumeChar->setCallbacks(new SpeakerVolumeCallback());
    speakerVolumeChar->setValue(&speakerVolume, 1);

    BLECharacteristic *speakerControlChar = service->createCharacteristic(
        SPEAKER_CONTROL_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    speakerControlChar->setCallbacks(new SpeakerControlCallback());

    BLECharacteristic *voiceUploadChar = service->createCharacteristic(
        VOICE_UPLOAD_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    voiceUploadChar->setCallbacks(new VoiceUploadCallback());

    BLECharacteristic *timeSyncChar = service->createCharacteristic(
        TIME_SYNC_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    timeSyncChar->setCallbacks(new TimeSyncCallback());

    service->start();
    BLEAdvertising *advertising = server->getAdvertising();
    BLEAdvertisementData advData;
    advData.setFlags(ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT);
    advData.setCompleteServices(BLEUUID(SERVICE_UUID));
    advertising->setAdvertisementData(advData);

    BLEAdvertisementData scanRespData;
    scanRespData.setName(bleName);
    advertising->setScanResponseData(scanRespData);

    advertising->setScanResponse(true);
    // iOS-friendly preferred connection parameter hints.
    advertising->setMinPreferred(0x06);
    advertising->setMinPreferred(0x12);
    advertising->start();

    Serial.print("BLE service started as ");
    Serial.println(bleName);
}

void setupA2dp() {
    i2s_config_t i2sConfig = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
        .sample_rate = 44100,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
        .intr_alloc_flags = 0,
        .dma_buf_count = 16,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0
    };

    i2s_pin_config_t pinConfig = {
        .bck_io_num = I2S_BCLK_PIN,
        .ws_io_num = I2S_LRCLK_PIN,
        .data_out_num = I2S_DOUT_PIN,
        .data_in_num = I2S_PIN_NO_CHANGE
    };

    // Hybrid firmware uses BLE + A2DP at the same time.
    a2dpSink.set_default_bt_mode(ESP_BT_MODE_BTDM);
    a2dpSink.set_i2s_ringbuffer_size(64 * 1024);
    a2dpSink.set_i2s_ringbuffer_prefetch_percent(70);
    a2dpSink.set_i2s_write_size_upto(1024);
    a2dpSink.set_mono_downmix(true);
    a2dpSink.set_volume(A2DP_STARTUP_VOLUME);
    a2dpSink.set_i2s_port(I2S_PORT);
    a2dpSink.set_i2s_config(i2sConfig);
    a2dpSink.set_pin_config(pinConfig);
    a2dpSink.set_on_connection_state_changed(onA2dpConnectionStateChanged);
    a2dpSink.set_on_audio_state_changed(onA2dpAudioStateChanged);
    a2dpSink.set_reconnect_delay(1500);
    a2dpSink.start(a2dpName, true); // reconnect to the last paired phone when possible
    a2dpSink.set_connectable(true);
    a2dpSink.set_discoverability(ESP_BT_GENERAL_DISCOVERABLE);

    i2s_zero_dma_buffer(I2S_PORT);

    Serial.print("A2DP sink started as ");
    Serial.println(a2dpName);
    Serial.println("Connect MAX98357A: BCLK=26 LRCLK=27 DIN=25");
}

void ensureClassicNameAndDiscoverable() {
    esp_err_t nameErr = esp_bt_gap_set_device_name(a2dpName);
    if (nameErr != ESP_OK) {
        Serial.print("Failed to re-assert Classic BT name err=");
        Serial.println((int)nameErr);
    } else {
        Serial.print("Classic BT name asserted as ");
        Serial.println(a2dpName);
    }

    a2dpSink.set_connectable(true);
    a2dpSink.set_discoverability(ESP_BT_GENERAL_DISCOVERABLE);
}

void setup() {
    Serial.begin(115200);
    delay(250);
    Serial.println();
    Serial.print("Awaken hybrid firmware on ");
    Serial.println(BOARD_NAME);
    Serial.println("BLE + Bluetooth Classic A2DP + Alarm");
    initDeviceNames();

    if (!SPIFFS.begin(true)) {
        Serial.println("SPIFFS mount failed");
    } else {
        Serial.println("SPIFFS mounted");
        // Restore uploadedVoiceReady if a previous upload survived in SPIFFS
        if (SPIFFS.exists(uploadedVoiceFile)) {
            File f = SPIFFS.open(uploadedVoiceFile, "r");
            if (f && f.size() > 0) {
                uploadedVoiceReady = true;
                Serial.print("Found existing voice file, size=");
                Serial.println(f.size());
            }
            if (f) f.close();
        }
    }

    initHaptics();
    initBatteryMonitor();
    syncTimeAndDisconnectWiFi();
    // A2DP must init FIRST — it starts the BT controller in BTDM (dual) mode.
    // If BLE inits first, the controller may start in BLE-only mode and
    // Classic Bluetooth (A2DP audio) silently fails when streaming begins.
    setupA2dp();
    setupBle();
    ensureClassicNameAndDiscoverable();
}

void loop() {
    serviceBatteryMonitor();

    if (alarmIsSet && !alarmIsTriggered) {
        int currentHour = -1;
        int currentMinute = -1;
        bool hasCurrentTime = false;
        bool shouldTriggerAlarm = false;

        if (alarmDeadlineMs > 0 && millis() >= alarmDeadlineMs) {
            shouldTriggerAlarm = true;
        }

        if (!shouldTriggerAlarm && getAppTimeHm(currentHour, currentMinute)) {
            hasCurrentTime = true;
        } else if (!shouldTriggerAlarm && hasValidTime) {
            currentHour = timeClient.getHours();
            currentMinute = timeClient.getMinutes();
            hasCurrentTime = true;
        }

        if (!shouldTriggerAlarm && hasCurrentTime) {
            if (currentHour == alarmHour && currentMinute == alarmMinute) {
                shouldTriggerAlarm = true;
            }
        }

        if (shouldTriggerAlarm) {
            triggerAlarm();
        }
    }

    if (alarmFiring) {
        serviceAlarmHaptics();

        if (STREAMING_ALARM_MODE) {
            stopFilePlayback();
            if (a2dpConnected && a2dpAudioState != ESP_A2D_AUDIO_STATE_STARTED) {
                unsigned long now = millis();
                if (now - lastA2dpPlayKickMs > 2000) {
                    a2dpSink.play();
                    lastA2dpPlayKickMs = now;
                    Serial.println("Alarm firing: re-sent AVRCP play");
                }
                // If phone refuses to start A2DP streaming, emit local fallback tones
                // quickly so alarm is always audible.
                if (alarmTriggeredAtMs > 0 && now - alarmTriggeredAtMs > 2000 &&
                    now - lastAlarmFallbackToneMs > 1500) {
                    playSpeakerTone(880, 120);
                    lastAlarmFallbackToneMs = now;
                    Serial.println("Alarm firing: fallback tone");
                }
            } else if (!a2dpConnected) {
                unsigned long now = millis();
                if (alarmTriggeredAtMs > 0 && now - lastAlarmFallbackToneMs > 1500) {
                    playSpeakerTone(880, 120);
                    lastAlarmFallbackToneMs = now;
                    Serial.println("Alarm firing: no A2DP, fallback tone");
                }
            }
        } else if (alarmSoundEnabled) {
            if (!playbackActive) {
                if (uploadedVoiceReady) {
                    startFilePlayback(uploadedVoiceFile, true, uploadedVoiceSampleRate);
                } else if (!startFilePlayback(defaultRingtoneFile, true, DEFAULT_RINGTONE_SAMPLE_RATE)) {
                    unsigned long now = millis();
                    if (now - lastAlarmFallbackToneMs > 1500) {
                        playSpeakerTone(880, 120);
                        lastAlarmFallbackToneMs = now;
                    }
                }
            }
        } else {
            stopFilePlayback();
            stopSpeakerOutput();
        }
    }

    if (customHapticActive) {
        serviceCustomHapticPattern();
    }

    serviceFilePlayback();

    if (!a2dpConnected) {
        unsigned long now = millis();
        if (now - lastA2dpConnectableRefreshMs > 5000) {
            a2dpSink.set_connectable(true);
            a2dpSink.set_discoverability(ESP_BT_GENERAL_DISCOVERABLE);
            lastA2dpConnectableRefreshMs = now;
        }
    }

    delay(customHapticActive ? 20 : 100);
}
