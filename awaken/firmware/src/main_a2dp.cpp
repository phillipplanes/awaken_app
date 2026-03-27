#include <Arduino.h>
#include <BluetoothA2DP.h>
#include <driver/i2s.h>
#include <esp_system.h>

#if defined(TARGET_BOARD_ADAFRUIT_FEATHER_ESP32_V2)
static constexpr const char *BOARD_NAME = "Adafruit Feather ESP32 V2";
#elif defined(TARGET_BOARD_ESP32_WROOM_32E)
static constexpr const char *BOARD_NAME = "ESP32-WROOM-32E";
#else
static constexpr const char *BOARD_NAME = "Original ESP32";
#endif

// Feather ESP32 V2 and generic original ESP32 modules both use the same wiring here.
static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int I2S_BCLK_PIN = 26;
static constexpr int I2S_LRCLK_PIN = 27;
static constexpr int I2S_DOUT_PIN = 25; // ESP32 -> MAX98357A DIN
static constexpr const char *DEVICE_NAME_PREFIX = "AWAKEN-audio";
static constexpr uint8_t A2DP_STARTUP_VOLUME = 55; // 0-127 inside library
char deviceName[48] = {0};

BluetoothA2DPSinkQueued a2dpSink;

void initDeviceName() {
    uint8_t btMac[6] = {0};
    esp_read_mac(btMac, ESP_MAC_BT);
    snprintf(deviceName, sizeof(deviceName), "%s", DEVICE_NAME_PREFIX);
}

void setup() {
    Serial.begin(115200);
    delay(250);
    initDeviceName();
    Serial.println();
    Serial.print("AWAKEN A2DP sink (");
    Serial.print(BOARD_NAME);
    Serial.println(" + MAX98357A)");
    Serial.println("Audio out: I2S BCLK=26 LRCLK=27 DOUT=25");

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

    // A separate I2S writer task and bigger ringbuffer reduce underflows/clicks.
    a2dpSink.set_i2s_ringbuffer_size(64 * 1024);
    a2dpSink.set_i2s_ringbuffer_prefetch_percent(70);
    a2dpSink.set_i2s_write_size_upto(1024);
    a2dpSink.set_mono_downmix(true); // single DAC channel path
    a2dpSink.set_volume(A2DP_STARTUP_VOLUME);
    a2dpSink.set_i2s_port(I2S_PORT);
    a2dpSink.set_i2s_config(i2sConfig);
    a2dpSink.set_pin_config(pinConfig);
    a2dpSink.start(deviceName, false); // Do not auto-reconnect on boot

    i2s_zero_dma_buffer(I2S_PORT);
    Serial.print("Bluetooth device name: ");
    Serial.println(deviceName);
    Serial.print("A2DP startup volume (0-127): ");
    Serial.println(A2DP_STARTUP_VOLUME);
    Serial.println("Pair from phone/computer and play audio.");
}

void loop() {
    delay(1000);
}
