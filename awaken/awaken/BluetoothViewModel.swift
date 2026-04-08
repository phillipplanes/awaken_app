import Foundation
import Combine
import CoreBluetooth
import AVFAudio
import AVFoundation
import UIKit

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
let TIME_SYNC_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26b4")
let BATTERY_LEVEL_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26b5")

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
    private var timeSyncCharacteristic: CBCharacteristic?
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var voiceUploadPackets: [Data] = []
    private var voiceUploadPacketIndex: Int = 0
    private var voiceUploadWriteType: CBCharacteristicWriteType?
    private var voiceUploadCompletion: ((Bool) -> Void)?
    private var voiceUploadRetryWorkItem: DispatchWorkItem?
    private var voiceUploadDeadline: Date?
    private var hasDisabledTimeSyncWrites: Bool = false
    private var audioRouteObserver: NSObjectProtocol?
    private var audioRouteDebounce: DispatchWorkItem?
    private var notificationObservers: [NSObjectProtocol] = []
    private var localAlarmFallbackWorkItem: DispatchWorkItem?
    private var pendingAlarmDisplayTime: String?
    private var userDisconnectRequested: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 10
    private var scanRestartTimer: Timer?

    // MARK: - Published
    @Published var connectionStatus: String = "Disconnected"
    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var vibrationIntensity: Double = 50
    @Published var hasDRV2605L: Bool = false
    @Published var hasSpeakerAmp: Bool = false
    @Published var hasBatteryTelemetry: Bool = false
    @Published var batteryLevelPercent: Int?
    @Published var alarmFiring: Bool = false
    @Published var selectedWakeEffect: UInt8 = 1
    @Published var speakerVolume: Double = 60
    @Published var alarmSoundEnabled: Bool = true
    @Published var testToneFrequency: Double = 880
    @Published var voiceUploadProgress: Double = 0
    @Published var voiceUploadStatus: String = ""
    @Published var canSyncGeneratedAudioToDevice: Bool = false
    @Published var audioRouteName: String = "Unknown"
    @Published var audioRouteStatus: String = "Checking audio route..."
    @Published var isAwakenAudioRouteActive: Bool = false
    @Published var hasVerifiedLiveAlarm: Bool = false
    @Published var liveAlarmVerificationMessage: String = ""
    @Published var scheduledAlarmDisplayTime: String?
    @Published var scheduledAlarms: [ScheduledAlarm] = ScheduledAlarm.loadAll()
    @Published var editingAlarmID: UUID?
    @Published var localAlarmFallbackActive: Bool = false

    private static let bleRestoreIdentifier = "com.awaken.centralManager"
    private static let savedPeripheralKey = "com.awaken.lastPeripheralUUID"

    // MARK: - Init
    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.bleRestoreIdentifier]
        )
        configureAudioSession()
        startAudioRouteMonitoring()
        startAlarmNotificationMonitoring()
        refreshAudioRoute()
    }

    deinit {
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Audio Route
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.allowBluetoothA2DP])
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
            self?.audioRouteDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshAudioRoute()
            }
            self?.audioRouteDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    private func startAlarmNotificationMonitoring() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: .awakenAlarmNotificationTriggered,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.alarmFiring else { return }
                self.localAlarmFallbackActive = true
            },
            center.addObserver(
                forName: .awakenAlarmNotificationStopRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stopAlarm()
            },
            center.addObserver(
                forName: .awakenAlarmNotificationSnoozeRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.snoozeAlarm()
            }
        ]
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
            status = "AWAKEN-audio connected"
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
        centralManager.scanForPeripherals(withServices: [ALARM_SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        // Restart scan every 3s so we catch the ESP32 after its supervision timeout
        scanRestartTimer?.invalidate()
        scanRestartTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.alarmClockPeripheral == nil || self.alarmClockPeripheral?.state == .disconnected else {
                self?.scanRestartTimer?.invalidate()
                self?.scanRestartTimer = nil
                return
            }
            self.centralManager.stopScan()
            self.centralManager.scanForPeripherals(withServices: [ALARM_SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func connect(to peripheral: CBPeripheral) {
        userDisconnectRequested = false
        connectionStatus = "Connecting..."
        scanRestartTimer?.invalidate()
        scanRestartTimer = nil
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

    private func writeType(for characteristic: CBCharacteristic, preferWithoutResponse: Bool = true) -> CBCharacteristicWriteType? {
        let properties = characteristic.properties

        if preferWithoutResponse {
            if properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
            if properties.contains(.write) {
                return .withResponse
            }
        } else {
            if properties.contains(.write) {
                return .withResponse
            }
            if properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
        }
        return nil
    }

    @discardableResult
    private func writeValue(_ data: Data, for characteristic: CBCharacteristic, preferWithoutResponse: Bool = true) -> CBCharacteristicWriteType? {
        guard let peripheral = alarmClockPeripheral else { return nil }
        guard let writeType = writeType(for: characteristic, preferWithoutResponse: preferWithoutResponse) else {
            print("Write blocked: characteristic \(characteristic.uuid) is not writable")
            return nil
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
        return writeType
    }

    private func writeControlValue(_ data: Data, for characteristic: CBCharacteristic) {
        _ = writeValue(data, for: characteristic, preferWithoutResponse: false)
        if characteristic.properties.contains(.writeWithoutResponse) {
            _ = writeValue(data, for: characteristic, preferWithoutResponse: true)
        }
    }

    private func sendSpeakerCommand(_ data: Data, repeats: Int = 3) {
        guard let characteristic = speakerControlCharacteristic else { return }

        for index in 0..<max(1, repeats) {
            let delay = Double(index) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                _ = self.writeValue(data, for: characteristic)
            }
        }
    }

    private func repeatAlarmControlWrite(_ action: @escaping () -> Void) {
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: action)
    }

    // MARK: - Alarm

    func setAlarm(time: Date, repeatDays: Set<Int> = [], wakeEffect: UInt8 = 1,
                  alarmType: AlarmType = .focus, voiceOption: VoiceOption = .shimmer,
                  audioOutput: AlarmAudioOutput = .phone, editingID: UUID? = nil) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: time)
        let minute = calendar.component(.minute, from: time)
        print("[ALARM] setAlarm called: \(hour):\(minute) repeatDays=\(repeatDays) editingID=\(String(describing: editingID))")

        // Create or update the ScheduledAlarm
        var alarm = ScheduledAlarm(
            id: editingID ?? UUID(),
            hour: hour,
            minute: minute,
            repeatDays: repeatDays,
            wakeEffect: wakeEffect,
            alarmType: alarmType.rawValue,
            voiceOption: voiceOption.rawValue,
            audioOutput: audioOutput.rawValue
        )

        if let editingID {
            if let idx = scheduledAlarms.firstIndex(where: { $0.id == editingID }) {
                alarm.createdAt = scheduledAlarms[idx].createdAt
                scheduledAlarms[idx] = alarm
            } else {
                scheduledAlarms.append(alarm)
            }
        } else {
            scheduledAlarms.append(alarm)
        }
        ScheduledAlarm.saveAll(scheduledAlarms)
        print("[ALARM] Saved \(scheduledAlarms.count) alarms to UserDefaults")
        editingAlarmID = nil

        // Send the soonest alarm to the device
        sendNextAlarmToDevice()
    }

    func deleteAlarm(_ alarm: ScheduledAlarm) {
        scheduledAlarms.removeAll { $0.id == alarm.id }
        ScheduledAlarm.saveAll(scheduledAlarms)

        if scheduledAlarms.isEmpty {
            stopAlarm()
        } else {
            sendNextAlarmToDevice()
        }
    }

    func toggleAlarm(_ alarm: ScheduledAlarm) {
        guard let idx = scheduledAlarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        scheduledAlarms[idx].isEnabled.toggle()
        ScheduledAlarm.saveAll(scheduledAlarms)
        sendNextAlarmToDevice()
    }

    /// Find the soonest enabled alarm and send it to the ESP32.
    func sendNextAlarmToDevice() {
        let enabled = scheduledAlarms.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            scheduledAlarmDisplayTime = nil
            clearLocalAlarmFallback()
            Task { await AlarmNotificationManager.shared.cancelPhoneAlarm() }
            return
        }

        let now = Date()
        guard let soonest = enabled.min(by: { $0.nextFireDate(after: now) < $1.nextFireDate(after: now) }) else { return }

        let target = soonest.nextFireDate(after: now)
        let delaySeconds = max(1, Int(target.timeIntervalSince(now)))
        let timeString = String(format: "%02d:%02d", soonest.hour, soonest.minute)

        var repeatMask = 0
        for day in soonest.repeatDays {
            let bit = day - 1
            if bit >= 0 && bit <= 6 { repeatMask |= (1 << bit) }
        }
        let payload = "\(timeString)|\(delaySeconds)|\(repeatMask)"

        pendingAlarmDisplayTime = soonest.displayTime
        scheduledAlarmDisplayTime = pendingAlarmDisplayTime

        scheduleLocalAlarmFallback(for: target, displayTime: pendingAlarmDisplayTime)
        if alarmSoundEnabled {
            Task { await AlarmNotificationManager.shared.cancelPhoneAlarm() }
        } else {
            AlarmNotificationManager.shared.schedulePhoneAlarm(for: target, displayTime: pendingAlarmDisplayTime)
        }

        sendTimeSync()

        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = "Verifying live alarm..."

        guard let characteristic = alarmCharacteristic,
              let data = payload.data(using: .utf8) else {
            hasVerifiedLiveAlarm = false
            liveAlarmVerificationMessage = "Alarm saved locally (device not ready)"
            return
        }
        let writeType = writeValue(data, for: characteristic)
        if writeType == .withoutResponse {
            hasVerifiedLiveAlarm = true
            liveAlarmVerificationMessage = "Alarm sent for \(pendingAlarmDisplayTime ?? "scheduled time")"
            pendingAlarmDisplayTime = nil
        }
    }

    private func sendTimeSync() {
        if hasDisabledTimeSyncWrites { return }
        guard let characteristic = timeSyncCharacteristic else { return }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: now)
        // Append day-of-week: 0=Sun, 1=Mon, ..., 6=Sat
        let dow = Calendar.current.component(.weekday, from: now) - 1 // Calendar weekday is 1=Sun
        let payload = "\(timeStr)|\(dow)"
        guard let data = payload.data(using: .utf8) else { return }
        _ = writeValue(data, for: characteristic)
    }

    func setWakeEffect(_ effectId: UInt8) {
        guard let characteristic = wakeEffectCharacteristic else { return }
        selectedWakeEffect = effectId
        writeValue(Data([effectId]), for: characteristic)
    }

    func stopAlarm() {
        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = ""
        pendingAlarmDisplayTime = nil
        clearLocalAlarmFallback()
        alarmFiring = false
        localAlarmFallbackActive = false

        // Remove one-time alarms that just fired; keep repeating ones
        scheduledAlarms.removeAll { $0.repeatDays.isEmpty }
        ScheduledAlarm.saveAll(scheduledAlarms)

        // Re-arm next alarm if any remain
        if !scheduledAlarms.isEmpty {
            sendNextAlarmToDevice()
        } else {
            scheduledAlarmDisplayTime = nil
        }
        Task {
            await AlarmNotificationManager.shared.cancelPhoneAlarm()
        }
        repeatAlarmControlWrite { [weak self] in
            guard let self else { return }
            if let intensityControl = self.intensityCharacteristic {
                self.writeControlValue(Data([0]), for: intensityControl)
            }
            if let speakerControl = self.speakerControlCharacteristic {
                self.writeControlValue(Data([0]), for: speakerControl)
            }
            if let characteristic = self.alarmControlCharacteristic {
                self.writeControlValue(Data([0]), for: characteristic)
            }
        }
    }

    func snoozeAlarm() {
        let snoozeDate = Date().addingTimeInterval(5 * 60)
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "h:mm a"
        scheduledAlarmDisplayTime = displayFormatter.string(from: snoozeDate)
        scheduleLocalAlarmFallback(for: snoozeDate, displayTime: scheduledAlarmDisplayTime)
        alarmFiring = false
        localAlarmFallbackActive = false
        if alarmSoundEnabled {
            Task {
                await AlarmNotificationManager.shared.cancelPhoneAlarm()
            }
        } else {
            AlarmNotificationManager.shared.schedulePhoneAlarm(
                for: snoozeDate,
                displayTime: scheduledAlarmDisplayTime
            )
        }
        repeatAlarmControlWrite { [weak self] in
            guard let self else { return }
            if let intensityControl = self.intensityCharacteristic {
                self.writeControlValue(Data([0]), for: intensityControl)
            }
            if let speakerControl = self.speakerControlCharacteristic {
                self.writeControlValue(Data([0]), for: speakerControl)
            }
            if let characteristic = self.alarmControlCharacteristic {
                self.writeControlValue(Data([1]), for: characteristic)
            }
        }
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
        alarmSoundEnabled = enabled
        let cmd: UInt8 = enabled ? 3 : 2
        sendSpeakerCommand(Data([cmd]), repeats: 2)
    }

    func playSpeakerTestTone() {
        let freq = UInt16(min(max(testToneFrequency, 100), 5000))
        let lo = UInt8(freq & 0xFF)
        let hi = UInt8(freq >> 8)
        sendSpeakerCommand(Data([1, lo, hi]))
    }

    func playUploadedVoiceOnDevice() {
        sendSpeakerCommand(Data([0x04]), repeats: 0)
    }

    func playUploadedVoicePreview() {
        sendSpeakerCommand(Data([4]))
    }

    // MARK: - A2DP Voice Capture
    /// Start A2DP capture on the ESP32. Call this BEFORE playing audio.
    func startA2dpCapture() {
        guard let characteristic = voiceUploadCharacteristic else {
            print("A2DP capture: no voice upload characteristic")
            return
        }
        print("=== A2DP CAPTURE: sending start command ===")
        _ = writeValue(Data([0x10]), for: characteristic)
        voiceUploadStatus = "Recording to device..."
        voiceUploadProgress = 0.1
    }

    /// Stop A2DP capture on the ESP32. Call this AFTER audio finishes playing.
    func stopA2dpCapture(completion: @escaping () -> Void) {
        guard let characteristic = voiceUploadCharacteristic else {
            completion()
            return
        }
        // Wait for ring buffer drain, then send stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            print("=== A2DP CAPTURE: sending stop command ===")
            _ = self?.writeValue(Data([0x11]), for: characteristic)
            self?.voiceUploadProgress = 1.0
            self?.voiceUploadStatus = "Voice synced to device."
            completion()
        }
    }

    private var voiceUploadInProgress = false

    func syncDeviceAlarmAudio(_ pcmData: Data, sampleRate: Int, completion: @escaping (Bool) -> Void) {
        guard !voiceUploadInProgress else {
            print("Voice upload already in progress, skipping duplicate request")
            completion(false)
            return
        }

        guard let characteristic = voiceUploadCharacteristic, let peripheral = alarmClockPeripheral else {
            print("Voice sync blocked: voiceUploadCharacteristic=\(voiceUploadCharacteristic == nil ? "nil" : "ok") alarmClockPeripheral=\(alarmClockPeripheral == nil ? "nil" : "ok")")
            voiceUploadStatus = "Device not connected for voice sync."
            completion(false)
            return
        }

        if pcmData.isEmpty {
            voiceUploadStatus = "No generated audio to sync"
            completion(false)
            return
        }

        // Must use writeWithoutResponse — ESP32 BLE stack rejects writeWithResponse.
        guard let selectedWriteType = writeType(for: characteristic, preferWithoutResponse: true) else {
            print("Voice sync blocked: no writable type found on characteristic (properties=\(characteristic.properties.rawValue))")
            voiceUploadStatus = "Device voice sync unavailable."
            completion(false)
            return
        }

        voiceUploadInProgress = true

        let maxWrite = peripheral.maximumWriteValueLength(for: selectedWriteType)
        // Use small chunks that fit within default BLE MTU (23 bytes).
        // Even with MTU negotiation, small chunks are more reliable with writeWithoutResponse.
        let chunkSize = 19

        let firstBytes = pcmData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let durationSec = Double(pcmData.count) / (2.0 * Double(sampleRate))
        print("=== VOICE UPLOAD START (iOS) ===")
        print("  pcmBytes: \(pcmData.count)")
        print("  sampleRate: \(sampleRate) Hz")
        print("  duration: \(String(format: "%.1f", durationSec)) sec")
        print("  chunkSize: \(chunkSize) (maxWrite=\(maxWrite), writeType=\(selectedWriteType == .withoutResponse ? "noResp" : "withResp"))")
        print("  first bytes: \(firstBytes)")
        print("================================")

        var packets: [Data] = []
        var begin = Data([1])
        var byteCount = UInt32(pcmData.count).littleEndian
        withUnsafeBytes(of: &byteCount) { begin.append(contentsOf: $0) }
        var littleEndianSampleRate = UInt32(max(1, sampleRate)).littleEndian
        withUnsafeBytes(of: &littleEndianSampleRate) { begin.append(contentsOf: $0) }
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

        let dataPackets = packets.count - 2
        print("  totalPackets: \(packets.count) (1 begin + \(dataPackets) data + 1 end, writeType=\(selectedWriteType == .withoutResponse ? "noResp" : "withResp"))")

        voiceUploadPackets = packets
        voiceUploadPacketIndex = 0
        voiceUploadWriteType = selectedWriteType
        voiceUploadCompletion = completion
        voiceUploadProgress = 0
        voiceUploadStatus = "Syncing \(pcmData.count) bytes (\(String(format: "%.1f", durationSec))s) to device..."
        voiceUploadDeadline = Date().addingTimeInterval(300) // withResponse is slow, allow 5 min

        sendNextVoiceUploadBatch()
    }

    var batteryStatusText: String {
        if let percent = batteryLevelPercent {
            return "\(percent)%"
        }
        return hasBatteryTelemetry ? "No battery detected" : "Not available"
    }

    /// Send 1 packet at a time with conservative pacing.
    /// The ESP32 BLE callback writes to SPIFFS which blocks — we must wait between packets.
    private func sendNextVoiceUploadBatch() {
        guard let peripheral = alarmClockPeripheral,
              let characteristic = voiceUploadCharacteristic,
              let writeType = voiceUploadWriteType else { return }

        voiceUploadRetryWorkItem?.cancel()
        voiceUploadRetryWorkItem = nil

        if let deadline = voiceUploadDeadline, Date() > deadline {
            finishVoiceUpload(success: false)
            return
        }

        guard voiceUploadPacketIndex < voiceUploadPackets.count else {
            finishVoiceUpload(success: true)
            return
        }

        // Send one packet
        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(voiceUploadPackets[voiceUploadPacketIndex], for: characteristic, type: writeType)
            voiceUploadPacketIndex += 1
        }

        if !voiceUploadPackets.isEmpty {
            voiceUploadProgress = Double(voiceUploadPacketIndex) / Double(voiceUploadPackets.count)
        }

        if voiceUploadPacketIndex % 500 == 0 {
            print("  upload progress: \(voiceUploadPacketIndex)/\(voiceUploadPackets.count)")
        }

        guard voiceUploadPacketIndex < voiceUploadPackets.count else {
            finishVoiceUpload(success: true)
            return
        }

        // Pause after BEGIN packet (packet index 1 = first chunk) to let ESP32 open SPIFFS file
        let delay: TimeInterval = (voiceUploadPacketIndex == 1) ? 1.0 : 0.015
        let workItem = DispatchWorkItem { [weak self] in self?.sendNextVoiceUploadBatch() }
        voiceUploadRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishVoiceUpload(success: Bool) {
        voiceUploadRetryWorkItem?.cancel()
        voiceUploadRetryWorkItem = nil
        voiceUploadDeadline = nil

        if success {
            let sentPackets = voiceUploadPacketIndex
            let totalPackets = voiceUploadPackets.count
            print("=== VOICE UPLOAD DONE (iOS) === sent \(sentPackets)/\(totalPackets) packets")
            voiceUploadStatus = "Audio synced (\(sentPackets)/\(totalPackets) packets)"
            voiceUploadProgress = voiceUploadPackets.isEmpty ? 0 : 1
        } else {
            let sentPackets = voiceUploadPacketIndex
            let totalPackets = voiceUploadPackets.count
            print("=== VOICE UPLOAD FAILED (iOS) === sent \(sentPackets)/\(totalPackets) packets")
            voiceUploadStatus = "Sync failed (\(sentPackets)/\(totalPackets) packets). Device will use built-in sound."
            voiceUploadProgress = 0
        }

        voiceUploadInProgress = false
        voiceUploadPackets = []
        voiceUploadPacketIndex = 0
        voiceUploadWriteType = nil
        let completion = voiceUploadCompletion
        voiceUploadCompletion = nil
        completion?(success)
    }

    private func clearLocalAlarmFallback() {
        localAlarmFallbackWorkItem?.cancel()
        localAlarmFallbackWorkItem = nil
        localAlarmFallbackActive = false
    }

    private func scheduleLocalAlarmFallback(for fireDate: Date, displayTime: String?) {
        clearLocalAlarmFallback()

        let delay = fireDate.timeIntervalSinceNow
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.alarmFiring {
                self.localAlarmFallbackActive = true
                self.hasVerifiedLiveAlarm = false
                self.liveAlarmVerificationMessage = "Alarm time reached for \(displayTime ?? "scheduled time"), but the device did not confirm start."
            }
        }
        localAlarmFallbackWorkItem = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothViewModel: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            alarmClockPeripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                connectionStatus = "Connected"
                restored.discoverServices([ALARM_SERVICE_UUID])
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Try to reconnect a restored peripheral in addition to scanning
            if let peripheral = alarmClockPeripheral, peripheral.state == .disconnected {
                central.connect(peripheral, options: nil)
            }
            // Pick up peripherals iOS still has connected (e.g. after Xcode rebuild)
            let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [ALARM_SERVICE_UUID])
            if let existing = alreadyConnected.first, alarmClockPeripheral == nil {
                alarmClockPeripheral = existing
                existing.delegate = self
                connectionStatus = "Connected"
                existing.discoverServices([ALARM_SERVICE_UUID])
            }
            // Queue a background reconnection to the last-known peripheral.
            // Also set a timeout: if it doesn't connect in 5s (e.g. bonds were
            // cleared on device reboot), cancel and let scanning take over.
            if alarmClockPeripheral == nil,
               let savedUUID = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
               let uuid = UUID(uuidString: savedUUID) {
                let known = central.retrievePeripherals(withIdentifiers: [uuid])
                if let peripheral = known.first {
                    print("[BLE] Queuing reconnect to saved peripheral \(uuid)")
                    peripheral.delegate = self
                    central.connect(peripheral, options: nil)
                    // Cancel stale reconnect if it hasn't connected after 5s
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        guard let self = self else { return }
                        if peripheral.state != .connected && self.alarmClockPeripheral == nil {
                            print("[BLE] Saved peripheral reconnect timed out, cancelling")
                            central.cancelPeripheralConnection(peripheral)
                        }
                    }
                }
            }
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

        // Auto-connect: connect to any device advertising our service unless already connected
        if alarmClockPeripheral?.state != .connected {
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        scanRestartTimer?.invalidate()
        scanRestartTimer = nil
        central.stopScan()
        reconnectAttempts = 0
        userDisconnectRequested = false
        // Adopt the peripheral if it came from a queued reconnect
        if alarmClockPeripheral == nil {
            alarmClockPeripheral = peripheral
            peripheral.delegate = self
        }
        connectionStatus = "Discovering services..."
        peripheral.discoverServices([ALARM_SERVICE_UUID])
        refreshAudioRoute()
        // Remember this peripheral so we can reconnect after Xcode rebuilds
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
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
        timeSyncCharacteristic = nil
        batteryLevelCharacteristic = nil
        hasDRV2605L = false
        hasSpeakerAmp = false
        batteryLevelPercent = nil
        alarmFiring = false
        voiceUploadInProgress = false
        voiceUploadPackets = []
        voiceUploadPacketIndex = 0
        voiceUploadCompletion = nil
        voiceUploadProgress = 0
        voiceUploadStatus = ""
        voiceUploadWriteType = nil
        hasDisabledTimeSyncWrites = false
        canSyncGeneratedAudioToDevice = false
        hasBatteryTelemetry = false
        hasVerifiedLiveAlarm = false
        liveAlarmVerificationMessage = ""
        pendingAlarmDisplayTime = nil
        scheduledAlarmDisplayTime = nil
        clearLocalAlarmFallback()

        if !userDisconnectRequested {
            reconnectAttempts += 1
            connectionStatus = "Reconnecting... (\(reconnectAttempts))"
            // Queue a direct reconnect to the known peripheral
            let delay = min(Double(reconnectAttempts) * 0.8, 5.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.alarmClockPeripheral = peripheral
                self.alarmClockPeripheral?.delegate = self
                central.connect(peripheral, options: nil)
            }
            // Also scan in parallel — the device may have a new identity after reboot/reflash
            startScanning()
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
                canSyncGeneratedAudioToDevice = writeType(for: characteristic, preferWithoutResponse: true) != nil
            case TIME_SYNC_CHARACTERISTIC_UUID:
                timeSyncCharacteristic = characteristic
            case BATTERY_LEVEL_CHARACTERISTIC_UUID:
                batteryLevelCharacteristic = characteristic
                hasBatteryTelemetry = true
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }

        if alarmCharacteristic != nil {
            connectionStatus = "Connected"
            sendTimeSync()
            // Re-send the next alarm to the device on reconnect
            if !scheduledAlarms.filter({ $0.isEnabled }).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendNextAlarmToDevice()
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write error for \(characteristic.uuid): \(error.localizedDescription)")

            if characteristic.uuid == ALARM_CHARACTERISTIC_UUID {
                hasVerifiedLiveAlarm = false
                liveAlarmVerificationMessage = "Alarm set failed: \(error.localizedDescription)"
                pendingAlarmDisplayTime = nil
                scheduledAlarmDisplayTime = nil
                clearLocalAlarmFallback()
            }

            if characteristic.uuid == VOICE_UPLOAD_CHARACTERISTIC_UUID {
                print("Voice upload write error at packet \(voiceUploadPacketIndex): \(error.localizedDescription)")
                finishVoiceUpload(success: false)
            }

            if characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
                hasDisabledTimeSyncWrites = true
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
            sendNextVoiceUploadBatch()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sendNextVoiceUploadBatch()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        DispatchQueue.main.async {
            switch characteristic.uuid {
            case STATUS_CHARACTERISTIC_UUID:
                self.hasDRV2605L = (data[0] & 0x01) != 0
                self.hasSpeakerAmp = (data[0] & 0x02) != 0
            case ALARM_STATE_CHARACTERISTIC_UUID:
                let firing = (data[0] == 1)
                self.alarmFiring = firing
                if firing {
                    self.localAlarmFallbackActive = false
                    // Only fire notification when app is backgrounded — in foreground,
                    // the alarm UI and audio are handled by ConnectedView directly.
                    // The notification sound was causing a second staggered audio instance.
                    if !self.alarmSoundEnabled,
                       UIApplication.shared.applicationState != .active {
                        AlarmNotificationManager.shared.fireImmediateAlarmNotification()
                    }
                }
            case BATTERY_LEVEL_CHARACTERISTIC_UUID:
                self.batteryLevelPercent = data[0] <= 100 ? Int(data[0]) : nil
            default:
                break
            }
        }
    }
}

