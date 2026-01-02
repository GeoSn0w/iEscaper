import Foundation
import Combine

@MainActor
class MobileGestaltManager: ObservableObject {
    @Published var devices: [Device] = []
    @Published var logEntries: [LogEntry] = []
    
    @Published var isRunning = false
    func refreshDevices() {
        log("Refreshing device list...", level: .info)
        
        Task {
            do {
                let detectedDevices = try await GeoiDeviceManager.shared.listDevices()
                self.devices = detectedDevices
                
                if detectedDevices.isEmpty {
                    log("No devices found. Please connect your iOS device.", level: .warning)
                } else {
                    log("Found \(detectedDevices.count) device(s)", level: .success)
                }
            } catch {
                log("Error listing devices: \(error.localizedDescription)", level: .error)
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var currentTask: Task<Void, Never>?
    
    private let iPadKeys = ["uKc7FPnEO++lVhHWHFlGbQ","mG0AnH/Vy1veoqoLRAIgTA","UCG5MkVahJxG1YULbbd5Bg","ZYqko/XM5zD3XBfN5RmaXA","nVh/gwNpy7Jv1NOk00CMrw","qeaj75wk3HF4DwQ8qbIi7g"]
    
    func log(_ message: String, level: LogLevel = .normal) {
        let entry = LogEntry(message: message, level: level)
        logEntries.append(entry)
    }
    
    
    func validateAndPrepare(deviceID: UUID?, fileURL: URL?, operation: PatchOperation) async -> String? {
        guard let deviceID = deviceID,
              let device = devices.first(where: { $0.id == deviceID }),
              let fileURL = fileURL else {
            return nil
        }
        
        do {
            guard fileURL.startAccessingSecurityScopedResource() else {
                log("Failed to access file", level: .error)
                return nil
            }
            defer { fileURL.stopAccessingSecurityScopedResource() }
            
            let data = try Data(contentsOf: fileURL)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            
            guard let cacheExtra = plist?["CacheExtra"] as? [String: Any] else {
                log("Error: Invalid com.apple.MobileGestalt.plist file", level: .error)
                return nil
            }
            
            let cacheBuildVersion = plist?["CacheVersion"] as? String
            let cacheProductType = cacheExtra["0+nc/Udy4WNG8S+Q7a/s1A"] as? String
            
            if cacheBuildVersion != device.buildVersion || cacheProductType != device.productType {
                log("Warning: MobileGestalt file may be for a different device", level: .warning)
                log("Device Build: \(device.buildVersion), MobileGestalt Build: \(cacheBuildVersion ?? "unknown")", level: .warning)
                
                log("Device ProductType: \(device.productType), MobileGestalt ProductType: \(cacheProductType ?? "unknown")", level: .warning)
                
                return "MobileGestalt file may be for a different device.\n\nDevice Build: \(device.buildVersion)\nMobileGestalt Build: \(cacheBuildVersion ?? "unknown")\n\nDevice ProductType: \(device.productType)\nMobileGestalt ProductType: \(cacheProductType ?? "unknown")\n\nContinue anyway?"
            }
            
            return nil
        } catch {
            log("Error validating file: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
    
    func startPatch(deviceID: UUID?, fileURL: URL?, operation: PatchOperation, offset: String) async {
        guard let deviceID = deviceID,
              let device = devices.first(where: { $0.id == deviceID }),
              let fileURL = fileURL else {
            return
        }
        
        isRunning = true
        
        currentTask = Task {
            do {
                try await GeoiDeviceManager.shared.checkPythonAvailabilityOnMac(logger: self)
                
                try await GeoiDeviceManager.shared.prepareTunneliOS17(device: device, logger: self)
                
                log("Checking developer mode...", level: .info)
                let developerModeEnabled = try await GeoiDeviceManager.shared.isDeveloperModeOn(device: device)
                
                if !developerModeEnabled {
                    log("DEVELOPER MODE NOT ENABLED!", level: .error)
                    log("Please enable Developer Mode on your device:", level: .error)
                    
                    log("1. Go to Settings > Privacy & Security", level: .error)
                    log("2. Scroll down to Developer Mode", level: .error)
                    log("3. Enable Developer Mode and restart your device", level: .error)
                    log("This is required for the exploit to work.", level: .error)
                        isRunning = false
                    return
                }
                
                log("Developer mode is enabled - proceeding with exploit", level: .success)
                log("Got device: \(device.model) (iOS \(device.version), Build \(device.buildVersion))", level: .info)
                log("Please keep your device unlocked during the process.", level: .warning)
                
                guard fileURL.startAccessingSecurityScopedResource() else {
                    log("Failed to access file", level: .error)
                    isRunning = false
                    return
                }
                defer { fileURL.stopAccessingSecurityScopedResource() }
                
                let modifiedURL = try await modifyMobileGestalt(
                    sourceURL: fileURL,
                    operation: operation,
                    offset: offset
                )
                
                if Task.isCancelled {
                    log("Patch cancelled", level: .warning)
                    isRunning = false
                    return
                }
                
                try await ExploitChain.shared.executeExploit(
                    device: device,
                    modifiedPlistURL: modifiedURL,
                    logger: self
                )
                
            } catch {
                log("Error: \(error.localizedDescription)", level: .error)
            }
            
            isRunning = false
        }
    }
    
    func stopPatch() {
        currentTask?.cancel()
        currentTask = nil
        
        isRunning = false
        
        log("Patch stopped by user", level: .warning)
    }
    
    private func modifyMobileGestalt(sourceURL: URL, operation: PatchOperation, offset: String) async throws -> URL {
        let data = try Data(contentsOf: sourceURL)
        var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        
        guard var plist = plist else {
            throw NSError(domain: "MobileGestaltManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid plist format"])
        }
        
        if operation == .enableIPad || operation == .restoreIPhone {
            var parsedOffset: Int?
            
            if !offset.isEmpty {
                if let hexValue = Int(offset.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: ""), radix: 16) {
                    parsedOffset = hexValue
                    log("Using offset: \(hexValue) (0x\(String(hexValue, radix: 16)))", level: .success)
                } else if let decValue = Int(offset) {
                    parsedOffset = decValue
                    log("Using offset: \(decValue) (0x\(String(decValue, radix: 16)))", level: .success)
                } else {
                    log("Invalid offset format, skipping CacheData modification", level: .warning)
                }
            }
            
            if operation == .enableIPad {
                if let offset = parsedOffset {
                    if try writeIPadToDeviceClass(plist: &plist, offset: offset) {
                        log("iPad mode enabled", level: .success)
                    } else {
                        log("Failed to enable iPad mode", level: .error)
                        throw NSError(domain: "MobileGestaltManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to enable iPad mode"])
                    }
                } else {
                    var cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
                    for key in iPadKeys {
                        cacheExtra[key] = 1
                    }
                    plist["CacheExtra"] = cacheExtra
                    log("iPad mode enabled (CacheExtra only - may not fully work without CacheData)", level: .warning)
                }
            } else if operation == .restoreIPhone {
                if let offset = parsedOffset {
                    if try restoreIPhoneDeviceClass(plist: &plist, offset: offset) {
                        log("iPhone mode restored", level: .success)
                    } else {
                        log("Failed to restore iPhone mode", level: .error)
                        throw NSError(domain: "MobileGestaltManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to restore iPhone mode"])
                    }
                } else {
                    var cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
                    for key in iPadKeys {
                        cacheExtra.removeValue(forKey: key)
                    }
                    plist["CacheExtra"] = cacheExtra
                    log("iPhone mode restored (CacheExtra only)", level: .warning)
                }
            }
        } else {
            log("Using file as-is", level: .info)
        }
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("modified_mg.plist")
        let outputData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try outputData.write(to: outputURL)
        
        log("SUCCESS: Modified MobileGestalt saved to: \(outputURL.path)", level: .success)
         return outputURL
    }
    
        private func writeIPadToDeviceClass(plist: inout [String: Any], offset: Int) throws -> Bool {
        guard var cacheData = plist["CacheData"] as? Data else {
            log("Error: CacheData not found in MobileGestalt", level: .error)
            return false
        }
        
        if offset >= cacheData.count - 8 {
            log("Error: Offset \(offset) is beyond CacheData bounds (\(cacheData.count) bytes)", level: .error)
            return false
        }
        
        var currentValue: UInt64 = 0
        cacheData.withUnsafeBytes { buffer in
            currentValue = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        
        let deviceType = currentValue == 1 ? "iPhone" : (currentValue == 3 ? "iPad" : "Unknown")
        log("Current DeviceClassNumber value: \(currentValue) (\(deviceType))", level: .info)
        
        var mutableData = cacheData
        mutableData.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: UInt64(3), toByteOffset: offset, as: UInt64.self)
        }
        
        var newValue: UInt64 = 0
        mutableData.withUnsafeBytes { buffer in
            newValue = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        log("New DeviceClassNumber value: \(newValue) (iPad)", level: .success)
        
        plist["CacheData"] = mutableData
        
        var cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
        for key in iPadKeys {
             cacheExtra[key] = 1
        }
        plist["CacheExtra"] = cacheExtra
        
        log("Successfully wrote iPad device class to MobileGestalt", level: .success)
        return true
    }
    
    private func restoreIPhoneDeviceClass(plist: inout [String: Any], offset: Int) throws -> Bool {
        guard var cacheData = plist["CacheData"] as? Data else {
            log("Error: CacheData not found in MobileGestalt", level: .error)
            
             return false
        }
        
        if offset >= cacheData.count - 8 {
            log("Error: Offset \(offset) is beyond CacheData bounds (\(cacheData.count) bytes)", level: .error)
            return false
        }
        var currentValue: UInt64 = 0
        cacheData.withUnsafeBytes { buffer in
        currentValue = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        log("Current DeviceClassNumber value: \(currentValue)", level: .info)
        
            var mutableData = cacheData
        
        mutableData.withUnsafeMutableBytes { buffer in
         buffer.storeBytes(of: UInt64(1), toByteOffset: offset, as: UInt64.self)
        }
        
        var newValue: UInt64 = 0
        mutableData.withUnsafeBytes { buffer in
          newValue = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        log("New DeviceClassNumber value: \(newValue) (iPhone)", level: .success)
        
        plist["CacheData"] = mutableData
        
        var cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
        for key in iPadKeys {
          cacheExtra.removeValue(forKey: key)
        }
        plist["CacheExtra"] = cacheExtra
        
          log("Successfully restored iPhone device class to MobileGestalt", level: .success)
        return true
    }
}
