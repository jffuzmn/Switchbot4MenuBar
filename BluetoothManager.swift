import Foundation
import CoreBluetooth
import Combine
import UserNotifications
import AppKit
import os.log

private let logger = Logger(subsystem: "com.switchbot.co2menubar", category: "Bluetooth")

// Simple file logger for debugging
class FileLogger {
    static let shared = FileLogger()
    private let logFile: URL
    private let fileHandle: FileHandle?
    
    init() {
        // Use tmp directory which is always writable
        logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchbot_ble_log.txt")
        
        // Create/clear the log file
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFile)
        log("=== SwitchBot BLE Scanner Started ===")
        log("Log file: \(logFile.path)")
    }
    
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
            try? fileHandle?.synchronize()
        }
    }
    
    deinit {
        try? fileHandle?.close()
    }
}

class BluetoothManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var currentReading: SwitchBotReading?
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var staleDataTimer: Timer?
    private let staleDataTimeout: TimeInterval = 300 // 5 minutes without data = stale

    // Alert settings
    private var co2AlertThreshold: Int = 1200 // ppm
    private var hasAlertedForHighCO2: Bool = false
    private var gentleAlertSound: NSSound?
    private var urgentAlertSound: NSSound?
    
    // Debug mode - enable to see raw advertisement data
    private let debugMode = true
    private var seenDevices = Set<String>()  // Track devices we've logged

    @Published var alertSoundType: AlertSoundType = .gentle {
        didSet {
            UserDefaults.standard.set(alertSoundType.rawValue, forKey: "alertSoundType")
        }
    }

    // MARK: - Initialization

    override init() {
        super.init()

        // Load saved alert sound preference
        if let savedType = UserDefaults.standard.string(forKey: "alertSoundType"),
           let type = AlertSoundType(rawValue: savedType) {
            alertSoundType = type
        }

        centralManager = CBCentralManager(delegate: self, queue: nil)
        requestNotificationPermissions()
        setupAlertSounds()
    }

    private func setupAlertSounds() {
        // Load gentle alert sound
        if let gentlePath = Bundle.main.path(forResource: "air_quality_alert", ofType: "aiff") {
            gentleAlertSound = NSSound(contentsOfFile: gentlePath, byReference: false)
        }

        // Load urgent/fire alarm sound
        if let urgentPath = Bundle.main.path(forResource: "fire_alarm", ofType: "aiff") {
            urgentAlertSound = NSSound(contentsOfFile: urgentPath, byReference: false)
        }
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Permission requested
        }
    }

    private func sendHighCO2Alert(co2: Int) {
        let content = UNMutableNotificationContent()
        content.title = "High CO₂ Alert"
        content.body = "CO₂ level is \(co2) ppm. Consider opening a window or improving ventilation."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "highCO2", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        // Play audio alarm
        playAlarmSound()
    }

    private func playAlarmSound() {
        switch alertSoundType {
        case .off:
            // No sound
            return

        case .gentle:
            // Play gentle sound 2 times
            guard let sound = gentleAlertSound else { return }
            for i in 0..<2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.6) {
                    sound.play()
                }
            }

        case .urgent:
            // Play fire alarm once (it's already 5 seconds long)
            urgentAlertSound?.play()
        }
    }

    func sendTestNotification() {
        // Check notification authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    // Permission granted, send notification
                    let content = UNMutableNotificationContent()
                    content.title = "Test Notification"
                    content.body = "Notifications and alarm sound are working! You'll be alerted when CO₂ reaches 1200 ppm."
                    content.sound = .default

                    let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)

                    // Also play the alarm sound so user can hear it
                    self.playAlarmSound()

                case .denied:
                    // Permission denied - show alert
                    let alert = NSAlert()
                    alert.messageText = "Notifications Disabled"
                    alert.informativeText = "Please enable notifications for SwitchBot CO₂ in System Settings → Notifications to receive CO₂ alerts."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        // Open System Settings to Notifications
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                case .notDetermined:
                    // Permission not yet requested - request it now
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted {
                            // Send test notification after granting
                            self.sendTestNotification()
                        }
                    }

                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            errorMessage = "Bluetooth is not available"
            return
        }

        connectionStatus = .scanning
        errorMessage = nil

        // Scan for all devices to capture advertisements
        // We use nil for services to see all BLE advertisements
        // AllowDuplicates = true so we get continuous updates from the same device
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        
        // Start stale data timer
        startStaleDataTimer()
        
        logger.info("Started scanning for BLE advertisements...")
        FileLogger.shared.log("Started scanning for BLE advertisements...")
    }

    func stopScanning() {
        centralManager.stopScan()
        stopStaleDataTimer()
        logger.info("Stopped scanning")
    }

    func refreshReadings() {
        // For advertisement-based reading, we just restart scanning
        // The device continuously broadcasts, so we'll get fresh data soon
        if connectionStatus != .scanning {
            startScanning()
        }
    }

    func disconnect() {
        stopScanning()
        connectionStatus = .disconnected
    }

    // MARK: - Private Methods
    
    private func startStaleDataTimer() {
        stopStaleDataTimer()
        staleDataTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForStaleData()
        }
    }
    
    private func stopStaleDataTimer() {
        staleDataTimer?.invalidate()
        staleDataTimer = nil
    }
    
    private func checkForStaleData() {
        guard let lastUpdated = lastUpdated else { return }
        
        let timeSinceUpdate = Date().timeIntervalSince(lastUpdated)
        if timeSinceUpdate > staleDataTimeout {
            DispatchQueue.main.async {
                self.errorMessage = "No data received for \(Int(timeSinceUpdate / 60)) minutes"
            }
        }
    }

    private func checkCO2Level(_ co2: Int) {
        if co2 >= co2AlertThreshold {
            if !hasAlertedForHighCO2 {
                sendHighCO2Alert(co2: co2)
                hasAlertedForHighCO2 = true
            }
        } else {
            // Reset alert flag when CO2 drops below threshold
            hasAlertedForHighCO2 = false
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth is powered off"
        case .unauthorized:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth permission denied"
        case .unsupported:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth not supported"
        default:
            connectionStatus = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        // Get device name from advertisement or peripheral
        let deviceName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown"
        let deviceID = peripheral.identifier.uuidString
        
        // Log ALL devices once (for debugging)
        if debugMode && !seenDevices.contains(deviceID) {
            seenDevices.insert(deviceID)
            let logMsg = "Found device: \(deviceName) (ID: \(deviceID.prefix(8))...) RSSI: \(RSSI)"
            logger.info("\(logMsg)")
            FileLogger.shared.log(logMsg)
            
            // Log service data if present
            if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                for (uuid, data) in serviceData {
                    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    let svcMsg = "  Service Data [\(uuid.uuidString)]: \(hex)"
                    logger.info("\(svcMsg)")
                    FileLogger.shared.log(svcMsg)
                }
            }
            
            // Log manufacturer data if present
            if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                let hex = mfgData.map { String(format: "%02x", $0) }.joined(separator: " ")
                let mfgMsg = "  Manufacturer Data: \(hex)"
                logger.info("\(mfgMsg)")
                FileLogger.shared.log(mfgMsg)
            }
            
            // Log service UUIDs if present
            if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                let uuidMsg = "  Service UUIDs: \(serviceUUIDs.map { $0.uuidString })"
                logger.info("\(uuidMsg)")
                FileLogger.shared.log(uuidMsg)
            }
        }
        
        // Check if this could be a SwitchBot device
        let isSwitchBot = SwitchBotUUIDs.deviceNamePatterns.contains { pattern in
            deviceName.localizedCaseInsensitiveContains(pattern)
        }
        
        // Also check for SwitchBot service UUID in service UUIDs
        var hasServiceUUID = false
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            hasServiceUUID = serviceUUIDs.contains { uuid in
                uuid.uuidString.uppercased() == SwitchBotUUIDs.serviceUUID ||
                uuid.uuidString.uppercased() == SwitchBotUUIDs.serviceUUIDFull
            }
        }
        
        // Check service data for SwitchBot's service UUID
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData {
                let uuidString = uuid.uuidString.uppercased()
                
                // Check if this is SwitchBot's service UUID (FD3D)
                if uuidString == SwitchBotUUIDs.serviceUUID || 
                   uuidString.contains("FD3D") ||
                   uuidString == SwitchBotUUIDs.serviceUUIDFull {
                    
                    let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    if debugMode {
                        logger.notice("🎯 Found SwitchBot service data for UUID: \(uuidString)")
                        logger.notice("🎯 Device: \(deviceName), RSSI: \(RSSI)")
                        logger.notice("🎯 Data (\(data.count) bytes): \(hexString)")
                        FileLogger.shared.log("🎯 SWITCHBOT FOUND! UUID: \(uuidString), Device: \(deviceName)")
                        FileLogger.shared.log("🎯 Data (\(data.count) bytes): \(hexString)")
                    }
                    
                    // Try to decode the reading
                    if let reading = SwitchBotReading.decode(from: data, rssi: RSSI.intValue) {
                        DispatchQueue.main.async {
                            self.currentReading = reading
                            self.lastUpdated = Date()
                            self.errorMessage = nil
                            self.connectionStatus = .receiving
                            
                            // Check for high CO2 and send alert
                            self.checkCO2Level(reading.co2)
                        }
                        return
                    }
                }
            }
        }
        
        // Check manufacturer data for SwitchBot
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            // SwitchBot manufacturer ID is 0x0969 (little-endian: 0x69 0x09)
            if manufacturerData.count >= 2 {
                let manufacturerID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
                
                if manufacturerID == SwitchBotUUIDs.manufacturerID {
                    if debugMode {
                        logger.notice("🎯 Found SwitchBot manufacturer data")
                        logger.notice("🎯 Device: \(deviceName), RSSI: \(RSSI)")
                        let hexString = manufacturerData.map { String(format: "%02x", $0) }.joined(separator: " ")
                        logger.notice("🎯 Manufacturer data (\(manufacturerData.count) bytes): \(hexString)")
                        FileLogger.shared.log("🎯 SWITCHBOT Manufacturer Data from \(deviceName): \(hexString)")
                    }
                    
                    // Try to decode from manufacturer data
                    if let reading = SwitchBotReading.decodeFromManufacturerData(manufacturerData, rssi: RSSI.intValue) {
                        DispatchQueue.main.async {
                            self.currentReading = reading
                            self.lastUpdated = Date()
                            self.errorMessage = nil
                            self.connectionStatus = .receiving
                            
                            // Check for high CO2 and send alert
                            self.checkCO2Level(reading.co2)
                            
                            FileLogger.shared.log("✅ READING: CO2=\(reading.co2)ppm, Temp=\(reading.temperature)°C, Humidity=\(reading.humidity)%")
                        }
                        return
                    }
                }
            }
        }
        
        // Debug: log devices that look like they might be SwitchBot
        if debugMode && (isSwitchBot || hasServiceUUID) {
            logger.notice("⚠️ Potentially relevant device: \(deviceName)")
            logger.info("  Advertisement keys: \(advertisementData.keys.map { String(describing: $0) })")
        }
    }
}
