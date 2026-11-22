import Foundation
import UIKit
import Combine
import os

public enum ThermalLevel: String, Sendable {
    case nominal, fair, serious, critical, unknown

    public var displayName: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    public var isElevated: Bool {
        self == .serious || self == .critical
    }
}

public enum MemoryPressureLevel: String, Sendable {
    case normal, warning, critical
}

public struct SystemResourceSnapshot: Sendable, Equatable {
    public let physicalMemoryBytes: UInt64
    public let appFootprintBytes: Int64
    public let availableHeadroomBytes: UInt64
    public let thermalLevel: ThermalLevel
    public let memoryPressure: MemoryPressureLevel
    public let lowPowerMode: Bool
    public let processorCount: Int
    public let deviceModelIdentifier: String
    public let systemVersion: String
    public let timestamp: Date

    public var isLowMemoryHeadroom: Bool {
        availableHeadroomBytes > 0 && availableHeadroomBytes < 900 * 1024 * 1024
    }
}

/// Monitors iPadOS RAM footprint, `os_proc_available_memory()`, thermal state, and memory pressure events.
@MainActor
public final class SystemResourceMonitor: ObservableObject {
    @Published public private(set) var snapshot: SystemResourceSnapshot
    @Published public private(set) var lastMemoryWarningDate: Date?

    public var onCriticalMemoryPressure: (() -> Void)?

    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    public init() {
        self.snapshot = Self.captureSnapshot(memoryPressure: .normal)
        startMonitoring()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pressureSource?.cancel()
        timer?.invalidate()
    }

    public func refresh() {
        snapshot = Self.captureSnapshot(memoryPressure: snapshot.memoryPressure)
    }

    private func startMonitoring() {
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastMemoryWarningDate = Date()
                    self.snapshot = Self.captureSnapshot(memoryPressure: .critical)
                    AppLogger.shared.warning("Resources", "iOS memory warning received. Headroom: \(Formatters.bytes(Int64(self.snapshot.availableHeadroomBytes)))")
                    self.onCriticalMemoryPressure?()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.snapshot = Self.captureSnapshot(memoryPressure: self.snapshot.memoryPressure)
                    AppLogger.shared.info("Resources", "Thermal state changed to \(self.snapshot.thermalLevel.displayName)")
                }
            }
        )

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, let src = self.pressureSource else { return }
                let level: MemoryPressureLevel
                if src.data.contains(.critical) {
                    level = .critical
                } else if src.data.contains(.warning) {
                    level = .warning
                } else {
                    level = .normal
                }
                self.snapshot = Self.captureSnapshot(memoryPressure: level)
                if level == .critical {
                    self.onCriticalMemoryPressure?()
                }
            }
        }
        source.resume()
        self.pressureSource = source

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public nonisolated static func captureSnapshot(memoryPressure: MemoryPressureLevel = .normal) -> SystemResourceSnapshot {
        let pi = ProcessInfo.processInfo
        let thermal: ThermalLevel
        switch pi.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }

        return SystemResourceSnapshot(
            physicalMemoryBytes: pi.physicalMemory,
            appFootprintBytes: currentAppFootprint(),
            availableHeadroomBytes: UInt64(os_proc_available_memory()),
            thermalLevel: thermal,
            memoryPressure: memoryPressure,
            lowPowerMode: pi.isLowPowerModeEnabled,
            processorCount: pi.activeProcessorCount,
            deviceModelIdentifier: deviceModel(),
            systemVersion: pi.operatingSystemVersionString,
            timestamp: Date()
        )
    }

    public nonisolated static func currentAppFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    public nonisolated static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
