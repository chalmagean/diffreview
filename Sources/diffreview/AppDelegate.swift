import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: ReviewStore
    var window: NSWindow!
    private var settingsWindow: NSWindow?

    init(store: ReviewStore) {
        self.store = store
        super.init()
        store.onSubmit = { markdown in
            FileHandle.standardOutput.write(Data(markdown.utf8))
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        AppearanceSettings.shared.apply()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Review · \(store.repoName)"
        window.subtitle = store.title
        window.contentViewController = NSHostingController(rootView: RootView(store: store))
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.minSize = NSSize(width: 700, height: 400)
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Open on whatever Space is active (e.g. over a full-screen terminal) rather than
        // on the desktop Space, where it would be invisible to the user.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("diffreview.main")
        if !window.setFrameUsingName("diffreview.main") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Launched from a terminal: force ourselves to the front.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancel()
    }

    /// Closing without submitting: keep the draft on disk, print nothing, exit 1.
    func cancel() -> Never {
        store.saveNow()
        exit(1)
    }

    @objc func closeReview(_ sender: Any?) { cancel() }

    @objc func showAbout(_ sender: Any?) { AppInfo.showAboutPanel() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            settings.title = "Settings"
            settings.styleMask = [.titled, .closable]
            settings.isReleasedWhenClosed = false
            settings.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About diffreview", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide diffreview", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Without Submitting", action: #selector(closeReview(_:)), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Needed for copy/paste/undo shortcuts to reach text editors.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
