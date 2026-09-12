import Foundation
import IOKit.pwr_mgt
import UserNotifications

/// Local notifications ("Restore complete") and keeping the Mac awake during long setup steps.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Prevents idle sleep while held (downloads and restores take a long time).
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func begin(reason: String) {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason as CFString, &assertionID) == kIOReturnSuccess
    }

    func end() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit { end() }
}
