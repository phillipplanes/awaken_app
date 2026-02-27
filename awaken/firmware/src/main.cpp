/**
 * @file main.cpp
 * @brief Firmware for an ESP32-S3 TFT Feather based alarm clock with haptic feedback.
 */
#include <WiFi.h>
#include <NTPClient.h>
#include <WiFiUdp.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <Fonts/FreeSansBold24pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>
#include <Fonts/FreeSans12pt7b.h>
#include <Fonts/FreeSans9pt7b.h>
#include <Wire.h>
#include <Adafruit_DRV2605.h>
#include <driver/i2s.h>
#include <math.h>
#include <SPIFFS.h>

// --- Display (ESP32-S3 TFT Feather built-in 240x135 ST7789) ---
#define TFT_CS        7
#define TFT_DC       39
#define TFT_RST      40
#define TFT_MOSI     35
#define TFT_SCLK     36
#define TFT_BACKLIGHT 45

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_MOSI, TFT_SCLK, TFT_RST);

// --- Haptic Motor (DRV2605L via STEMMA QT I2C) ---
Adafruit_DRV2605 drv;
uint8_t vibrationIntensity = 64;
uint8_t wakeEffectId = 1; // Default: Strong Click

// --- Audio (MAX98357A I2S amp) ---
#define I2S_BCLK   5
#define I2S_LRC    6
#define I2S_DOUT   9
#define I2S_PORT   I2S_NUM_0
#define SAMPLE_RATE 8000
#define SINE_TABLE_SIZE 256

int16_t sineTable[SINE_TABLE_SIZE];
bool i2sInitialized = false;

// --- Wi-Fi & Time ---
const char* ssid = "BOSCO";
const char* password = "Yadagjb0ys!";
WiFiUDP ntpUDP;
NTPClient timeClient(ntpUDP, "pool.ntp.org", -18000);

// --- BLE UUIDs ---
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

#define STATUS_DRV2605L  0x01
#define STATUS_MAX98357  0x02

#define SPEAKER_CMD_STOP            0x00
#define SPEAKER_CMD_TEST_TONE       0x01
#define SPEAKER_CMD_ALARM_SOUND_OFF 0x02
#define SPEAKER_CMD_ALARM_SOUND_ON  0x03
#define SPEAKER_CMD_PLAY_UPLOADED   0x04

#define VOICE_UPLOAD_CMD_BEGIN      0x01
#define VOICE_UPLOAD_CMD_CHUNK      0x02
#define VOICE_UPLOAD_CMD_END        0x03

BLECharacteristic *pAlarmCharacteristic;
BLECharacteristic *pIntensityCharacteristic;
BLECharacteristic *pEffectCharacteristic;
BLECharacteristic *pStatusCharacteristic;
BLECharacteristic *pWakeEffectChar;
BLECharacteristic *pAlarmStateChar;
BLECharacteristic *pAlarmControlChar;
BLECharacteristic *pSpeakerVolumeChar;
BLECharacteristic *pSpeakerControlChar;
BLECharacteristic *pRingtoneSelectChar;
BLECharacteristic *pVoiceUploadChar;

bool deviceConnected = false;
uint8_t moduleStatus = 0;
bool alarmSoundEnabled = true;
// speakerVolume 0-100 scales I2S sample amplitude (0 = silent)
uint8_t speakerVolume = 60;

// --- Ringtone Selection ---
uint8_t selectedRingtone = 0; // 0, 1, or 2
const char* ringtoneFiles[] = {"/ringtone0.pcm", "/ringtone1.pcm", "/ringtone2.pcm"};
const char* uploadedVoiceFile = "/voice_alarm.pcm";
bool uploadedVoiceReady = false;
bool voiceUploadActive = false;
uint32_t uploadedVoiceExpectedBytes = 0;
uint32_t uploadedVoiceReceivedBytes = 0;
File uploadedVoiceHandle;

// --- Alarm State ---
long alarmHour = -1;
long alarmMinute = -1;
bool alarmIsSet = false;
bool alarmIsTriggered = false;
bool alarmFiring = false;
unsigned long alarmStartTime = 0;
unsigned long lastAlarmPulse = 0;
bool wifiConnected = false;

// --- Display State Tracking ---
uint8_t displayMode = 0;       // 0=normal, 1=alarm
uint8_t prevDisplayMode = 255; // Force initial clear
String prevTimeStr = "";
String prevStatusStr = "";
bool flashToggle = false;

// Forward declarations
void stopAlarm();
void snoozeAlarm();
void notifyAlarmState(uint8_t state);
void playSpeakerTone(uint16_t frequencyHz, uint16_t durationMs);
void playAlarmAudioFromFile(const char* filePath);
void stopSpeakerOutput();
void runSpeakerSelfTest();
void initI2SAudio();

// --- BLE Server Callbacks ---
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { deviceConnected = true; }
    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        pServer->getAdvertising()->start();
    }
};

// --- BLE Characteristic Callbacks ---

class AlarmCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() == 5 && value[2] == ':') {
            String timeStr = String(value.c_str());
            long newHour = timeStr.substring(0, 2).toInt();
            long newMinute = timeStr.substring(3, 5).toInt();
            if (newHour >= 0 && newHour <= 23 && newMinute >= 0 && newMinute <= 59) {
                alarmHour = newHour;
                alarmMinute = newMinute;
                alarmIsSet = true;
                alarmIsTriggered = false;
                Serial.print("Alarm set for: ");
                Serial.print(alarmHour);
                Serial.print(":");
                Serial.println(alarmMinute);
            }
        }
    }
};

class IntensityCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        if (!(moduleStatus & STATUS_DRV2605L)) return;
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t intensity = (uint8_t)value[0];
            vibrationIntensity = intensity;
            if (intensity == 0) {
                drv.setMode(DRV2605_MODE_INTTRIG);
                delay(10);
                drv.setRealtimeValue(0);
                Serial.println("Motor stopped");
            } else {
                drv.setMode(DRV2605_MODE_REALTIME);
                delay(10);
                drv.setRealtimeValue(intensity);
                Serial.print("Vibration intensity: ");
                Serial.println(intensity);
            }
        }
    }
};

class EffectCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        if (!(moduleStatus & STATUS_DRV2605L)) return;
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t effectId = (uint8_t)value[0];
            if (effectId >= 1 && effectId <= 123) {
                drv.setMode(DRV2605_MODE_INTTRIG);
                delay(10);
                drv.setWaveform(0, effectId);
                drv.setWaveform(1, 0);
                drv.go();
                delay(10);
                Serial.print("Playing effect: ");
                Serial.println(effectId);
            }
        }
    }
};

class WakeEffectCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t effectId = (uint8_t)value[0];
            if (effectId >= 1 && effectId <= 123) {
                wakeEffectId = effectId;
                Serial.print("Wake effect set to: ");
                Serial.println(effectId);
            }
        }
    }
};

class AlarmControlCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t cmd = (uint8_t)value[0];
            if (cmd == 0) {
                stopAlarm();
            } else if (cmd == 1) {
                snoozeAlarm();
            }
        }
    }
};

class SpeakerVolumeCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t requested = (uint8_t)value[0];
            if (requested > 100) requested = 100;
            speakerVolume = requested;
            if (speakerVolume == 0) stopSpeakerOutput();
            Serial.print("Speaker volume: ");
            Serial.print(speakerVolume);
            Serial.println("%");
        }
    }
};

class SpeakerControlCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() < 1) return;

        uint8_t cmd = (uint8_t)value[0];
        if (cmd == SPEAKER_CMD_STOP) {
            stopSpeakerOutput();
        } else if (cmd == SPEAKER_CMD_TEST_TONE) {
            uint16_t freq = 880; // default
            if (value.length() >= 3) {
                freq = (uint16_t)((uint8_t)value[1]) | ((uint16_t)((uint8_t)value[2]) << 8);
                if (freq < 100) freq = 100;
                if (freq > 5000) freq = 5000;
            }
            Serial.print("Test tone: ");
            Serial.print(freq);
            Serial.println("Hz");
            playSpeakerTone(freq, 250);
        } else if (cmd == SPEAKER_CMD_ALARM_SOUND_OFF) {
            alarmSoundEnabled = false;
            stopSpeakerOutput();
            Serial.println("Alarm sound disabled");
        } else if (cmd == SPEAKER_CMD_ALARM_SOUND_ON) {
            alarmSoundEnabled = true;
            Serial.println("Alarm sound enabled");
        } else if (cmd == SPEAKER_CMD_PLAY_UPLOADED) {
            if (uploadedVoiceReady) {
                Serial.println("Playing uploaded voice clip");
                playAlarmAudioFromFile(uploadedVoiceFile);
            } else {
                Serial.println("No uploaded voice clip available");
            }
        }
    }
};

class RingtoneSelectCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() >= 1) {
            uint8_t idx = (uint8_t)value[0];
            if (idx <= 2) {
                selectedRingtone = idx;
                Serial.print("Ringtone selected: ");
                Serial.println(idx);
            }
        }
    }
};

class VoiceUploadCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) {
        std::string value = pChar->getValue();
        if (value.length() < 1) return;

        uint8_t cmd = (uint8_t)value[0];

        if (cmd == VOICE_UPLOAD_CMD_BEGIN) {
            if (uploadedVoiceHandle) uploadedVoiceHandle.close();
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

            uploadedVoiceHandle = SPIFFS.open(uploadedVoiceFile, "w");
            if (!uploadedVoiceHandle) {
                Serial.println("Voice upload start failed: could not open file");
                return;
            }

            voiceUploadActive = true;
            Serial.print("Voice upload started, expected bytes=");
            Serial.println(uploadedVoiceExpectedBytes);
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

            Serial.print("Voice upload finished, received bytes=");
            Serial.println(uploadedVoiceReceivedBytes);
            if (uploadedVoiceExpectedBytes > 0 && uploadedVoiceExpectedBytes != uploadedVoiceReceivedBytes) {
                Serial.print("Warning: expected bytes=");
                Serial.print(uploadedVoiceExpectedBytes);
                Serial.print(" received=");
                Serial.println(uploadedVoiceReceivedBytes);
            }
        }
    }
};

// --- Alarm Control Functions ---

void notifyAlarmState(uint8_t state) {
    if (deviceConnected && pAlarmStateChar) {
        pAlarmStateChar->setValue(&state, 1);
        pAlarmStateChar->notify();
    }
}

void stopAlarm() {
    alarmFiring = false;
    alarmIsSet = false;
    if (moduleStatus & STATUS_DRV2605L) {
        drv.setMode(DRV2605_MODE_INTTRIG);
        delay(10);
        drv.setRealtimeValue(0);
    }
    notifyAlarmState(0);
    stopSpeakerOutput();
    Serial.println("Alarm stopped");
}

void snoozeAlarm() {
    alarmFiring = false;
    if (moduleStatus & STATUS_DRV2605L) {
        drv.setMode(DRV2605_MODE_INTTRIG);
        delay(10);
        drv.setRealtimeValue(0);
    }

    alarmMinute += 5;
    if (alarmMinute >= 60) {
        alarmMinute -= 60;
        alarmHour = (alarmHour + 1) % 24;
    }
    alarmIsTriggered = false;
    notifyAlarmState(0);
    stopSpeakerOutput();
    Serial.print("Snoozed. Next alarm: ");
    Serial.print(alarmHour);
    Serial.print(":");
    Serial.println(alarmMinute);
}

void triggerAlarm() {
    Serial.println("ALARM! WAKE UP!");
    alarmIsTriggered = true;
    alarmFiring = true;
    alarmStartTime = millis();
    lastAlarmPulse = 0; // Force immediate first pulse
    notifyAlarmState(1);
}

// --- Display ---

// Returns x cursor for horizontally centering text on 240px display.
// Must be called AFTER setFont() and setTextSize().
int16_t centerTextX(const char* text) {
    int16_t x1, y1;
    uint16_t w, h;
    tft.getTextBounds(text, 0, 0, &x1, &y1, &w, &h);
    return (240 - w) / 2;
}

// Draw a small bell icon at (x, y). About 16px wide, 18px tall.
void drawBell(int16_t x, int16_t y, uint16_t color) {
    // Dome (top circle)
    tft.fillCircle(x + 8, y + 4, 4, color);
    // Body (trapezoid approximated with triangle)
    tft.fillTriangle(x + 2, y + 14, x + 14, y + 14, x + 8, y + 3, color);
    // Rim (bottom bar)
    tft.fillRect(x, y + 14, 16, 3, color);
    // Clapper (small circle at bottom center)
    tft.fillCircle(x + 8, y + 19, 2, color);
}

void updateDisplay() {
    tft.setTextWrap(false);

    uint8_t currentMode = alarmFiring ? 1 : 0;

    // Clear screen on mode change
    if (currentMode != prevDisplayMode) {
        tft.fillScreen(ST77XX_BLACK);
        prevTimeStr = "";
        prevStatusStr = "";
        prevDisplayMode = currentMode;
    }

    if (alarmFiring) {
        // --- Alarm Mode: flashing display ---
        flashToggle = !flashToggle;

        if (flashToggle) {
            tft.fillScreen(ST77XX_RED);
            tft.setTextColor(ST77XX_WHITE);
        } else {
            tft.fillScreen(ST77XX_BLACK);
            tft.setTextColor(ST77XX_RED);
        }

        // "ALARM!" in large bold font, centered
        tft.setFont(&FreeSansBold24pt7b);
        tft.setTextSize(1);
        const char* alarmText = "ALARM!";
        int16_t ax = centerTextX(alarmText);
        tft.setCursor(ax, 55);
        tft.print(alarmText);

        // "WAKE UP" below, centered
        tft.setFont(&FreeSansBold18pt7b);
        const char* wakeText = "WAKE UP";
        int16_t wx = centerTextX(wakeText);
        tft.setCursor(wx, 105);
        tft.print(wakeText);

    } else {
        // --- Normal Mode: time + status ---

        // Build current time string
        String timeStr;
        if (wifiConnected) {
            timeStr = timeClient.getFormattedTime().substring(0, 5);
        } else {
            timeStr = "--:--";
        }

        // Only redraw time when it changes
        if (timeStr != prevTimeStr) {
            // Clear time region (top portion)
            tft.fillRect(0, 0, 240, 80, ST77XX_BLACK);

            tft.setFont(&FreeSansBold24pt7b);
            tft.setTextSize(1);
            tft.setTextColor(ST77XX_WHITE);
            int16_t tx = centerTextX(timeStr.c_str());
            tft.setCursor(tx, 55);
            tft.print(timeStr);

            prevTimeStr = timeStr;
        }

        // Build status string
        String statusStr;
        uint16_t statusColor;
        bool showBell = false;

        if (alarmIsSet) {
            char buf[12];
            snprintf(buf, sizeof(buf), "%02ld:%02ld  R%d", alarmHour, alarmMinute, selectedRingtone + 1);
            statusStr = String(buf);
            statusColor = ST77XX_YELLOW;
            showBell = true;
        } else if (!wifiConnected) {
            statusStr = "No WiFi";
            statusColor = ST77XX_RED;
        } else {
            statusStr = "No alarm";
            statusColor = 0x8410; // mid-grey
        }

        // Only redraw status when it changes
        if (statusStr != prevStatusStr) {
            // Clear status region (bottom portion)
            tft.fillRect(0, 85, 240, 50, ST77XX_BLACK);

            tft.setFont(&FreeSans12pt7b);
            tft.setTextSize(1);
            tft.setTextColor(statusColor);

            if (showBell) {
                // Measure text to center bell + text together
                int16_t x1, y1;
                uint16_t tw, th;
                tft.getTextBounds(statusStr.c_str(), 0, 0, &x1, &y1, &tw, &th);
                int16_t totalW = 20 + tw; // 16px bell + 4px gap + text
                int16_t startX = (240 - totalW) / 2;
                drawBell(startX, 93, ST77XX_YELLOW);
                tft.setCursor(startX + 20, 112);
            } else {
                int16_t sx = centerTextX(statusStr.c_str());
                tft.setCursor(sx, 112);
            }
            tft.print(statusStr);

            prevStatusStr = statusStr;
        }
    }
}

// --- Wi-Fi ---

void connectToWiFi() {
    Serial.print("Connecting to ");
    Serial.println(ssid);
    WiFi.begin(ssid, password);

    int attempts = 0;
    const int maxAttempts = 10;

    while (WiFi.status() != WL_CONNECTED && attempts < maxAttempts) {
        delay(1000);
        attempts++;
        Serial.print("WiFi status: ");
        Serial.println(WiFi.status());

        tft.fillScreen(ST77XX_BLACK);
        tft.setFont(&FreeSans12pt7b);
        tft.setTextSize(1);
        tft.setTextColor(ST77XX_WHITE);

        const char* connText = "Connecting...";
        int16_t cx = centerTextX(connText);
        tft.setCursor(cx, 55);
        tft.print(connText);

        char progBuf[8];
        snprintf(progBuf, sizeof(progBuf), "%d/%d", attempts, maxAttempts);
        int16_t px = centerTextX(progBuf);
        tft.setCursor(px, 90);
        tft.setTextColor(0x8410); // grey
        tft.print(progBuf);
    }

    if (WiFi.status() == WL_CONNECTED) {
        wifiConnected = true;
        Serial.println("WiFi connected");
    } else {
        wifiConnected = false;
        WiFi.disconnect(true);
        Serial.println("WiFi failed — running without clock");
    }
}

// --- Audio (MAX98357A via I2S) ---

void initI2SAudio() {
    // Pre-compute sine lookup table
    for (int i = 0; i < SINE_TABLE_SIZE; i++) {
        sineTable[i] = (int16_t)(sinf(2.0f * M_PI * i / SINE_TABLE_SIZE) * 32767);
    }

    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 64,
        .use_apll = false,
        .tx_desc_auto_clear = true
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = I2S_BCLK,
        .ws_io_num = I2S_LRC,
        .data_out_num = I2S_DOUT,
        .data_in_num = I2S_PIN_NO_CHANGE
    };

    if (i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL) == ESP_OK &&
        i2s_set_pin(I2S_PORT, &pin_config) == ESP_OK) {
        i2sInitialized = true;
        i2s_zero_dma_buffer(I2S_PORT);
        moduleStatus |= STATUS_MAX98357;
        Serial.println("MAX98357A I2S audio ready");
    } else {
        Serial.println("I2S init failed");
    }
}

void stopSpeakerOutput() {
    if (!i2sInitialized) return;
    i2s_zero_dma_buffer(I2S_PORT);
}

void playSpeakerTone(uint16_t frequencyHz, uint16_t durationMs) {
    if (!i2sInitialized) return;
    if (speakerVolume == 0 || frequencyHz == 0 || durationMs == 0) return;

    int totalSamples = (SAMPLE_RATE * durationMs) / 1000;
    float phaseInc = (float)frequencyHz * SINE_TABLE_SIZE / SAMPLE_RATE;
    float phase = 0;
    int16_t amplitude = (int16_t)((int32_t)32767 * speakerVolume / 100);

    // Stereo interleaved buffer: [L, R, L, R, ...]
    int16_t buf[512]; // 256 stereo frames
    size_t bytesWritten;
    int written = 0;

    while (written < totalSamples) {
        int chunk = totalSamples - written;
        if (chunk > 256) chunk = 256;
        for (int i = 0; i < chunk; i++) {
            int idx = (int)phase % SINE_TABLE_SIZE;
            int16_t sample = (int16_t)((int32_t)sineTable[idx] * amplitude / 32767);
            buf[i * 2]     = sample; // Left
            buf[i * 2 + 1] = sample; // Right
            phase += phaseInc;
            if (phase >= SINE_TABLE_SIZE) phase -= SINE_TABLE_SIZE;
        }
        i2s_write(I2S_PORT, buf, chunk * 2 * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        written += chunk;
    }
}

void runSpeakerSelfTest() {
    Serial.println("Playing I2S test tone");
    playSpeakerTone(880, 250);
}

void playAlarmAudioFromFile(const char* filePath) {
    Serial.print("playAlarmAudioFromFile: i2s=");
    Serial.print(i2sInitialized);
    Serial.print(" vol=");
    Serial.print(speakerVolume);
    Serial.print(" file=");
    Serial.println(filePath);

    if (!i2sInitialized || speakerVolume == 0) return;

    File f = SPIFFS.open(filePath, "r");
    if (!f) {
        Serial.print("Failed to open audio file: ");
        Serial.println(filePath);
        return;
    }
    Serial.print("File opened, size=");
    Serial.println(f.size());

    int16_t monoBuf[256];
    int16_t stereoBuf[512];
    size_t bytesWritten;
    int16_t amplitude = (int16_t)((int32_t)32767 * speakerVolume / 100);
    unsigned long lastHapticPulse = 0;

    bool loopForAlarm = alarmFiring;
    bool keepPlaying = true;

    while (keepPlaying) {
        f.seek(0);
        while (true) {
            if (loopForAlarm && !alarmFiring) break;

            if (loopForAlarm) {
                // Re-trigger haptic effect every 2.5 seconds
                unsigned long now = millis();
                if (now - lastHapticPulse > 2500) {
                    if (moduleStatus & STATUS_DRV2605L) {
                        drv.setMode(DRV2605_MODE_INTTRIG);
                        delay(10);
                        drv.setWaveform(0, wakeEffectId);
                        drv.setWaveform(1, 0);
                        drv.go();
                        delay(10);
                    }
                    lastHapticPulse = now;
                }
            }

            size_t bytesRead = f.read((uint8_t*)monoBuf, sizeof(monoBuf));
            if (bytesRead == 0) break;

            int samples = bytesRead / sizeof(int16_t);
            for (int i = 0; i < samples; i++) {
                int16_t scaled = (int16_t)((int32_t)monoBuf[i] * amplitude / 32767);
                stereoBuf[i * 2]     = scaled; // Left
                stereoBuf[i * 2 + 1] = scaled; // Right
            }
            i2s_write(I2S_PORT, stereoBuf, samples * 2 * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        }

        keepPlaying = loopForAlarm && alarmFiring;
    }

    f.close();
    stopSpeakerOutput();
}

// --- Setup ---

void setup() {
    Serial.begin(115200);

    // --- Display ---
    pinMode(TFT_BACKLIGHT, OUTPUT);
    digitalWrite(TFT_BACKLIGHT, HIGH);
    tft.init(135, 240);
    tft.setRotation(3); // Landscape, USB connector on left
    tft.fillScreen(ST77XX_BLACK);
    tft.setFont(&FreeSansBold18pt7b);
    tft.setTextSize(1);
    tft.setTextColor(0x9DFF); // soft blue (RGB565)
    const char* splashText = "Awaken";
    int16_t sx = centerTextX(splashText);
    tft.setCursor(sx, 80);
    tft.print(splashText);

    // --- DRV2605L (via STEMMA QT, I2C SDA=42 SCL=41) ---
    Serial.println("Initializing DRV2605L...");
    if (drv.begin()) {
        drv.selectLibrary(1);
        drv.setMode(DRV2605_MODE_INTTRIG);
        drv.setWaveform(0, 1); // Strong Click
        drv.setWaveform(1, 0);
        drv.go();
        moduleStatus |= STATUS_DRV2605L;
        Serial.println("DRV2605L ready");
    } else {
        Serial.println("DRV2605L not found — continuing without haptics");
    }

    // --- MAX98357A I2S Audio ---
    initI2SAudio();

    // --- SPIFFS (ringtone audio files) ---
    if (!SPIFFS.begin(true)) {
        Serial.println("SPIFFS mount failed");
    } else {
        Serial.println("SPIFFS mounted");
    }

    connectToWiFi();

    if (wifiConnected) {
        timeClient.begin();
    }

    // --- BLE ---
    BLEDevice::init("MyAwakenAlarm");
    BLEServer *pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 30);

    pAlarmCharacteristic = pService->createCharacteristic(
        ALARM_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_WRITE);
    pAlarmCharacteristic->setCallbacks(new AlarmCallback());

    pIntensityCharacteristic = pService->createCharacteristic(
        INTENSITY_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pIntensityCharacteristic->setCallbacks(new IntensityCallback());

    pEffectCharacteristic = pService->createCharacteristic(
        EFFECT_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pEffectCharacteristic->setCallbacks(new EffectCallback());

    pStatusCharacteristic = pService->createCharacteristic(
        STATUS_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
    pStatusCharacteristic->setValue(&moduleStatus, 1);

    pWakeEffectChar = pService->createCharacteristic(
        WAKE_EFFECT_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pWakeEffectChar->setCallbacks(new WakeEffectCallback());

    pAlarmStateChar = pService->createCharacteristic(
        ALARM_STATE_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    pAlarmStateChar->addDescriptor(new BLE2902());
    static uint8_t initialState = 0;
    pAlarmStateChar->setValue(&initialState, 1);

    pAlarmControlChar = pService->createCharacteristic(
        ALARM_CONTROL_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pAlarmControlChar->setCallbacks(new AlarmControlCallback());

    pSpeakerVolumeChar = pService->createCharacteristic(
        SPEAKER_VOLUME_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
    pSpeakerVolumeChar->setCallbacks(new SpeakerVolumeCallback());
    pSpeakerVolumeChar->setValue(&speakerVolume, 1);

    pSpeakerControlChar = pService->createCharacteristic(
        SPEAKER_CONTROL_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pSpeakerControlChar->setCallbacks(new SpeakerControlCallback());

    pRingtoneSelectChar = pService->createCharacteristic(
        RINGTONE_SELECT_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
    pRingtoneSelectChar->setCallbacks(new RingtoneSelectCallback());
    pRingtoneSelectChar->setValue(&selectedRingtone, 1);

    pVoiceUploadChar = pService->createCharacteristic(
        VOICE_UPLOAD_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pVoiceUploadChar->setCallbacks(new VoiceUploadCallback());

    pService->start();

    BLEAdvertising *pAdvertising = pServer->getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->start();
    Serial.println("BLE Server started. Waiting for a client to connect...");

    tft.fillScreen(ST77XX_BLACK);
}

// --- Main Loop ---

void loop() {
    if (wifiConnected) {
        timeClient.update();

        if (alarmIsSet && !alarmIsTriggered) {
            if (timeClient.getHours() == alarmHour && timeClient.getMinutes() == alarmMinute) {
                triggerAlarm();
            }
        }
    }

    // Alarm firing: play audio + haptics (playAlarmAudioFromFile blocks & handles both)
    if (alarmFiring) {
        if (alarmSoundEnabled) {
            if (uploadedVoiceReady) {
                playAlarmAudioFromFile(uploadedVoiceFile);
            } else {
                playAlarmAudioFromFile(ringtoneFiles[selectedRingtone]);
            }
        } else {
            // Sound disabled — still pulse haptics
            unsigned long now = millis();
            if (now - lastAlarmPulse > 2500) {
                if (moduleStatus & STATUS_DRV2605L) {
                    drv.setMode(DRV2605_MODE_INTTRIG);
                    delay(10);
                    drv.setWaveform(0, wakeEffectId);
                    drv.setWaveform(1, 0);
                    drv.go();
                    delay(10);
                }
                lastAlarmPulse = now;
            }
        }
    }

    updateDisplay();
    delay(1000);
}
