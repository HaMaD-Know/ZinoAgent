import SwiftUI
import BackgroundTasks

@main
public struct ZinoAgentApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        registerBackgroundTasks()
    }

    public var body: some Scene {
        WindowGroup {
            RootNavigationView(coordinator: coordinator)
                .preferredColorScheme(coordinator.settings.appearance.colorScheme)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        coordinator.resourceMonitor.refresh()
                        coordinator.refreshStorage()
                    case .background:
                        scheduleMaintenanceTask()
                    default:
                        break
                    }
                }
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConfiguration.maintenanceBackgroundTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            processingTask.expirationHandler = {
                processingTask.setTaskCompleted(success: false)
            }
            let paths = AppStoragePaths()
            _ = try? paths.clearSafeCaches()
            processingTask.setTaskCompleted(success: true)
        }
    }

    private func scheduleMaintenanceTask() {
        let request = BGProcessingTaskRequest(identifier: AppConfiguration.maintenanceBackgroundTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
