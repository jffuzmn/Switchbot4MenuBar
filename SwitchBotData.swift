import Foundation
import os.log

private let dataLogger = Logger(subsystem: "com.switchbot.co2menubar", category: "Data")

// MARK: - Connection Status

enum ConnectionStatus {
    case disconnected
    case scanning
    case receiving  // Changed from connecting/connected since we don't connect
}

// MARK: - SwitchBot Reading

struct SwitchBotReading {
    let co2: Int           // ppm
    let temperature: Double // Celsius
    let humidity: Int      // percent
    let battery: Int       // percent
    let timestamp: Date
    let rssi: Int          // Signal strength

    init(co2: Int, temperature: Double, humidity: Int, battery: Int, rssi: Int = 0, timestamp: Date = Date()) {
        self.co2 = co2
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.rssi = rssi
        self.timestamp = timestamp
    }

    /// Decode from SwitchBot Meter Pro CO2 (W4900010) manufacturer data
    /// Manufacturer ID: 0x0969 (SwitchBot)
    /// 
    /// Based on captured advertisement data analysis:
    /// Format: 69 09 [MAC 6 bytes] [type] [battery] [data...]
    /// 
    /// For CO2 Meter (18 bytes total):
    /// - Bytes 0-1: Manufacturer ID (69 09)
    /// - Bytes 2-7: Device MAC/ID
    /// - Byte 8: Device type (0x18 for CO2 meter)
    /// - Byte 9: Battery percentage
    /// - Bytes 10-11: CO2 value (little-endian)
    /// - Bytes 12-13: Humidity (encoded)  
    /// - Bytes 14-15: Temperature (encoded)
    /// - Bytes 16-17: Additional data
    static func decodeFromManufacturerData(_ data: Data, rssi: Int) -> SwitchBotReading? {
        // Check minimum length and manufacturer ID
        guard data.count >= 10 else {
            return nil
        }
        
        // Check manufacturer ID (0x0969 in little-endian = 69 09)
        guard data[0] == 0x69 && data[1] == 0x09 else {
            return nil
        }
        
        let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        dataLogger.info("SwitchBot manufacturer data (\(data.count) bytes): \(hexString)")
        
        // Device type is at byte 8
        let deviceType = data[8]
        dataLogger.info("Device type: 0x\(String(format: "%02x", deviceType))")
        
        // SwitchBot Meter Pro CO2 (W4900010) format - 18 bytes
        // Device types: 0x18, 0x19, 0x1e observed
        // Format after manufacturer ID and MAC:
        //   Byte 8:  Device type/flags
        //   Byte 9:  Battery % (0x64 = 100%)
        //   Byte 10: Temperature decimal (divide by 10)
        //   Byte 11: Temperature integer + 128 offset
        //   Byte 12: Humidity %
        //   Byte 13: (unknown)
        //   Byte 14: (unknown) 
        //   Byte 15: CO2 high byte
        //   Byte 16: CO2 low byte
        //   Byte 17: (unknown)
        
        if data.count >= 17 {
            let battery = Int(data[9])
            
            // Temperature: byte 11 has integer + 128, byte 10 has decimal * 10
            let tempInteger = Int(data[11]) - 128
            let tempDecimal = Double(data[10]) / 10.0
            let temperature = Double(tempInteger) + tempDecimal
            
            // Humidity: byte 12
            let humidity = Int(data[12])
            
            // CO2: bytes 15-16, big-endian
            let co2 = (Int(data[15]) << 8) | Int(data[16])
            
            dataLogger.info("📊 Decoded: CO2=\(co2)ppm, Temp=\(temperature)°C, Humidity=\(humidity)%, Battery=\(battery)%")
            
            // Validate ranges
            if co2 >= 300 && co2 <= 6000 && 
               humidity >= 0 && humidity <= 100 && 
               temperature >= -20 && temperature <= 60 {
                dataLogger.notice("✅ VALID reading from CO2 Meter Pro")
                return SwitchBotReading(
                    co2: co2,
                    temperature: temperature,
                    humidity: humidity,
                    battery: min(100, max(0, battery)),
                    rssi: rssi
                )
            }
        }
        
        return nil
    }
    
    /// Try different byte positions for decoding
    private static func tryAlternativeDecoding(_ data: Data, rssi: Int) -> SwitchBotReading? {
        guard data.count >= 18 else { return nil }
        
        let battery = Int(data[9])
        
        // Alternative 1: CO2 might be bytes 10-11 big-endian
        let co2Alt1 = (Int(data[10]) << 8) | Int(data[11])
        
        // Alternative 2: Check different positions for temp/humidity
        // Some formats put temp at 12-13, humidity at 14
        let tempAlt = Double(Int(data[12]) | (Int(data[13]) << 8)) / 10.0
        let humidityAlt = Int(data[14])
        
        dataLogger.info("Alt decode: CO2=\(co2Alt1), Temp=\(tempAlt), Humidity=\(humidityAlt)")
        
        if co2Alt1 >= 400 && co2Alt1 <= 5000 && tempAlt >= -10 && tempAlt <= 50 {
            return SwitchBotReading(
                co2: co2Alt1,
                temperature: tempAlt,
                humidity: humidityAlt,
                battery: battery,
                rssi: rssi
            )
        }
        
        return nil
    }
    
    /// Decode from FD3D service data
    /// Format varies by device type
    static func decode(from serviceData: Data, rssi: Int) -> SwitchBotReading? {
        let hexString = serviceData.map { String(format: "%02x", $0) }.joined(separator: " ")
        dataLogger.info("Service data (\(serviceData.count) bytes): \(hexString)")
        
        // 6-byte format (standard SwitchBot Meter) - no CO2
        // Format: [type] [temp_high+flags] [humidity] [?] [?] [?]
        if serviceData.count >= 6 {
            let deviceByte = serviceData[0]
            
            // Check for Meter Pro CO2 (type 0x7b with specific flags)
            // The 0x7b type might indicate a Meter device
            if deviceByte == 0x7b || (deviceByte & 0x7F) == 0x7b {
                // Standard meter format (no CO2)
                // Byte 1: bits 0-3 = temp decimal, bit 6 = temp sign (0=positive)
                // Byte 2: humidity %
                let tempDecimal = Double(serviceData[1] & 0x0F) / 10.0
                let isNegative = (serviceData[1] & 0x40) == 0  // bit 6 = 0 means negative
                let tempInteger = Double((serviceData[1] >> 4) & 0x03) * 10 + Double(serviceData[2] >> 4)
                var temperature = tempInteger + tempDecimal
                if isNegative { temperature = -temperature }
                
                let humidity = Int(serviceData[2] & 0x7F)
                
                // This is a regular meter without CO2 - return nil or partial data
                dataLogger.info("Standard Meter (no CO2): Temp=\(temperature), Humidity=\(humidity)")
                // Return nil since we specifically want CO2 data
                return nil
            }
        }
        
        // Longer service data might contain CO2
        if serviceData.count >= 10 {
            // Try to decode as CO2 meter service data
            let deviceType = serviceData[0]
            
            // Look for CO2 data patterns
            // Some devices put CO2 in service data bytes
            if deviceType == 0x18 || deviceType == 0x19 || deviceType == 0x69 {
                let battery = Int(serviceData[1])
                let co2 = (Int(serviceData[2]) << 8) | Int(serviceData[3])
                let humidity = Int(serviceData[4])
                let temperature = Double(serviceData[5]) + Double(serviceData[6]) / 10.0
                
                if co2 >= 300 && co2 <= 5000 {
                    return SwitchBotReading(co2: co2, temperature: temperature, humidity: humidity, battery: battery, rssi: rssi)
                }
            }
        }
        
        return nil
    }

    // Format for menu bar display
    var menuBarText: String {
        return "CO₂ \(co2) ppm  \(String(format: "%.1f", temperature))°C"
    }

    // Get CO2 level status
    var co2Status: CO2Level {
        if co2 < 1000 {
            return .good
        } else if co2 < 1400 {
            return .moderate
        } else {
            return .poor
        }
    }
}

// MARK: - CO2 Level Status

enum CO2Level {
    case good      // < 1000 ppm
    case moderate  // 1000-1399 ppm
    case poor      // >= 1400 ppm

    var color: String {
        switch self {
        case .good: return "🟢"
        case .moderate: return "🟡"
        case .poor: return "🔴"
        }
    }
}

// MARK: - Alert Sound Type

enum AlertSoundType: String, CaseIterable {
    case off = "Off"
    case gentle = "Gentle"
    case urgent = "Urgent (Fire Alarm)"

    var displayName: String {
        return self.rawValue
    }
}

// MARK: - SwitchBot UUIDs

struct SwitchBotUUIDs {
    // SwitchBot's registered BLE service UUID (0xFD3D)
    static let serviceUUID = "FD3D"
    
    // Alternative: Full 128-bit UUID format
    static let serviceUUIDFull = "0000FD3D-0000-1000-8000-00805F9B34FB"
    
    // SwitchBot manufacturer ID (used in manufacturer data)
    static let manufacturerID: UInt16 = 0x0969
    
    // Device name patterns to identify SwitchBot Meter Pro CO2
    static let deviceNamePatterns = ["WoSensorTH", "SwitchBot", "Meter"]
}
