// BluetoothViewModel.swift

import Foundation
import CoreBluetooth

// These UUIDs must match the ones in your ESP32 firmware
let ALARM_SERVICE_UUID = CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")
let ALARM_CHARACTERISTIC_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a8")

class BluetoothViewModel: NSObject, ObservableObject {
    // MARK: - Properties
    private var centralManager: CBCentralManager!
    private var alarmClockPeripheral: CBPeripheral?
    private var alarmCharacteristic: CBCharacteristic?

    @Published var connectionStatus: String = "Disconnected"
    @Published var discoveredPeripherals: [CBPeripheral] = []

    // MARK: - Initialization
    override init() {
        super.init()
        // The 'centralManager' is the entry point to CoreBluetooth.
        // We set the delegate to self to receive BLE events.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public Methods
    func startScanning() {
        connectionStatus = "Scanning..."
        discoveredPeripherals.removeAll()
        // We scan for peripherals that are advertising our specific service UUID.
        centralManager.scanForPeripherals(withServices: [ALARM_SERVICE_UUID], options: nil)
    }

    func connect(to peripheral: CBPeripheral) {
        connectionStatus = "Connecting..."
        centralManager.stopScan()
        alarmClockPeripheral = peripheral
        alarmClockPeripheral?.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = alarmClockPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func setAlarm(time: Date) {
        guard let characteristic = alarmCharacteristic else {
            print("Error: Alarm characteristic not found.")
            return
        }

        // Format the Date into the "HH:mm" string the ESP32 expects
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeString = formatter.string(from: time)

        guard let data = timeString.data(using: .utf8) else { return }

        // Write the data to the characteristic
        alarmClockPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
        print("Sent alarm time: \(timeString)")
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothViewModel: CBCentralManagerDelegate {
    // This method is called when the Bluetooth state changes (e.g., powered on/off).
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            connectionStatus = "Bluetooth is not available."
        }
    }

    // This method is called for each peripheral discovered during a scan.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Avoid adding duplicates
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    // Called when a connection is successfully established.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = "Connected! Discovering services..."
        // Now that we're connected, we ask the peripheral to discover its services.
        peripheral.discoverServices([ALARM_SERVICE_UUID])
    }

    // Called when a peripheral disconnects.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Disconnected"
        alarmClockPeripheral = nil
        alarmCharacteristic = nil
        // Optionally, restart scanning to find it again
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothViewModel: CBPeripheralDelegate {
    // Called after discoverServices() is called.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == ALARM_SERVICE_UUID {
                connectionStatus = "Service found! Discovering characteristics..."
                // Now we discover the characteristics for our specific service.
                peripheral.discoverCharacteristics([ALARM_CHARACTERISTIC_UUID], for: service)
            }
        }
    }

    // Called after discoverCharacteristics() is called.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == ALARM_CHARACTERISTIC_UUID {
                connectionStatus = "Ready to set alarm!"
                // We found the characteristic we need to write to. Save a reference to it.
                alarmCharacteristic = characteristic
            }
        }
    }
    
    // This is a confirmation that our data was successfully written.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error writing characteristic value: \(error.localizedDescription)")
            return
        }
        print("Successfully wrote value to characteristic.")
    }
}
