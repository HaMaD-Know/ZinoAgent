import Foundation
import Capacitor
import UIKit
import os

/// Device and process resource telemetry: RAM, app footprint, memory headroom, memory
/// pressure, thermal state and storage. iPadOS decides how much memory the app may use, so
/// `availableMemory` (os_proc_available_memory) is the number that matters for model loading.
@objc(ZinoResourcesPlugin)
public class ZinoResourcesPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoResourcesPlugin"
    public let jsName = "ZinoResources"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "snapshot", returnType: CAPPluginReturnPromise)
    ]

    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    override public func load() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.notifyListeners("memoryWarning", data: self.snapshotData())
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.notifyListeners("thermalChange", data: ["thermalState": Self.thermal()])
        })
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let s = self.pressureSource else { return }
            let level = s.data.contains(.critical) ? "critical" : (s.data.contains(.warning) ? "warning" : "normal")
            var d = self.snapshotData(); d["level"] = level
            self.notifyListeners("memoryPressure", data: d)
        }
        src.resume()
        pressureSource = src
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pressureSource?.cancel()
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func snapshotData() -> [String: Any] {
        let pi = ProcessInfo.processInfo
        let storage = try? ZinoPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return [
            "physicalMemory": Double(pi.physicalMemory),
            "appFootprint": Double(Self.footprint()),
            "availableMemory": Double(os_proc_available_memory()),
            "thermalState": Self.thermal(),
            "lowPowerMode": pi.isLowPowerModeEnabled,
            "processorCount": pi.activeProcessorCount,
            "storageAvailable": Double(storage?.volumeAvailableCapacityForImportantUsage ?? -1),
            "storageTotal": Double(storage?.volumeTotalCapacity ?? -1),
            "deviceModel": Self.deviceModel(),
            "systemVersion": UIDevice.current.systemVersion,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
    }

    @objc func snapshot(_ call: CAPPluginCall) {
        call.resolve(snapshotData())
    }
}
