import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("PSTE: не удалось изменить автозапуск — \(error.localizedDescription)")
            }
        }
    }
}
