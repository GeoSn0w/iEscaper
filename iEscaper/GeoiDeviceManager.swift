import Foundation

class GeoiDeviceManager {
    static let shared = GeoiDeviceManager()
    
    private var py: String?
    private var alldone = false
    private var tunnelPID: Int?
    
    private var rsdAddress: String?
    
    private var rsdPort: Int?
    
    private init() {
        idevice_set_debug_level(0)
    }
    
    deinit {
        stopTunnel()
    }
    
    
    func checkPythonAvailabilityOnMac(logger: MobileGestaltManager) async throws {
        if alldone {
            return
        }
        try await isPyAvailable(logger: logger)
        await logger.log("Checking environment...", level: .info)
        py = checkPyAndLibs()
        
        if py == nil {
             await logger.log("Woah. Required libs not found, installing...", level: .warning)
             try await checkPymobiledevice3OnMac(logger: logger)
             py = checkPyAndLibs()
            
             guard py != nil else {
                await logger.log("Failed to install the necessary libs. Bailing.", level: .error)
                
                
                throw NSError(domain: "DeviceManager", code: 100, userInfo: [NSLocalizedDescriptionKey: "Failed to install the necessary libs. Bailing."])
            }
        }
        
        await logger.log("[OK] The necessary shit is available now.", level: .success)
        alldone = true
    }
    
    func prepareTunneliOS17(device: Device, logger: MobileGestaltManager) async throws {
        let version = device.version.split(separator: ".").first.flatMap { Int($0) } ?? 0
        
        if version >= 17 {
            await logger.log("This device is using iOS 17 or newer, starting RemoteXPC tunnel...", level: .info)
            
            await logger.log("You will be prompted for your password (administrator access required)", level: .warning)
            try await startTunnel(udid: device.udid, logger: logger)
        }
    }
    
    private func startTunnel(udid: String, logger: MobileGestaltManager) async throws {
        guard let py = py else {
            throw NSError(domain: "DeviceManager", code: 200, userInfo: [NSLocalizedDescriptionKey: "Python not found"])
        }
        stopTunnel()
        
        return try await withCheckedThrowingContinuation { continuation in
             DispatchQueue.global(qos: .utility).async {
                 let epy = py.replacingOccurrences(of: "'", with: "'\\''")
                 let eudid = udid.replacingOccurrences(of: "'", with: "'\\''")
                
                 let script = """
                 do shell script "'\(epy)' -m pymobiledevice3 remote start-tunnel --script-mode --udid '\(eudid)' > /tmp/iescaper_tunnel.log 2>&1 & echo $! > /tmp/iescaper_tunnel.pid" with administrator privileges
                 """
                 let proc = Process()
                 proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                 proc.arguments = ["-e", script]
                 
                 let pipe = Pipe()
                 proc.standardOutput = pipe
                 proc.standardError = pipe
                
                do {
                   try proc.run()
                    proc.waitUntilExit()
                    
                    if proc.terminationStatus != 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                        
                        Task { @MainActor in
                            await logger.log("Tunnel err: \(output)", level: .error)
                        }
                        
                        continuation.resume(throwing: NSError(domain: "DeviceManager", code: 201, userInfo: [NSLocalizedDescriptionKey: "Failed to authenticate or start tunnel"]))
                        return
                    }
                    
                    Task { @MainActor in
                        await logger.log("Tunnel started, waiting for connection...", level: .info)
                    }
                    
                    var resolved = false
                    var tries = 0
                    let maxAttempts = 60
                    
                    while !resolved && tries < maxAttempts {
                        tries += 1
                        
                        if let logContents = try? String(contentsOfFile: "/tmp/iescaper_tunnel.log", encoding: .utf8) {
                            let lines = logContents.components(separatedBy: .newlines)
                            
                            for line in lines.reversed() {
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.isEmpty { continue }
                                
                                let components = trimmed.split(separator: " ")
                                if components.count == 2,
                                   let port = Int(components[1]) {
                                    self.rsdAddress = String(components[0])
                                    self.rsdPort = port
                                    
                                    Task { @MainActor in
                                        await logger.log("Tunnel established: \(self.rsdAddress!):\(self.rsdPort!)", level: .success)
                                    }
                                    
                                    resolved = true
                                    
                                    if let pidStr = try? String(contentsOfFile: "/tmp/iescaper_tunnel.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                                       let pid = Int(pidStr) {
                                        self.tunnelPID = pid
                                    }
                                    
                                    continuation.resume(returning: ())
                                    return
                                }
                                
                                if trimmed.contains("error") || trimmed.contains("Error") || trimmed.contains("Failed") {
                                    Task { @MainActor in
                                        await logger.log("Tunnel error: \(trimmed)", level: .error)
                                    }
                                    resolved = true
                                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: 202, userInfo: [NSLocalizedDescriptionKey: "Tunnel failed: \(trimmed)"]))
                                    return
                                }
                            }
                        }
                        
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    
                    if !resolved {
                        continuation.resume(throwing: NSError(domain: "DeviceManager", code: 203, userInfo: [NSLocalizedDescriptionKey: "Tunnel setup timeout - could not read tunnel address"]))
                    }
                    
                } catch {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: 204, userInfo: [NSLocalizedDescriptionKey: "Failed to start tunnel: \(error.localizedDescription)"]))
                }
            }
        }
    }
    
    private func stopTunnel() {
        if let pid = tunnelPID {
            let killProcess = Process()
            killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            killProcess.arguments = ["kill", "-9", String(pid)]
            try? killProcess.run()
        }
        
        if let pidStr = try? String(contentsOfFile: "/tmp/iescaper_tunnel.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int(pidStr) {
            let killProcess = Process()
            killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            killProcess.arguments = ["kill", "-9", String(pid)]
            try? killProcess.run()
        }
        
        try? FileManager.default.removeItem(atPath: "/tmp/iescaper_tunnel.log")
        try? FileManager.default.removeItem(atPath: "/tmp/iescaper_tunnel.pid")
        tunnelPID = nil
        rsdAddress = nil
        rsdPort = nil
    }
    
    private func checkPyAndLibs() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3","/Library/Frameworks/Python.framework/Versions/Current/bin/python3","/Library/Frameworks/Python.framework/Versions/3.11/bin/python3","/Library/Frameworks/Python.framework/Versions/3.10/bin/python3","/Library/Frameworks/Python.framework/Versions/3.9/bin/python3"
        ]
        
        for path in possiblePaths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(path) -c 'import pymobiledevice3' 2>/dev/null"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    return path
                }
            } catch {
                continue
            }
        }
        
        
        return nil
    }
    
    
    private func isPyAvailable(logger: MobileGestaltManager) async throws {
        let chkprog = Process()
        chkprog.executableURL = URL(fileURLWithPath: "/bin/sh")
        chkprog.arguments = ["-c", "python3 --version 2>&1"]
        let pipe = Pipe()
        chkprog.standardOutput = pipe
        chkprog.standardError = pipe
        
        do {
            try chkprog.run()
            chkprog.waitUntilExit()
            
            if chkprog.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), output.contains("Python 3") {
                    await logger.log("Found functional environment", level: .info)
                    return
                }
            }
        } catch {
            
        }
        
        await logger.log("python3 not found, installing via homebrew...", level: .warning)
        
        let brchk = Process()
        brchk.executableURL = URL(fileURLWithPath: "/bin/sh")
        brchk.arguments = ["-c", "which brew"]
        let brewPipe = Pipe()
        brchk.standardOutput = brewPipe
        
        var hazbrew = false
        do {
            try brchk.run()
            brchk.waitUntilExit()
            hazbrew = brchk.terminationStatus == 0
        } catch {}
        
        if !hazbrew {
            await logger.log("Homebrew not installed either. Well... I tried. Install HomeBrew first from brew.sh", level: .error)
            throw NSError(domain: "DeviceManager", code: 99, userInfo: [NSLocalizedDescriptionKey: "Need homebrew to install python3"])
        }
        

         await logger.log("installing python3 with homebrew, this might take a minute...", level: .info)
         let intsallprog = Process()
         intsallprog.executableURL = URL(fileURLWithPath: "/bin/sh")
         intsallprog.arguments = ["-c", "brew install python3 2>&1"]
         let inpipe = Pipe()
         intsallprog.standardOutput = pipe
         intsallprog.standardError = pipe
        
        do {
            try intsallprog.run()
            intsallprog.waitUntilExit()
            
            if intsallprog.terminationStatus == 0 {
                await logger.log("[OK] Python3 installed successfully", level: .success)
            } else {
                let data = inpipe.fileHandleForReading.readDataToEndOfFile()
                
                let output = String(data: data, encoding: .utf8) ?? "unknown error"
                await logger.log("Failed to install python3: \(output)", level: .error)
                throw NSError(domain: "DeviceManager", code: 98, userInfo: [NSLocalizedDescriptionKey: "Python3 installation failed"])
            }
        } catch {
             await logger.log("something went wrong installing python3", level: .error)
             throw error
        }
    }
    
    private func checkPymobiledevice3OnMac(logger: MobileGestaltManager) async throws {
        let paths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            //"/usr/bin/python2",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
        ]
        
        var isavailable = false
        
            for pypath in paths {
                guard FileManager.default.fileExists(atPath: pypath) else {
                    continue
                }
                
                await logger.log("Attempting installation with \(pypath)...", level: .info)
                
                let pipCommands = [
                    "\(pypath) -m pip install --upgrade pip --break-system-packages 2>&1","\(pypath) -m pip install pymobiledevice3 --break-system-packages 2>&1"
                ]
                
                var allSucceeded = true
                
                for cmd in pipCommands {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", cmd]
                    
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    
                    do {
                        try process.run()
                        
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: data, encoding: .utf8) {
                            if output.contains("Successfully installed") {
                                
                                await logger.log("Installation progress: \(output.components(separatedBy: "\n").last ?? "")", level: .info)
                            }
                        }
                        
                        process.waitUntilExit()
                        if process.terminationStatus != 0 {
                            allSucceeded = false
                            break
                        }
                    } catch {
                        allSucceeded = false
                        break
                    }
                }
                
                if allSucceeded {
                    isavailable = true
                    await logger.log("Successfully installed pymobiledevice3", level: .success)
                    break
                }
        }
        
        if !isavailable {
             await logger.log("Could not install pymobiledevice3 automatically", level: .error)
             await logger.log("Please install manually: pip3 install pymobiledevice3", level: .error)
             throw NSError(domain: "DeviceManager", code: 101, userInfo: [NSLocalizedDescriptionKey: "Installation failed"])
        }
    }
    
    func isDeveloperModeOn(device: Device) async throws -> Bool {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var idev: idevice_t?
                    
                    var client: lockdownd_client_t?
                    
                    guard idevice_new(&idev, device.udid) == IDEVICE_E_SUCCESS else {
                        continuation.resume(returning: false)
                        
                        return
                    }
                    
                    defer {
                         if client != nil { lockdownd_client_free(client) }
                         if idev != nil { idevice_free(idev) }
                    }
                    
                    guard lockdownd_client_new_with_handshake(idev, &client, "iEscaper") == LOCKDOWN_E_SUCCESS else {
                        continuation.resume(returning: false)
                        
                        return
                    }
                    
                     var service: lockdownd_service_descriptor_t?
                    let result = lockdownd_start_service(client, "com.apple.afc", &service)
                    
                    continuation.resume(returning: result == LOCKDOWN_E_SUCCESS)
                }
            }
    }
    
    func listDevices() async throws -> [Device] {
        return try await withCheckedThrowingContinuation { continuation in
            var devices: [Device] = []
            
            var deviceList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            
            var count: Int32 = 0
            
            let result = idevice_get_device_list(&deviceList, &count)
            
            guard result == IDEVICE_E_SUCCESS, let list = deviceList else {
                continuation.resume(throwing: NSError(domain: "DeviceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "No devices found"]))
                return
            }
            
            for i in 0..<Int(count) {
                if let udidPtr = list[i], let udidStr = String(cString: udidPtr, encoding: .utf8) {
                    
                    if let device = try? self.deviceinfosync(udid: udidStr) {
                        
                        devices.append(device)
                        
                    }
                }
            }
            idevice_device_list_free(list)
            continuation.resume(returning: devices)
        }
    }
    
    private func deviceinfosync(udid: String) throws -> Device {
         var device: idevice_t?
        
         var client: lockdownd_client_t?
        
         guard idevice_new(&device, udid) == IDEVICE_E_SUCCESS else {
             throw NSError(domain: "DeviceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to device"])
         }
        
         defer {
            if client != nil {
                lockdownd_client_free(client)
            }
            if device != nil {
                idevice_free(device)
            }
         }
        
          guard lockdownd_client_new_with_handshake(device, &client, "iEscaper") == LOCKDOWN_E_SUCCESS else {
            throw NSError(domain: "DeviceManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create lockdown client"])
          }
            var deviceNamePtr: UnsafeMutablePointer<CChar>?
            lockdownd_get_device_name(client, &deviceNamePtr)
            let name = deviceNamePtr != nil ? String(cString: deviceNamePtr!) : "Unknown"
            if deviceNamePtr != nil { free(deviceNamePtr) }
            var productTypePlist: plist_t?
            var productVersionPlist: plist_t?
            var buildVersionPlist: plist_t?
            var mname: plist_t?
            lockdownd_get_value(client, nil, "ProductType", &productTypePlist)
            lockdownd_get_value(client, nil, "ProductVersion", &productVersionPlist)
            lockdownd_get_value(client, nil, "BuildVersion", &buildVersionPlist)
            lockdownd_get_value(client, nil, "MarketingName", &mname)
            
            func plistToString(_ plist: plist_t?) -> String {
                guard let plist = plist else { return "Unknown" }
                var cstr: UnsafeMutablePointer<CChar>?
                plist_get_string_val(plist, &cstr)
                let result = cstr != nil ? String(cString: cstr!) : "Unknown"
                if cstr != nil { free(cstr) }
                plist_free(plist)
                
                return result
            }
        
        let model = plistToString(mname)
        let version = plistToString(productVersionPlist)
        let build = plistToString(buildVersionPlist)
        
        let product = plistToString(productTypePlist)
        
        return Device(udid: udid, name: name, model: model, version: version, buildVersion: build, productType: product)
    }
    
    func uploadFile(to device: Device, localPath: String, remotePath: String) async throws {
         var idev: idevice_t?
         var client: lockdownd_client_t?
         var afc: afc_client_t?
        
        guard idevice_new(&idev, device.udid) == IDEVICE_E_SUCCESS else {
             throw NSError(domain: "DeviceManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Can't connect to device"])
        }
        
        defer {
             if afc != nil { afc_client_free(afc) }
             if client != nil { lockdownd_client_free(client) }
             if idev != nil { idevice_free(idev) }
        }
        
        guard lockdownd_client_new_with_handshake(idev, &client, "iEscaper") == LOCKDOWN_E_SUCCESS else {
            throw NSError(domain: "DeviceManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Can't create lockdown client"])
        }
        
        var service: lockdownd_service_descriptor_t?
        guard lockdownd_start_service(client, "com.apple.afc", &service) == LOCKDOWN_E_SUCCESS else {
            throw NSError(domain: "DeviceManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Can't start AFC service"])
        }
        guard afc_client_new(idev, service, &afc) == AFC_E_SUCCESS else {
            throw NSError(domain: "DeviceManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Can't create AFC client"])
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: localPath))
        
        var afcFile: UInt64 = 0
        guard afc_file_open(afc, remotePath, AFC_FOPEN_WRONLY, &afcFile) == AFC_E_SUCCESS else {
            throw NSError(domain: "DeviceManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Can't open remote file"])
        }
        
        defer {
            afc_file_close(afc, afcFile)
        }
        
        try fileData.withUnsafeBytes { buffer in
            guard let baseAddy = buffer.baseAddress else {
                throw NSError(domain: "DeviceManager", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid file data"])
            }
            var bytesrw: UInt32 = 0
            let result = afc_file_write(afc, afcFile, baseAddy.assumingMemoryBound(to: CChar.self), UInt32(buffer.count), &bytesrw)
            
            guard result == AFC_E_SUCCESS else {
                throw NSError(domain: "DeviceManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to write file"])
            }
        }
    }
    
    func launchAppPrimitive(udid: String, bundleId: String) async throws {
        guard let py = py else {
            throw NSError(domain: "DeviceManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "Python with pymobiledevice3 not found"])
        }
        
        guard let addy = rsdAddress, let port = rsdPort else {
            throw NSError(domain: "DeviceManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Tunnel not established"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                 let proc = Process()
                 proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                 proc.arguments = ["-c", "\(py) -m pymobiledevice3 developer dvt launch \(bundleId) --rsd \(addy) \(port) 2>&1"]
                
                 let pipe = Pipe()
                 proc.standardOutput = pipe
                 proc.standardError = pipe
                
                 do {
                    try proc.run()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    proc.waitUntilExit()
                    
                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: NSError(domain: "DeviceManager", code: 13, userInfo: [NSLocalizedDescriptionKey: "Can't launch app: \(output)"]))
                    }
                } catch {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: 14, userInfo: [NSLocalizedDescriptionKey: "can't execute pymobiledevice3: \(error.localizedDescription)"]))
                }
            }
        }
    }
    
    
    
    func killProcessPrimitive(udid: String, pid: Int) async throws {
        guard let py = py else {
            throw NSError(domain: "DeviceManager", code: 15, userInfo: [NSLocalizedDescriptionKey: "Python with pymobiledevice3 not found"])
        }
        
        guard let addy = rsdAddress, let port = rsdPort else {
            throw NSError(domain: "DeviceManager", code: 16, userInfo: [NSLocalizedDescriptionKey: "Tunnel not established"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                
                proc.arguments = ["-c", "\(py) -m pymobiledevice3 developer dvt kill \(pid) --rsd \(addy) \(port) 2>&1"]
                
                
                 let pipe = Pipe()
                 proc.standardOutput = pipe
                 proc.standardError = pipe
                
                 do {
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: ())
                 } catch {
                    continuation.resume(returning: ())
                 }
             }
         }
     }
    
    func getProcessListPrimitive(udid: String, logger: MobileGestaltManager? = nil) async throws -> [String: [String: Any]] {
        guard let py = py else {
            throw NSError(domain: "DeviceManager", code: 17, userInfo: [NSLocalizedDescriptionKey: "Python with pymobiledevice3 not found"])
        }
        
        guard let addy = rsdAddress, let port = rsdPort else {
            if let logger = logger {
                Task { @MainActor in
                    await logger.log("ERROR: Tunnel not established. Address: \(rsdAddress ?? "nil"), Port: \(rsdPort?.description ?? "nil")", level: .error)
                }
            }
            throw NSError(domain: "DeviceManager", code: 18, userInfo: [NSLocalizedDescriptionKey: "Tunnel not established"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let command = "\(py) -m pymobiledevice3 developer dvt proclist --rsd \(addy) \(port) 2>&1"
                
                Task { @MainActor in
                    if let logger = logger {
                        await logger.log("Executing: \(command)", level: .info)
                    }
                }
                
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", command]
                
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                
                
                do {
                    try proc.run()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    
                    let output = String(data: data, encoding: .utf8) ?? ""
                    
                    Task { @MainActor in
                        if let logger = logger {
                            await logger.log("Exit code: \(proc.terminationStatus)", level: .info)
                            
                        }
                    }
                    
                     if proc.terminationStatus == 0 {
                         var procs: [String: [String: Any]] = [:]
                        
                         if let jsonData = output.data(using: .utf8),
                           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] {
                            
                            for procinfo in jsonArray {
                                if let pid = procinfo["pid"] as? Int,
                                   let name = procinfo["name"] as? String {
                                    procs[String(pid)] = ["ProcessName": name]
                                }
                            }
                            
                            Task { @MainActor in
                                if let logger = logger {
                                    await logger.log("Found \(procs.count) processes", level: .success)
                                }
                            }
                        } else {
                            Task { @MainActor in
                                if let logger = logger {
                                    await logger.log("Failed to parse JSON output", level: .error)
                                }
                            }
                        }
                        
                        continuation.resume(returning: procs)
                    } else {
                        continuation.resume(returning: [:])
                    }
                } catch {
                     Task { @MainActor in
                         if let logger = logger {
                            
                            await logger.log("Exception: \(error)", level: .error)
                         }
                     }
                     continuation.resume(returning: [:])
                }
            }
        }
    }
    
    func suspendProcessPrimitive(udid: String, pid: Int) async throws {
        guard let addy = rsdAddress, let port = rsdPort else {
            throw NSError(domain: "DeviceManager", code: 20, userInfo: [NSLocalizedDescriptionKey: "Tunnel not established"])
        }
        guard let py = py else {
            throw NSError(domain: "DeviceManager", code: 19, userInfo: [NSLocalizedDescriptionKey: "Python with pymobiledevice3 not found"])
        }
        
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
    
                proc.arguments = ["-c", "\(py) -m pymobiledevice3 developer dvt signal \(pid) 19 --rsd \(addy) \(port) 2>&1"]
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    
    func awaitsyslogShit(udid: String, handler: @escaping (String) -> Bool) async throws {
        return try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
                var idev: idevice_t?
                var client: lockdownd_client_t?
                var syslog: syslog_relay_client_t?
                
                guard idevice_new(&idev, udid) == IDEVICE_E_SUCCESS else {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "Can't connect to device"]))
                    return
                }
                
                defer {
                    if syslog != nil { syslog_relay_client_free(syslog) }
                    if client != nil { lockdownd_client_free(client) }
                    if idev != nil { idevice_free(idev) }
                }
                
                 guard lockdownd_client_new_with_handshake(idev, &client, "iEscaper") == LOCKDOWN_E_SUCCESS else {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "Can't create lockdown client"]))
                    return
                 }
                
                 var service: lockdownd_service_descriptor_t?
                
                 guard lockdownd_start_service(client, "com.apple.syslog_relay", &service) == LOCKDOWN_E_SUCCESS else {
                     continuation.resume(throwing: NSError(domain: "DeviceManager", code: 23, userInfo: [NSLocalizedDescriptionKey: "syslog service err"]))
                     return
                 }
                 guard syslog_relay_client_new(idev, service, &syslog) == SYSLOG_RELAY_E_SUCCESS else {
                     continuation.resume(throwing: NSError(domain: "DeviceManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "Failed to create syslog client"]))
                     return
                 }
                
                syslog_relay_start_capture(syslog, nil, nil)
                
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                
                var isend = false
                while !isend {
                    var bytesRead: UInt32 = 0
                    let r = syslog_relay_receive_with_timeout(syslog, buffer, UInt32(bufferSize), &bytesRead, 1000)
                    
                    if r == SYSLOG_RELAY_E_SUCCESS && bytesRead > 0 {
                        if let line = String(bytesNoCopy: buffer, length: Int(bytesRead), encoding: .utf8, freeWhenDone: false) {
                            let lines = line.components(separatedBy: .newlines)
                            
                            for logLine in lines where !logLine.isEmpty {
                                if handler(logLine) {
                                    isend = true
                                    break
                                }
                            }
                       }
                    } else if r != SYSLOG_RELAY_E_SUCCESS && r != SYSLOG_RELAY_E_TIMEOUT {
                        break
                    }
                }
                
                syslog_relay_stop_capture(syslog)
                continuation.resume(returning: ())
            }
        }
    }
}
