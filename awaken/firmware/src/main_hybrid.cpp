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
#include <esp_bt_main.h>
#include <esp_bt.h>
#include <esp_system.h>
#include <esp_pm.h>
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
    volatile bool outputForceMuted = false;

    void muteOutput() { outputForceMuted = true; }
    void unmuteOutput() { outputForceMuted = false; }

    // Skip ring buffer writes when muted — prevents out->begin() and
    // I2S driver reinstall from write_audio's !is_i2s_active path.
    // Let set_i2s_active work normally so the library state machine stays consistent.
    size_t write_audio(const uint8_t *data, size_t size) override {
        if (outputForceMuted) return size; // discard silently
        return BluetoothA2DPSinkQueued::write_audio(data, size);
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
uint8_t alarmRepeatMask = 0; // bitmask: bit0=Sun, bit1=Mon, ..., bit6=Sat
bool hasValidTime = false;
bool hasAppTime = false;
unsigned long alarmDeadlineMs = 0;
unsigned long appTimeSyncMillis = 0;
uint32_t appTimeSyncSecOfDay = 0;
int appTimeSyncDayOfWeek = -1; // 0=Sun, 1=Mon, ..., 6=Sat

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
uint32_t playbackInputRate = 44100;  // sample rate of the file being played
// Gap between alarm audio loops (escalating urgency)
bool playbackInGap = false;
unsigned long playbackGapStartMs = 0;
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

// Forward declarations for A2DP capture
void serviceA2dpCaptureDrain();
void startA2dpCapture();
void stopA2dpCapture();

// --- A2DP audio capture state ---
#define VOICE_UPLOAD_CMD_A2DP_START  0x10
#define VOICE_UPLOAD_CMD_A2DP_STOP   0x11

static constexpr size_t A2DP_CAPTURE_BUF_SIZE = 16384;  // 16KB ring buffer (20ms loop drain keeps up)
static uint8_t a2dpCaptureBuf[A2DP_CAPTURE_BUF_SIZE];
static volatile size_t a2dpCaptureWritePos = 0;
static volatile size_t a2dpCaptureReadPos = 0;
static volatile bool a2dpCaptureActive = false;
static volatile bool a2dpCaptureGotAudio = false; // true once non-silence is detected
static File a2dpCaptureFile;
static uint32_t a2dpCaptureBytesWritten = 0;
static unsigned long a2dpCaptureStartMs = 0;
static constexpr unsigned long A2DP_CAPTURE_TIMEOUT_MS = 30000; // 30s max
static constexpr uint32_t A2DP_CAPTURE_SAMPLE_RATE = 44100;
static constexpr int16_t A2DP_SILENCE_THRESHOLD = 50; // samples below this are silence
static volatile uint32_t a2dpCaptureDroppedSamples = 0;
static volatile bool a2dpCaptureStartRequested = false;
static volatile bool a2dpCaptureStopRequested = false;

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

// --- Power management ---
static bool cpuIsHighSpeed = true;

void setCpuHigh() {
    if (!cpuIsHighSpeed) {
        setCpuFrequencyMhz(240);
        cpuIsHighSpeed = true;
        Serial.println("[Power] CPU -> 240MHz");
    }
}

void setCpuLow() {
    if (cpuIsHighSpeed) {
        setCpuFrequencyMhz(80);
        cpuIsHighSpeed = false;
        Serial.println("[Power] CPU -> 80MHz");
    }
}

bool needsHighCpu() {
    return alarmFiring || playbackActive || customHapticActive
        || a2dpCaptureActive || voiceUploadActive
        || a2dpConnected;
}

void servicePowerManagement() {
    if (needsHighCpu()) {
        setCpuHigh();
    } else {
        setCpuLow();
    }
}

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
    if (now - lastAlarmHapticPulseMs > 800) {
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
    localAudioOwnsI2S = true;
    // Block A2DP's write_audio so it can't push to ring buffer or reinstall I2S
    a2dpSink.muteOutput();
    // Flush stale DMA data and restart I2S for our exclusive use
    i2s_stop(I2S_PORT);
    delay(10);
    i2s_zero_dma_buffer(I2S_PORT);
    i2s_start(I2S_PORT);
    Serial.print("I2S acquired for local playback (file rate=");
    Serial.print(sampleRate);
    Serial.println("Hz, I2S stays at 44100Hz, A2DP muted)");
}

void releaseI2SToA2DP() {
    localAudioOwnsI2S = false;
    // Re-enable A2DP's write_audio path
    a2dpSink.unmuteOutput();
    Serial.println("I2S released back to A2DP");
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
    esp_a2d_audio_state_t prevState = a2dpAudioState;
    a2dpAudioState = state;
    Serial.print("A2DP audio state: ");
    Serial.println(a2dpSink.to_str(state));

    // Auto-stop capture when audio stops playing (phone finished playback)
    if (a2dpCaptureActive &&
        prevState == ESP_A2D_AUDIO_STATE_STARTED &&
        state == ESP_A2D_AUDIO_STATE_REMOTE_SUSPEND) {
        Serial.println("[A2DP Capture] Audio stopped -- auto-stopping capture");
        stopA2dpCapture();
    }
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
    playbackInGap = false;
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

    size_t fileSize = playbackFileHandle.size();
    float durationSec = (sampleRate > 0) ? (float)fileSize / (2.0f * sampleRate) : 0;

    Serial.println("=== PLAYBACK START ===");
    Serial.print("  file: "); Serial.println(filePath);
    Serial.print("  fileSize: "); Serial.print(fileSize); Serial.println(" bytes");
    Serial.print("  sampleRate: "); Serial.print(sampleRate); Serial.println(" Hz");
    Serial.println("  format: 16-bit mono PCM -> stereo I2S @ 44100Hz");
    Serial.print("  duration: "); Serial.print(durationSec, 1); Serial.println(" sec");
    Serial.print("  loop: "); Serial.println(loopPlayback ? "yes" : "no");

    // Dump first 16 bytes to verify data integrity
    uint8_t header[16];
    size_t headerRead = playbackFileHandle.read(header, sizeof(header));
    if (headerRead > 0) {
        Serial.print("  first bytes: ");
        for (size_t i = 0; i < headerRead; i++) {
            if (header[i] < 0x10) Serial.print("0");
            Serial.print(header[i], HEX);
            Serial.print(" ");
        }
        Serial.println();
        playbackFileHandle.seek(0); // rewind after peeking
    }
    Serial.println("======================");

    playbackInputRate = sampleRate;
    playbackLoopEnabled = loopPlayback;
    playbackActive = true;
    return true;
}

// Returns the gap duration (ms) between alarm audio loops based on how long
// the alarm has been firing.  Escalates urgency over time:
//   0–60s  → 15s gap,  60–120s → 10s gap,  120s+ → 5s gap
unsigned long alarmLoopGapMs() {
    if (alarmTriggeredAtMs == 0) return 15000;
    unsigned long elapsed = millis() - alarmTriggeredAtMs;
    if (elapsed < 60000)  return 15000;
    if (elapsed < 120000) return 10000;
    return 5000;
}

void serviceFilePlayback() {
    if (!playbackActive || !playbackFileHandle) return;

    // If we're in a gap between loops, wait it out
    if (playbackInGap) {
        if (millis() - playbackGapStartMs < alarmLoopGapMs()) return;
        playbackInGap = false;
        playbackFileHandle.seek(0);
    }

    // I2S stays at 44100Hz. iOS resamples to 44100 before upload.
    // Simple mono PCM → stereo I2S conversion.
    // Buffer 200ms of audio per call to survive the main loop delay.
    static int16_t monoBuf[256];
    static int16_t stereoBuf[512];
    size_t bytesWritten;
    int16_t amplitude = (int16_t)((int32_t)32767 * speakerVolume / 100);
    int totalFramesWritten = 0;
    const int targetFrames = playbackInputRate / 5; // 200ms worth of frames

    while (totalFramesWritten < targetFrames) {
        size_t bytesRead = playbackFileHandle.read((uint8_t*)monoBuf, sizeof(monoBuf));
        if (bytesRead == 0) {
            if (playbackLoopEnabled && alarmFiring) {
                // Enter gap before replaying — silence the DMA buffers
                i2s_zero_dma_buffer(I2S_PORT);
                playbackInGap = true;
                playbackGapStartMs = millis();
                Serial.printf("[Alarm] Loop gap started (%lu ms)\n", alarmLoopGapMs());
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

        i2s_write(I2S_PORT, stereoBuf, samples * 2 * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        totalFramesWritten += samples;
    }
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

// Returns current day of week (0=Sun..6=Sat), or -1 if unknown
int getCurrentDayOfWeek() {
    if (hasAppTime && appTimeSyncDayOfWeek >= 0) {
        unsigned long elapsedSec = (millis() - appTimeSyncMillis) / 1000UL;
        uint32_t totalSec = appTimeSyncSecOfDay + elapsedSec;
        int dayRollover = (int)(totalSec / 86400UL);
        return (appTimeSyncDayOfWeek + dayRollover) % 7;
    }
    if (hasValidTime) {
        return timeClient.getDay(); // 0=Sun
    }
    return -1;
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
    alarmIsTriggered = false;
    alarmDeadlineMs = 0;
    notifyAlarmState(0);
    stopFilePlayback();
    stopSpeakerOutput();
    stopHaptics();
    alarmTriggeredAtMs = 0;
    lastAlarmHapticPulseMs = 0;
    lastAlarmFallbackToneMs = 0;

    if (alarmRepeatMask != 0) {
        // Re-arm for next matching day
        alarmIsSet = true;
        alarmIsTriggered = false;
        Serial.print("Alarm re-armed (repeat mask=0x");
        Serial.print(alarmRepeatMask, HEX);
        Serial.println(")");
    } else {
        alarmIsSet = false;
        Serial.println("Alarm stopped");
    }
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

// --- A2DP capture: stream reader callback (runs in BT task — must be fast) ---
void a2dpStreamReaderCallback(const uint8_t *data, uint32_t len) {
    if (!a2dpCaptureActive) return;

    // Input: stereo 16-bit PCM (L,R interleaved), 4 bytes per frame
    // Output: mono 16-bit PCM, 2 bytes per frame
    const int16_t *frames = (const int16_t *)data;
    int frameCount = len / 4;

    for (int i = 0; i < frameCount; i++) {
        int16_t left = frames[i * 2];
        int16_t right = frames[i * 2 + 1];
        int16_t mono = (int16_t)(((int32_t)left + (int32_t)right) / 2);

        // Skip leading silence (A2DP settling period)
        if (!a2dpCaptureGotAudio) {
            if (mono > -A2DP_SILENCE_THRESHOLD && mono < A2DP_SILENCE_THRESHOLD) continue;
            a2dpCaptureGotAudio = true;
        }

        size_t wp = a2dpCaptureWritePos;
        size_t nextWp = (wp + 2) % A2DP_CAPTURE_BUF_SIZE;
        if (nextWp == a2dpCaptureReadPos) { a2dpCaptureDroppedSamples++; continue; }

        a2dpCaptureBuf[wp]     = (uint8_t)(mono & 0xFF);
        a2dpCaptureBuf[wp + 1] = (uint8_t)((mono >> 8) & 0xFF);
        a2dpCaptureWritePos = nextWp;
    }
}

// Drain ring buffer to SPIFFS (called from loop)
void serviceA2dpCaptureDrain() {
    if (!a2dpCaptureFile) return;

    size_t rp = a2dpCaptureReadPos;
    size_t wp = a2dpCaptureWritePos;
    if (rp == wp) return;

    size_t available;
    if (wp > rp) {
        available = wp - rp;
    } else {
        available = A2DP_CAPTURE_BUF_SIZE - rp;
    }

    size_t written = a2dpCaptureFile.write(a2dpCaptureBuf + rp, available);
    a2dpCaptureBytesWritten += written;
    a2dpCaptureReadPos = (rp + written) % A2DP_CAPTURE_BUF_SIZE;
}

void startA2dpCapture() {
    if (a2dpCaptureActive) return;

    // Mute A2DP output FIRST — prevents write_audio race during transition.
    // Must happen before stopFilePlayback, which would otherwise unmute briefly.
    a2dpSink.muteOutput();

    // Stop file playback WITHOUT calling releaseI2SToA2DP (which would unmute).
    if (playbackFileHandle) playbackFileHandle.close();
    playbackActive = false;
    playbackLoopEnabled = false;
    playbackInGap = false;
    localAudioOwnsI2S = false;

    Serial.printf("[A2DP Capture] Free heap: %u, min ever: %u\n",
                  ESP.getFreeHeap(), ESP.getMinFreeHeap());

    if (a2dpCaptureFile) a2dpCaptureFile.close();
    a2dpCaptureFile = SPIFFS.open(uploadedVoiceFile, "w");
    if (!a2dpCaptureFile) {
        Serial.println("[A2DP Capture] SPIFFS open failed");
        a2dpSink.unmuteOutput();
        return;
    }

    a2dpCaptureWritePos = 0;
    a2dpCaptureReadPos = 0;
    a2dpCaptureBytesWritten = 0;
    a2dpCaptureGotAudio = false;
    a2dpCaptureDroppedSamples = 0;
    a2dpCaptureStartMs = millis();
    a2dpCaptureActive = true;

    uploadedVoiceReady = false;
    uploadedVoiceSampleRate = A2DP_CAPTURE_SAMPLE_RATE;

    Serial.println("[A2DP Capture] Started (speaker muted)");
}

void stopA2dpCapture() {
    if (!a2dpCaptureActive) return;
    a2dpCaptureActive = false;
    a2dpSink.unmuteOutput(); // unmute speaker

    // Drain remaining data
    serviceA2dpCaptureDrain();
    if (a2dpCaptureFile) {
        a2dpCaptureFile.flush();
        a2dpCaptureFile.close();
    }

    uploadedVoiceReady = a2dpCaptureBytesWritten > 0;
    uploadedVoiceReceivedBytes = a2dpCaptureBytesWritten;

    float durationSec = (float)a2dpCaptureBytesWritten / (2.0f * A2DP_CAPTURE_SAMPLE_RATE);
    Serial.println("=== A2DP CAPTURE COMPLETE ===");
    Serial.printf("  bytes: %u\n", a2dpCaptureBytesWritten);
    Serial.printf("  duration: %.1f sec\n", durationSec);
    Serial.printf("  dropped samples: %u\n", a2dpCaptureDroppedSamples);
    Serial.println("=============================");
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
        connParams.timeout = 200;  // 2 s supervision timeout — faster stale connection detection
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

            // Parse optional repeat mask: "HH:mm|delaySec|repeatMask"
            alarmRepeatMask = 0;
            int pipeCount = 0;
            size_t lastPipe = 0;
            for (size_t i = 0; i < value.size(); i++) {
                if (value[i] == '|') {
                    pipeCount++;
                    lastPipe = i;
                }
            }
            if (pipeCount >= 2 && lastPipe + 1 < value.size()) {
                alarmRepeatMask = (uint8_t)atoi(value.c_str() + lastPipe + 1);
            }

            Serial.print("Alarm set for: ");
            if (alarmHour < 10) Serial.print("0");
            Serial.print(alarmHour);
            Serial.print(":");
            if (alarmMinute < 10) Serial.print("0");
            Serial.print(alarmMinute);
            if (alarmRepeatMask != 0) {
                Serial.print(" repeat=0x");
                Serial.print(alarmRepeatMask, HEX);
            }
            Serial.println();
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

// RAM buffer to absorb BLE writes quickly — flush to SPIFFS when full
static uint8_t voiceUploadBuf[4096];
static size_t  voiceUploadBufLen = 0;

static void flushVoiceUploadBuf() {
    if (voiceUploadBufLen > 0 && uploadedVoiceHandle) {
        uploadedVoiceHandle.write(voiceUploadBuf, voiceUploadBufLen);
        voiceUploadBufLen = 0;
    }
}

class VoiceUploadCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
        std::string value = pChar->getValue();
        if (value.empty()) return;

        uint8_t cmd = (uint8_t)value[0];

        if (cmd == VOICE_UPLOAD_CMD_A2DP_START) {
            Serial.println("[VoiceUpload] A2DP capture start requested (deferred)");
            a2dpCaptureStartRequested = true;
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_A2DP_STOP) {
            Serial.println("[VoiceUpload] A2DP capture stop requested (deferred)");
            a2dpCaptureStopRequested = true;
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_BEGIN) {
            Serial.printf("[VoiceUpload] BEGIN len=%u\n", value.length());
            if (uploadedVoiceHandle) uploadedVoiceHandle.close();
            stopFilePlayback();
            uploadedVoiceExpectedBytes = 0;
            uploadedVoiceReceivedBytes = 0;
            uploadedVoiceReady = false;
            voiceUploadActive = false;
            voiceUploadBufLen = 0;

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
                Serial.println("[VoiceUpload] SPIFFS open failed");
                return;
            }
            Serial.printf("[VoiceUpload] expecting %u bytes @ %u Hz\n",
                          uploadedVoiceExpectedBytes, uploadedVoiceSampleRate);
            voiceUploadActive = true;
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_CHUNK) {
            if (!voiceUploadActive || !uploadedVoiceHandle) return;
            if (value.length() <= 1) return;

            size_t dataLen = value.length() - 1;
            const uint8_t *data = (const uint8_t*)&value[1];

            // Buffer in RAM — only flush to SPIFFS when buffer is full
            if (voiceUploadBufLen + dataLen > sizeof(voiceUploadBuf)) {
                flushVoiceUploadBuf();
            }
            memcpy(voiceUploadBuf + voiceUploadBufLen, data, dataLen);
            voiceUploadBufLen += dataLen;
            uploadedVoiceReceivedBytes += dataLen;

            if (uploadedVoiceReceivedBytes % 50000 < 100) {
                Serial.printf("[VoiceUpload] %u / %u bytes\n",
                              uploadedVoiceReceivedBytes, uploadedVoiceExpectedBytes);
            }
            return;
        }

        if (cmd == VOICE_UPLOAD_CMD_END) {
            Serial.printf("[VoiceUpload] END received, %u bytes buffered\n", uploadedVoiceReceivedBytes);
            flushVoiceUploadBuf();
            if (uploadedVoiceHandle) uploadedVoiceHandle.close();
            voiceUploadActive = false;
            uploadedVoiceReady = uploadedVoiceReceivedBytes > 0;

            // Verify file on disk
            File verifyFile = SPIFFS.open(uploadedVoiceFile, "r");
            size_t diskSize = verifyFile ? verifyFile.size() : 0;
            uint8_t diskHeader[16] = {0};
            size_t diskHeaderRead = 0;
            if (verifyFile) {
                diskHeaderRead = verifyFile.read(diskHeader, sizeof(diskHeader));
                verifyFile.close();
            }

            float durationSec = (uploadedVoiceSampleRate > 0)
                ? (float)uploadedVoiceReceivedBytes / (2.0f * uploadedVoiceSampleRate)
                : 0;

            Serial.println("=== VOICE UPLOAD COMPLETE ===");
            Serial.print("  received: "); Serial.print(uploadedVoiceReceivedBytes); Serial.println(" bytes");
            Serial.print("  expected: "); Serial.print(uploadedVoiceExpectedBytes); Serial.println(" bytes");
            Serial.print("  on disk:  "); Serial.print(diskSize); Serial.println(" bytes");
            Serial.print("  match: "); Serial.println(
                (uploadedVoiceReceivedBytes == uploadedVoiceExpectedBytes &&
                 diskSize == uploadedVoiceReceivedBytes) ? "YES" : "MISMATCH");
            Serial.print("  sampleRate: "); Serial.print(uploadedVoiceSampleRate); Serial.println(" Hz");
            Serial.print("  duration: "); Serial.print(durationSec, 1); Serial.println(" sec");
            if (diskHeaderRead > 0) {
                Serial.print("  first bytes on disk: ");
                for (size_t i = 0; i < diskHeaderRead; i++) {
                    if (diskHeader[i] < 0x10) Serial.print("0");
                    Serial.print(diskHeader[i], HEX);
                    Serial.print(" ");
                }
                Serial.println();
            }
            Serial.println("=============================");
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

        // Parse optional day-of-week after pipe: "HH:MM:SS|dow"
        size_t pipePos = value.find('|');
        if (pipePos != std::string::npos && pipePos + 1 < value.size()) {
            int dow = atoi(value.c_str() + pipePos + 1);
            if (dow >= 0 && dow <= 6) {
                appTimeSyncDayOfWeek = dow;
            }
        }

        int hh = (int)(secOfDay / 3600UL);
        int mm = (int)((secOfDay % 3600UL) / 60UL);
        int ss = (int)(secOfDay % 60UL);
        Serial.printf("App time synced: %02d:%02d:%02d dow=%d\n", hh, mm, ss, appTimeSyncDayOfWeek);
    }
};

void setupBle() {
    BLEDevice::init(bleName);
    BLEDevice::setMTU(517);  // Allow large BLE writes (voice upload packets up to 512 bytes)
    BLEServer *server = BLEDevice::createServer();
    server->setCallbacks(new MyServerCallbacks());

    BLEService *service = server->createService(BLEUUID(SERVICE_UUID), 60);

    // Voice upload registered FIRST to ensure it gets handles before the limit
    BLECharacteristic *voiceUploadChar = service->createCharacteristic(
        VOICE_UPLOAD_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    voiceUploadChar->setAccessPermissions(ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE);
    voiceUploadChar->setCallbacks(new VoiceUploadCallback());
    Serial.printf("VoiceUpload char registered: handle=%u\n", voiceUploadChar->getHandle());

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
    a2dpSink.set_raw_stream_reader(a2dpStreamReaderCallback); // capture PRE-volume audio; I2S output continues normally
    a2dpSink.set_on_connection_state_changed(onA2dpConnectionStateChanged);
    a2dpSink.set_on_audio_state_changed(onA2dpAudioStateChanged);
    a2dpSink.set_reconnect_delay(1500);

    // Clear stale bonding keys — prevents "Pairing Unsuccessful" after
    // the phone forgets the device. Fresh pairing on each boot.
    int bondedCount = esp_bt_gap_get_bond_device_num();
    if (bondedCount > 0) {
        esp_bd_addr_t *bondedDevices = (esp_bd_addr_t *)malloc(bondedCount * sizeof(esp_bd_addr_t));
        if (bondedDevices) {
            esp_bt_gap_get_bond_device_list(&bondedCount, bondedDevices);
            for (int i = 0; i < bondedCount; i++) {
                esp_bt_gap_remove_bond_device(bondedDevices[i]);
            }
            free(bondedDevices);
            Serial.printf("[BT] Cleared %d stale bond(s)\n", bondedCount);
        }
    }

    a2dpSink.start(a2dpName, true);
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

    // Start at low CPU since nothing is active yet
    setCpuFrequencyMhz(80);
    cpuIsHighSpeed = false;
    Serial.println("[Power] CPU -> 80MHz (idle start)");
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
                // For repeating alarms, check day-of-week matches
                if (alarmRepeatMask != 0) {
                    int dow = getCurrentDayOfWeek();
                    if (dow >= 0 && (alarmRepeatMask & (1 << dow))) {
                        shouldTriggerAlarm = true;
                    }
                    // If we can't determine day, skip time-based trigger
                    // (deadline fallback still works)
                } else {
                    shouldTriggerAlarm = true;
                }
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

    // Handle deferred A2DP capture start/stop (from BLE callbacks)
    if (a2dpCaptureStartRequested) {
        a2dpCaptureStartRequested = false;
        startA2dpCapture();
    }
    if (a2dpCaptureStopRequested) {
        a2dpCaptureStopRequested = false;
        stopA2dpCapture();
    }

    // Drain A2DP capture buffer to SPIFFS
    if (a2dpCaptureActive) {
        serviceA2dpCaptureDrain();
        if (millis() - a2dpCaptureStartMs > A2DP_CAPTURE_TIMEOUT_MS) {
            Serial.println("[A2DP Capture] Timeout -- auto-stopping");
            stopA2dpCapture();
        }
    }

    if (!a2dpConnected) {
        unsigned long now = millis();
        if (now - lastA2dpConnectableRefreshMs > 5000) {
            a2dpSink.set_connectable(true);
            a2dpSink.set_discoverability(ESP_BT_GENERAL_DISCOVERABLE);
            lastA2dpConnectableRefreshMs = now;
        }
    }

    servicePowerManagement();

    // Adaptive delay: fast when actively playing/capturing, slow when fully idle.
    if (playbackActive || customHapticActive || a2dpCaptureActive) {
        delay(20);
    } else if (alarmIsSet || alarmFiring || voiceUploadActive || a2dpConnected) {
        delay(100);
    } else {
        delay(500);
    }
}
