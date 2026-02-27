import Foundation
import Combine
import CoreBluetooth
import AVFAudio

// BLE UUIDs — must match ESP32 firmware
let ALARM_SERVICE_UUID = CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")
let ALARM_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a8")
let INTENSITY_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a9")
let EFFECT_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26aa")
let STATUS_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26ab")
let WAKE_EFFECT_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26ac")
let ALARM_STATE_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26ad")
let ALARM_CONTROL_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26ae")
let SPEAKER_VOLUME_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26b0")
let SPEAKER_CONTROL_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26b1")
let VOICE_UPLOAD_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26b3")

class BluetoothViewModel: NSObject, ObservableObject {

    // MARK: - Private
    private var centralManager: CBCentralManager!
    private var alarmClockPeripheral: CBPeripheral?
    private var alarmCharacteristic: CBCharacteristic?
    private var intensityCharacteristic: CBCharacteristic?
    private var effectCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var wakeEffectCharacteristic: CBCharacteristic?
    private var alarmStateCharacteristic: CBCharacteristic?
    private var alarmControlCharacteristic: CBCharacteristic?
    private var speakerVolumeCharacteristic: CBCharacteristic?
    private var speakerControlCharacteristic: CBCharacteristic?
    private var voiceUploadCharacteristic: CBCharacteristic?
    private var voiceUploadPackets: [Data] = []
    private var voiceUploadPacketIndex: Int = 0
    private var voiceUploadCompletion: ((Bool) -> Void)?
    private var audioRouteObserver: NSObjectProtocol?
    private var pendingAlarmDisplayTime: String?
    private var userDisconnectRequested: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3

    // MARK: - Published
    @Published var connectionStatus: String = "Disconnected"
    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var vibrationIntensity: Double = 50
    @Published var hasDRV2605L: Bool = false
    @Published var hasSpeakerAmp: Bool = false
    @Published var alarmFiring: Bool = false
    @Published var selectedWakeEffect: UInt8 = 1
    @Published var speakerVolume: Double = 60
    @Published var alarmSoundEnabled: Bool = true
    @Published var testToneFrequency: Double = 880
    @Published var voiceUploadProgress: Double = 0
    @Published var voiceUploadStatus: String = ""
    @Published var audioRouteName: String = "Unknown"
    @Published var audioRouteStatus: String = "Checking audio route..."
    @Published var isAwakenAudioRouteActive: Bool = false
    @Published var hasVerifiedLiveAlarm: Bool = false
    @Published var liveAlarmVerificationMessage: String = ""

    // MARK: - Init
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        configureAudioSession()
        startAudioRouteMonitoring()
        refreshAudioRoute()
    }

    deinit {
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Audio Route
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            print("Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func startAudioRouteMonitoring() {
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAudioRoute()
        }
    }

    func refreshAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let output = outputs.first
        let outputName = output?.portName ?? "Built-in Speaker"

        let hasA2DPRoute = outputs.contains { $0.portType == .bluetoothA2DP }
        let hasAwakenName = outputs.contains { $0.portName.localizedCaseInsensitiveContains("Awaken") }

        let isAwakenRouteActive = hasAwakenName || hasA2DPRoute
        let status: String
        if hasAwakenName {
            status = "Awaken-Stream selected"
        } else if hasA2DPRoute {
            status = "Bluetooth A2DP active: \(outputName)"
        } else {
            status = "Current output: \(outputName)"
        }

        DispatchQueue.main.async {
            self.audioRouteName = outputName
            self.isAwakenAudioRouteActive = isAwakenRouteActive
            self.audioRouteStatus = status
        }
    }

    // MARK: - Connection
    func startScanning() {
        connectionStatus = "Scanning..."
        discoveredPeripherals.removeAll()
        centralManager.scanForPeripherals(withServices: [ALARM_SERVICE_UUID], options: nil)
    }

    func connect(to peripheral: CBPeripheral) {
        userDisconnectRequested = false
        connectionStatus = "Connecting..."
        centralManager.stopScan()
        alarmClockPeripheral = peripheral
        alarmClockPeripheral?.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = alarmClockPeripheral else { return }
        userDisconnectRequested = true
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func writeType(for characteristic: CBCharacteristic, preferResponse: Bool = false) -> CBCharacteristicWriteType? {
        let properties = characteristic.properties

        if preferResponse && properties.contains(.write) {
            return .withResponse
        }
        if properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if properties.contains(.write) {
            return .withResponse
        }
        return nil
    }

    private func writeValue(_ data: Data, for characteristic: CBCharacteristic, preferResponse: Bool = false) {
        guard let peripheral = alarmClockPeripheral else { return }
        guard let writeType = writeType(for: characteristic, preferResponse: preferResponse) else {
            print("Write blocked: characteristic \(characteristic.uuid) is not writable")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    // MARK: - Alarm
    func setAlarm(time: Date) {
        guard let characteristic = alarmCharacteristic else {
            hasVerifiedLiveAlarm = false
            liveAlarmVerificationMessage = "Alarm set failed: device not ready"
            return
        }

        let payloadFormatter = DateFormatter()
        payloadFormatter.dateFormat = "HH:mm"
        let timeString = payloadFormatter.string(from: time)

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "h:mm a"
        pendingAlarmDisplayTime = displayFormatter.string(from: time)

        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = "Verifying live alarm..."

        guard let data = timeString.data(using: .utf8) else { return }
        writeValue(data, for: characteristic, preferResponse: true)
    }

    func setWakeEffect(_ effectId: UInt8) {
        guard let characteristic = wakeEffectCharacteristic else { return }
        selectedWakeEffect = effectId
        writeValue(Data([effectId]), for: characteristic)
    }

    func stopAlarm() {
        guard let characteristic = alarmControlCharacteristic else { return }
        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = ""
        pendingAlarmDisplayTime = nil
        writeValue(Data([0]), for: characteristic)
    }

    func snoozeAlarm() {
        guard let characteristic = alarmControlCharacteristic else { return }
        writeValue(Data([1]), for: characteristic)
    }

    // MARK: - Vibration Test
    func setVibrationIntensity(_ percent: Double) {
        guard let characteristic = intensityCharacteristic else { return }
        let mapped = UInt8(min(max(percent, 0), 100) * 127.0 / 100.0)
        writeValue(Data([mapped]), for: characteristic)
    }

    func playEffect(_ effectId: UInt8) {
        guard let characteristic = effectCharacteristic else { return }
        writeValue(Data([effectId]), for: characteristic)
    }

    func stopVibration() {
        guard let characteristic = intensityCharacteristic else { return }
        writeValue(Data([0]), for: characteristic)
    }

    // MARK: - Speaker
    func setSpeakerVolume(_ percent: Double) {
        guard let characteristic = speakerVolumeCharacteristic else { return }
        let clamped = min(max(percent, 0), 100)
        speakerVolume = clamped
        writeValue(Data([UInt8(clamped)]), for: characteristic)
    }

    func setAlarmSoundEnabled(_ enabled: Bool) {
        guard let characteristic = speakerControlCharacteristic else { return }
        alarmSoundEnabled = enabled
        let cmd: UInt8 = enabled ? 3 : 2
        writeValue(Data([cmd]), for: characteristic)
    }

    func playSpeakerTestTone() {
        guard let characteristic = speakerControlCharacteristic else { return }
        let freq = UInt16(min(max(testToneFrequency, 100), 5000))
        let lo = UInt8(freq & 0xFF)
        let hi = UInt8(freq >> 8)
        writeValue(Data([1, lo, hi]), for: characteristic)
    }

    func playUploadedVoiceAlarm() {
        guard let characteristic = speakerControlCharacteristic else { return }
        writeValue(Data([4]), for: characteristic)
    }

    func uploadVoiceAlarmPCM(_ pcmData: Data, completion: @escaping (Bool) -> Void) {
        guard let characteristic = voiceUploadCharacteristic, let peripheral = alarmClockPeripheral else {
            voiceUploadStatus = "Voice upload characteristic unavailable"
            completion(false)
            return
        }

        if pcmData.isEmpty {
            voiceUploadStatus = "No audio to upload"
            completion(false)
            return
        }

        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunkSize = max(8, min(180, maxWrite - 1))

        var packets: [Data] = []
        var begin = Data([1])
        var byteCount = UInt32(pcmData.count).littleEndian
        withUnsafeBytes(of: &byteCount) { begin.append(contentsOf: $0) }
        packets.append(begin)

        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            var packet = Data([2])
            packet.append(pcmData.subdata(in: offset..<end))
            packets.append(packet)
            offset = end
        }
        packets.append(Data([3]))

        voiceUploadPackets = packets
        voiceUploadPacketIndex = 0
        voiceUploadCompletion = completion
        voiceUploadProgress = 0
        voiceUploadStatus = "Uploading voice..."

        peripheral.writeValue(packets[0], for: characteristic, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothViewModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            connectionStatus = "Bluetooth is not available."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        userDisconnectRequested = false
        connectionStatus = "Discovering services..."
        peripheral.discoverServices([ALARM_SERVICE_UUID])
        refreshAudioRoute()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        alarmCharacteristic = nil
        intensityCharacteristic = nil
        effectCharacteristic = nil
        statusCharacteristic = nil
        wakeEffectCharacteristic = nil
        alarmStateCharacteristic = nil
        alarmControlCharacteristic = nil
        speakerVolumeCharacteristic = nil
        speakerControlCharacteristic = nil
        voiceUploadCharacteristic = nil
        hasDRV2605L = false
        hasSpeakerAmp = false
        alarmFiring = false
        voiceUploadPackets = []
        voiceUploadPacketIndex = 0
        voiceUploadCompletion = nil
        voiceUploadProgress = 0
        voiceUploadStatus = ""
        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = ""
        pendingAlarmDisplayTime = nil

        if !userDisconnectRequested && reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            connectionStatus = "Reconnecting... (\(reconnectAttempts))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.alarmClockPeripheral = peripheral
                self.alarmClockPeripheral?.delegate = self
                central.connect(peripheral, options: nil)
            }
            return
        }

        userDisconnectRequested = false
        reconnectAttempts = 0
        connectionStatus = "Disconnected"
        alarmClockPeripheral = nil
        refreshAudioRoute()
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothViewModel: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == ALARM_SERVICE_UUID {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("Discovered characteristic \(characteristic.uuid) properties=\(characteristic.properties.rawValue)")
            switch characteristic.uuid {
            case ALARM_CHARACTERISTIC_UUID:
                alarmCharacteristic = characteristic
            case INTENSITY_CHARACTERISTIC_UUID:
                intensityCharacteristic = characteristic
            case EFFECT_CHARACTERISTIC_UUID:
                effectCharacteristic = characteristic
            case STATUS_CHARACTERISTIC_UUID:
                statusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            case WAKE_EFFECT_CHARACTERISTIC_UUID:
                wakeEffectCharacteristic = characteristic
            case ALARM_STATE_CHARACTERISTIC_UUID:
                alarmStateCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case ALARM_CONTROL_CHARACTERISTIC_UUID:
                alarmControlCharacteristic = characteristic
            case SPEAKER_VOLUME_CHARACTERISTIC_UUID:
                speakerVolumeCharacteristic = characteristic
            case SPEAKER_CONTROL_CHARACTERISTIC_UUID:
                speakerControlCharacteristic = characteristic
            case VOICE_UPLOAD_CHARACTERISTIC_UUID:
                voiceUploadCharacteristic = characteristic
            default:
                break
            }
        }

        if alarmCharacteristic != nil {
            connectionStatus = "Connected"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.refreshAudioRoute()
                if !self.isAwakenAudioRouteActive {
                    self.audioRouteStatus = "Select a device named Awaken-Stream-Hybrid-XXXX in iOS Bluetooth settings"
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write error: \(error.localizedDescription)")

            if characteristic.uuid == ALARM_CHARACTERISTIC_UUID {
                hasVerifiedLiveAlarm = false
                liveAlarmVerificationMessage = "Alarm set failed: \(error.localizedDescription)"
                pendingAlarmDisplayTime = nil
            }

            if characteristic.uuid == VOICE_UPLOAD_CHARACTERISTIC_UUID {
                voiceUploadStatus = "Voice upload failed"
                voiceUploadPackets = []
                voiceUploadPacketIndex = 0
                voiceUploadProgress = 0
                let completion = voiceUploadCompletion
                voiceUploadCompletion = nil
                completion?(false)
            }
            return
        }

        if characteristic.uuid == ALARM_CHARACTERISTIC_UUID {
            hasVerifiedLiveAlarm = true
            let displayTime = pendingAlarmDisplayTime ?? "scheduled time"
            liveAlarmVerificationMessage = "Live alarm verified for \(displayTime)"
            pendingAlarmDisplayTime = nil
            return
        }

        if characteristic.uuid == VOICE_UPLOAD_CHARACTERISTIC_UUID {
            voiceUploadPacketIndex += 1
            if !voiceUploadPackets.isEmpty {
                voiceUploadProgress = Double(voiceUploadPacketIndex) / Double(voiceUploadPackets.count)
            }

            if voiceUploadPacketIndex >= voiceUploadPackets.count {
                voiceUploadStatus = "Voice uploaded"
                voiceUploadPackets = []
                voiceUploadPacketIndex = 0
                voiceUploadProgress = 1
                let completion = voiceUploadCompletion
                voiceUploadCompletion = nil
                completion?(true)
            } else if let uploadCharacteristic = voiceUploadCharacteristic {
                peripheral.writeValue(
                    voiceUploadPackets[voiceUploadPacketIndex],
                    for: uploadCharacteristic,
                    type: .withResponse
                )
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        DispatchQueue.main.async {
            switch characteristic.uuid {
            case STATUS_CHARACTERISTIC_UUID:
                self.hasDRV2605L = (data[0] & 0x01) != 0
                self.hasSpeakerAmp = (data[0] & 0x02) != 0
            case ALARM_STATE_CHARACTERISTIC_UUID:
                self.alarmFiring = (data[0] == 1)
            default:
                break
            }
        }
    }
}
