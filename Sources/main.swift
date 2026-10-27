import AppKit

// mac-screen-rec — record a region of your screen together with system audio.
// Programmatic AppKit application (no storyboard, no xib).

let arguments = Set(CommandLine.arguments)
let smokeTest = arguments.contains("--smoke")
let selfTest = arguments.contains("--selftest")
let uiTestSelect = arguments.contains("--uitest-select")

let app = NSApplication.shared
let controller = AppController()
let delegate = AppDelegate(controller: controller)

app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = MainMenu.build(controller: controller)

if selfTest {
    controller.runSelfTest()
} else if uiTestSelect {
    controller.runSelectUITest()
} else {
    controller.showMainWindow()
}

if smokeTest {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        print("SMOKE-OK")
        NSApp.terminate(nil)
    }
}

app.run()

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.isRecording {
            controller.finishForTermination()
            return .terminateLater
        }
        return .terminateNow
    }
}

// MARK: - Main menu

enum MainMenu {
    static func build(controller: AppController) -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem(title: "MacScreenRec", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mac Screen Recorder",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mac Screen Recorder",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mac Screen Recorder",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let recordingMenuItem = NSMenuItem(title: "Recording", action: nil, keyEquivalent: "")
        let recordingMenu = NSMenu(title: "Recording")
        let selectItem = recordingMenu.addItem(withTitle: "Select Region…",
                                               action: #selector(AppController.selectRegionAction),
                                               keyEquivalent: "r")
        selectItem.keyEquivalentModifierMask = [.command, .shift]
        selectItem.target = controller
        let toggleItem = recordingMenu.addItem(withTitle: "Record / Stop",
                                               action: #selector(AppController.toggleRecordingAction),
                                               keyEquivalent: "r")
        toggleItem.target = controller
        recordingMenuItem.submenu = recordingMenu
        main.addItem(recordingMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        let mainItem = windowMenu.addItem(withTitle: "Main Window",
                                          action: #selector(AppController.showMainWindowAction),
                                          keyEquivalent: "0")
        mainItem.target = controller
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)

        return main
    }
}
