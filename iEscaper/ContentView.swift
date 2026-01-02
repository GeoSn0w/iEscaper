import SwiftUI

struct ContentView: View {
     @StateObject private var manager = MobileGestaltManager()
     @State private var selectedDeviceID: UUID?
    @State private var selectedFileURL: URL?
      @State private var patchOperation: PatchOperation = .useAsIs
    @State private var offsetString: String = ""
     @State private var showFilePicker = false
    @State private var showWarningAlert = false
    @State private var showDeveloperModeAlert = false
    @State private var warningMessage = ""
    
    @State private var showOffsetWarningAlert = false
    
    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            Divider()
            rightPanel
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .frame(minWidth: 800, minHeight: 400)
        .preferredColorScheme(.dark)
            .onAppear {
                Task {
                    manager.refreshDevices()
                    try? await Task.sleep(nanoseconds: 500_000_000) 
                    if selectedDeviceID == nil, let firstDevice = manager.devices.first {
                        selectedDeviceID = firstDevice.id
                    }
                }
            }
        .alert("Warning", isPresented: $showWarningAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") {
                Task {
                    await manager.startPatch(
                        deviceID: selectedDeviceID,
                        fileURL: selectedFileURL,
                        operation: patchOperation,
                        offset: offsetString
                    )
                }
            }
        } message: {
            Text(warningMessage)
        }
         .alert("Developer Mode Required", isPresented: $showDeveloperModeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Developer Mode is not enabled on your device.\n\nPlease enable it by going to:\nSettings > Privacy & Security > Developer Mode\n\nThen restart your device and try  again.")
        }
        .alert("Use Default Offset?", isPresented: $showOffsetWarningAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Use 0x330 (iOS 26)", role: .destructive) {
                offsetString = "0x330"
                performPatchWithChecks()
            }
        } message: {
            Text("No offset specified. The default offset for iOS 26 is 0x330.\n\nWARNING: This offset MAY be WRONG for your iOS version and CAN cause a bootloop!\n\nPlease BACKUP your device first and verify the correct offset for your iOS version using the Symaro MobileGestalter app.")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.propertyList, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedFileURL = url
                manager.log("Selected file: \(url.path)", level: .info)
            }
        }
    }
    
    private var leftPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerView
                    .padding(.bottom, 16)
                
                VStack(spacing: 14) {
                    deviceSelectionSection
                    fileSelectionSection
                    patchOptionsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
         .frame(width: 380)
        .background(Color(red: 0.15, green: 0.15, blue: 0.16))
    }
    
    private var rightPanel: some View {
        VStack(spacing: 0) {
            actionButtonsPanel
            
            VStack(spacing: 0) {
                HStack {
                    Text("What's going on YouTube? GeoSn0w right here and today...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "terminal")
                        .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35))
                }
                .padding(.horizontal, 16)
                 .padding(.vertical, 12)
                .background(Color(red: 0.10, green: 0.10, blue: 0.11))
                
                logContent
            }
            
            creditsPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35))
            
            Text("iEscaper")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("iOS MobileGestalt Tweaker v1.0")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
    
    private var deviceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick your device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                Picker("", selection: $selectedDeviceID) {
                     Text("Select a device...").tag(nil as UUID?)
                    ForEach(manager.devices) { device in
                        Text(device.displayName).tag(device.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(red: 0.20, green: 0.20, blue: 0.21))
                .cornerRadius(6)
                
                Button(action: {
                    manager.refreshDevices()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if selectedDeviceID == nil, let firstDevice = manager.devices.first {
                            selectedDeviceID = firstDevice.id
                        }
                    }
                })  {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Devices")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.25, green: 0.25, blue: 0.26))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRunning)
                .opacity(manager.isRunning ? 0.5 : 1.0)
            }
        }
        .padding(14)
        .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        .cornerRadius(8)
    }
    
    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MobileGestalt File")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                HStack {
                    Text(selectedFileURL?.lastPathComponent ?? "No file selected")
                        .font(.system(size: 11))
                        .foregroundColor(selectedFileURL == nil ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.20, green: 0.20, blue: 0.21))
                .cornerRadius(6)
                
                Button(action: {
                    showFilePicker = true
                }) {
                    HStack {
                        Image(systemName: "folder")
                        Text("Browse...")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.25, green: 0.25, blue: 0.26))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRunning)
                .opacity(manager.isRunning ? 0.5 : 1.0)
            }
        }
        .padding(14)
        .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        .cornerRadius(8)
    }
    
    private var patchOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tweaks (for now)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 8) {
                RadioButton(
                    title: "Enable iPadOS Mode",
                    isSelected: patchOperation == .enableIPad,
                    action: { patchOperation = .enableIPad }
                )
                
                RadioButton(
                    title: "Restore iPhone Mode",
                    isSelected: patchOperation == .restoreIPhone,
                    action: { patchOperation = .restoreIPhone }
                )
                
                RadioButton(
                    title: "Use file as-is (no modifications)",
                    isSelected: patchOperation == .useAsIs,
                    action: { patchOperation = .useAsIs }
                )
            }
            
            Rectangle()
                .fill(Color(red: 0.25, green: 0.25, blue: 0.26))
                .frame(height: 1)
                .padding(.vertical, 6)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("DeviceClassNumber Offset (hex)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                
                TextField("0x...", text: $offsetString)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.21))
                    .cornerRadius(5)
                    .disabled(manager.isRunning)
                
                Text("Optional, from Symaro MobileGestalter app")
                    .font(.system(size: 10))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
        .padding(14)
        .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        .cornerRadius(8)
    }
    
    private var actionButtonsPanel: some View {
        HStack(spacing: 12) {
            Button(action: {
                Task {
                    if (patchOperation == .enableIPad || patchOperation == .restoreIPhone) && offsetString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showOffsetWarningAlert = true
                        return
                    }
                    performPatchWithChecks()
                }
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Patch")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    manager.isRunning || selectedDeviceID == nil || selectedFileURL == nil
                        ? Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.3)
                        : Color(red: 0.95, green: 0.35, blue: 0.35)
                )
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
            .disabled(manager.isRunning || selectedDeviceID == nil || selectedFileURL == nil)
            
            Button(action: {
                manager.stopPatch()
            }) {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    !manager.isRunning
                        ? Color(red: 0.25, green: 0.25, blue: 0.26)
                        : Color(red: 0.35, green: 0.35, blue: 0.36)
                )
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
            .disabled(!manager.isRunning)
            .opacity(manager.isRunning ? 1.0 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(red: 0.15, green: 0.15, blue: 0.16))
    }
    private func performPatchWithChecks() {
        Task {
            let warning = await manager.validateAndPrepare(
                deviceID: selectedDeviceID,
                fileURL: selectedFileURL,
                operation: patchOperation
            )
            
            if let warning = warning {
                warningMessage = warning
                showWarningAlert = true
            } else {
                if let deviceID = selectedDeviceID,
                   let device = manager.devices.first(where: { $0.id == deviceID }) {
                    do {
                        let developerModeEnabled = try await GeoiDeviceManager.shared.isDeveloperModeOn(device: device)
                        if !developerModeEnabled {
                            showDeveloperModeAlert = true
                            return
                        }
                    } catch {
                        manager.log("Could not verify developer mode: \(error.localizedDescription)", level: .warning)
                    }
                }
                
                await manager.startPatch(
                    deviceID: selectedDeviceID,
                    fileURL: selectedFileURL,
                    operation: patchOperation,
                    offset: offsetString
                )
            }
        }
    }
    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(manager.logEntries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Text(entry.timestamp)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                                .frame(width: 70, alignment: .leading)
                            
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(entry.level.color)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09))
            .onChange(of: manager.logEntries.count) { _ in
                if let lastEntry = manager.logEntries.last {
                    withAnimation {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var creditsPanel: some View {
        HStack {
            Image(systemName: "c.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray.opacity(0.6))
            
            Text("Developed by GeoSn0w, Symaro LLC, 2025")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray.opacity(0.8))
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
    }
}

struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "record.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? Color(red: 0.95, green: 0.35, blue: 0.35) : .gray)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isSelected
                    ? Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.15)
                    : Color.clear
            )
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 500)
}
