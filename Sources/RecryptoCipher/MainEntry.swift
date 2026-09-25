import AppKit
import Darwin
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--self-test") {
            if let error = SelfTest.run() {
                fputs("SELF-TEST FAILED: \(error)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            print("16-byte salt, 12-byte nonce, XOR keystream, size padding, fuzzed sheets.")
            exit(0)
        }

        if args.contains("--fuzz") {
            let rounds = 400
            let mutations = 400
            if let error = Fuzz.run(rounds: rounds, mutations: mutations) {
                fputs("FUZZ FAILED: \(error)\n", stderr)
                exit(1)
            }
            print("FUZZ OK")
            print("\(rounds) round trips, \(mutations) mutated sheets.")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }

        if args.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }

        if args.contains("--encrypt") || args.contains("--decrypt") {
            exit(CLI.run(args))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    static let helpText = """
    \(AppInfo.name) \(AppInfo.version) — a note written as code cards

    Usage:
      RecryptoCipher                         Launch the app
      RecryptoCipher --self-test             Cipher checks, including a fuzz pass
      RecryptoCipher --fuzz                  Longer fuzz: random notes and damaged sheets
      RecryptoCipher --version
      RecryptoCipher --help

      RecryptoCipher --encrypt \\
          --1 oak --2 river --3 clock --4 stone \\
          --message "Meet at noon"

      RecryptoCipher --decrypt \\
          --1 oak --2 river --3 clock --4 stone \\
          --file sheet.txt

    The four words are the screen, numbered 1 to 4. Encrypt prints the
    sheet, including a fresh salt and nonce. Decrypt prints the note.
    --file reads either one, and with neither --message nor --sheet the
    text is read from stdin.

    --salt and --nonce take hex (16 bytes and 12 bytes) when you want
    those values instead of a fresh draw. The sheet still carries them.

    A code is three different digits from 1 to 4. The salt chooses the
    shuffle. The framed bytes are XORed with their own keystream, then
    each byte becomes two cards, and the nonce shifts each digit. The
    note is padded to a size bucket. This is a puzzle cipher. Anyone
    who learns the four words can read the sheet.

    Drop a text file on the note, or a sheet on the sheet.
    Export Sheet writes the salt, the nonce, and the codes.
    Save Words writes the four words that sealed the sheet. Keep that
    file with you, and send the sheet on its own.

    Unofficial cipher in the form of the game by Thomas Dagenais-Lespérance.
    """
}

enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try Invocation(args)
        } catch {
            fputs("\(error)\n\n\(MainEntry.helpText)\n", stderr)
            return 2
        }
        guard invocation.encrypt != invocation.decrypt else {
            fputs("Choose --encrypt or --decrypt.\n", stderr)
            return 2
        }
        if invocation.decrypt && (invocation.salt != nil || invocation.nonce != nil) {
            fputs("Decrypt reads the salt and the nonce from the sheet.\n", stderr)
            return 2
        }
        let words: [String]
        if let four = invocation.words {
            words = four
        } else {
            fputs("The screen needs --1, --2, --3, and --4.\n", stderr)
            return 2
        }

        let text: String
        do {
            text = try invocation.text(encrypting: invocation.encrypt)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }

        do {
            if invocation.encrypt {
                let sealed: SealedNote
                if invocation.salt != nil || invocation.nonce != nil {
                    guard let saltHex = invocation.salt, let nonceHex = invocation.nonce else {
                        fputs("Pass both --salt and --nonce, as hex.\n", stderr)
                        return 2
                    }
                    guard let salt = NoteCipher.unhex(saltHex), salt.count == NoteCipher.saltSize else {
                        fputs("\(CipherError.badSalt)\n", stderr)
                        return 2
                    }
                    guard let nonce = NoteCipher.unhex(nonceHex), nonce.count == NoteCipher.nonceSize else {
                        fputs("\(CipherError.badNonce)\n", stderr)
                        return 2
                    }
                    sealed = try NoteCipher.encrypt(note: text, words: words, salt: salt, nonce: nonce, pad: nil)
                } else {
                    sealed = try NoteCipher.encrypt(note: text, words: words)
                }
                writeOut(sealed.sheet)
            } else {
                let opened = try NoteCipher.decrypt(sheet: text, words: words)
                writeOut(opened.note)
            }
            return 0
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    private static func writeOut(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
        if !text.hasSuffix("\n") {
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}

private struct Invocation {
    var encrypt = false
    var decrypt = false
    var wordSlots: [String?] = [nil, nil, nil, nil]
    var message: String?
    var sheet: String?
    var file: String?
    var salt: String?
    var nonce: String?

    var words: [String]? {
        if wordSlots.allSatisfy({ $0 != nil }) {
            return wordSlots.map { $0! }
        }
        return nil
    }

    init(_ args: [String]) throws {
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--encrypt":
                encrypt = true
            case "--decrypt":
                decrypt = true
            case "--1", "--2", "--3", "--4", "--message", "--sheet", "--file", "--salt", "--nonce":
                index += 1
                guard index < args.count else { throw CLIError.usage("\(arg) needs a value.") }
                let value = args[index]
                switch arg {
                case "--1": wordSlots[0] = value
                case "--2": wordSlots[1] = value
                case "--3": wordSlots[2] = value
                case "--4": wordSlots[3] = value
                case "--message": message = value
                case "--sheet": sheet = value
                case "--file": file = value
                case "--salt": salt = value
                case "--nonce": nonce = value
                default: break
                }
            default:
                throw CLIError.usage("Unknown option \(arg).")
            }
            index += 1
        }
    }

    func text(encrypting: Bool) throws -> String {
        if encrypting, let message {
            return message
        }
        if !encrypting, let sheet {
            return sheet
        }
        if let file {
            return try DeskFile.read(URL(fileURLWithPath: file))
        }
        if encrypting, sheet != nil {
            throw CLIError.usage("Encrypt reads --message or --file.")
        }
        if !encrypting, message != nil {
            throw CLIError.usage("Decrypt reads --sheet or --file.")
        }
        if isatty(STDIN_FILENO) != 0 {
            throw CLIError.usage(encrypting
                ? "Pass the note with --message or --file, or pipe it in."
                : "Pass the sheet with --sheet or --file, or pipe it in.")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if data.count > DeskFile.maxBytes {
            throw CLIError.usage("That input is too big for the desk.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError.usage("The input is not UTF-8 text.")
        }
        return text
    }
}

/// Fills the window it is given. A new sheet must not change the window’s height.
final class DeskHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let text):
            return text
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let model = DeskModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let hosting = DeskHostingView(rootView: ContentView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.deskNS
        window.contentView = hosting
        window.minSize = NSSize(width: 860, height: 620)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        window.setFrameAutosaveName("RecryptoCipherMainWindow")
        window.makeKeyAndOrderFront(nil)
        keepWindowOnScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowDidResize(_ notification: Notification) {
        keepWindowOnScreen()
    }

    /// The sheet and the word list stay inside the window. If a resize still
    /// crosses the menu bar or the Dock, pull the window back onto the screen.
    private func keepWindowOnScreen() {
        guard let window, let screen = window.screen, !fittingToScreen else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if frame.height > visible.height {
            frame.size.height = visible.height
            frame.origin.y = visible.minY
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        if frame.maxY > visible.maxY {
            frame.origin.y -= frame.maxY - visible.maxY
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX
        }
        if frame.maxX > visible.maxX {
            frame.origin.x -= frame.maxX - visible.maxX
        }
        guard frame != window.frame else { return }
        fittingToScreen = true
        window.setFrame(frame, display: true, animate: false)
        fittingToScreen = false
    }

    private var fittingToScreen = false

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.load(urls: urls, destination: nil)
    }

    @objc private func openNote(_ sender: Any?) { model.openNote() }
    @objc private func openSheetFile(_ sender: Any?) { model.openSheet() }
    @objc private func exportSheet(_ sender: Any?) { model.exportSheet() }
    @objc private func openWords(_ sender: Any?) { model.openWords() }
    @objc private func saveWords(_ sender: Any?) { model.saveWords() }
    @objc private func encrypt(_ sender: Any?) { model.encrypt() }
    @objc private func decrypt(_ sender: Any?) { model.decrypt() }
    @objc private func clearDesk(_ sender: Any?) { model.clearDesk() }
    @objc private func copySheet(_ sender: Any?) { model.copySheet() }
    @objc private func copyNote(_ sender: Any?) { model.copyNote() }
    @objc private func showHelp(_ sender: Any?) { model.showHelp = true }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .version: AppInfo.version,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .credits: NSAttributedString(
                string: """
                A note sealed as code cards. Each sheet draws a 16-byte salt \
                and a 12-byte nonce, and the note is padded to a size bucket. \
                The framed bytes are XORed with their own keystream. The salt \
                shuffles the 24-card deck. The nonce shifts every digit. \
                Two cards carry each whitened byte.

                A puzzle cipher in the form of the game. Anyone who learns \
                the four words can read the sheet. The salt and the nonce \
                travel with the codes.

                Unofficial. Decrypto was designed by Thomas \
                Dagenais-Lespérance and published by Le Scorpion Masqué.
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About Recrypto Cipher", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Recrypto Cipher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Recrypto Cipher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let openNoteItem = fileMenu.addItem(withTitle: "Open Note…", action: #selector(openNote(_:)), keyEquivalent: "o")
        openNoteItem.target = self
        let openSheetItem = fileMenu.addItem(withTitle: "Open Sheet…", action: #selector(openSheetFile(_:)), keyEquivalent: "o")
        openSheetItem.keyEquivalentModifierMask = [.command, .shift]
        openSheetItem.target = self
        let openWordsItem = fileMenu.addItem(withTitle: "Open Words…", action: #selector(openWords(_:)), keyEquivalent: "o")
        openWordsItem.keyEquivalentModifierMask = [.command, .option]
        openWordsItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        let exportItem = fileMenu.addItem(withTitle: "Export Sheet…", action: #selector(exportSheet(_:)), keyEquivalent: "s")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        let saveWordsItem = fileMenu.addItem(withTitle: "Save Words…", action: #selector(saveWords(_:)), keyEquivalent: "s")
        saveWordsItem.keyEquivalentModifierMask = [.command, .option]
        saveWordsItem.target = self

        let cipherItem = NSMenuItem()
        mainMenu.addItem(cipherItem)
        let cipherMenu = NSMenu(title: "Cipher")
        cipherItem.submenu = cipherMenu
        let encryptItem = cipherMenu.addItem(withTitle: "Encrypt", action: #selector(encrypt(_:)), keyEquivalent: "e")
        encryptItem.target = self
        let decryptItem = cipherMenu.addItem(withTitle: "Decrypt", action: #selector(decrypt(_:)), keyEquivalent: "d")
        decryptItem.target = self
        cipherMenu.addItem(NSMenuItem.separator())
        let copySheetItem = cipherMenu.addItem(withTitle: "Copy Sheet", action: #selector(copySheet(_:)), keyEquivalent: "c")
        copySheetItem.keyEquivalentModifierMask = [.command, .shift]
        copySheetItem.target = self
        let copyNoteItem = cipherMenu.addItem(withTitle: "Copy Note", action: #selector(copyNote(_:)), keyEquivalent: "n")
        copyNoteItem.keyEquivalentModifierMask = [.command, .shift]
        copyNoteItem.target = self
        cipherMenu.addItem(NSMenuItem.separator())
        let clearItem = cipherMenu.addItem(withTitle: "Clear", action: #selector(clearDesk(_:)), keyEquivalent: "k")
        clearItem.target = self

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let how = helpMenu.addItem(withTitle: "How the Cipher Works", action: #selector(showHelp(_:)), keyEquivalent: "?")
        how.target = self
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
