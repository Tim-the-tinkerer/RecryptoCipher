import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DeskModel: ObservableObject {
    @Published var words = ["", "", "", ""]
    @Published var note = ""
    @Published var sheet = ""
    @Published var readings: [CodeReading] = []
    @Published var readingOpen = true
    @Published var status: String?
    @Published var statusIsError = false
    @Published var showHelp = false
    private var noteFileName: String?
    /// The four words that last sealed or opened the sheet on the desk.
    private var sealedWords: [String]?
    /// The sheet text the current readings belong to. A failed open of that same sheet keeps them.
    private var readingForSheet: String?
    private var recentLoad: (names: [String], texts: [String], destination: DeskFile.Role?, time: TimeInterval)?
    private var panelPresented = false

    func encrypt() {
        guard !note.isEmpty else {
            report("Write a note first.", error: true)
            return
        }
        do {
            let cleaned = try ScreenWords.validated(words)
            let sealed = try NoteCipher.encrypt(note: note, words: cleaned)
            sheet = sealed.sheet
            sealedWords = cleaned
            showReadings(sealed.readings, for: sealed.sheet)
            report("Wrote \(sealed.codes) codes for \(sealed.bytes) bytes, padded to \(sealed.paddedBytes).\(listNote(sealed.codes))", error: false)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    func decrypt() {
        guard !sheet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report("Paste a sheet first.", error: true)
            return
        }
        let cleaned: [String]
        do {
            cleaned = try ScreenWords.validated(words)
        } catch {
            report(error.localizedDescription, error: true)
            return
        }
        do {
            let opened = try NoteCipher.decrypt(sheet: sheet, words: cleaned)
            note = opened.note
            sheet = opened.sheet
            sealedWords = cleaned
            showReadings(opened.readings, for: opened.sheet)
            report("Opened \(opened.bytes) bytes from \(opened.codes) codes, padded to \(opened.paddedBytes).\(listNote(opened.codes))", error: false)
        } catch {
            if sheet != readingForSheet {
                readings = []
                readingForSheet = nil
            }
            report(error.localizedDescription, error: true)
        }
    }

    func clearDesk() {
        words = ["", "", "", ""]
        sealedWords = nil
        note = ""
        sheet = ""
        readings = []
        readingForSheet = nil
        status = nil
        statusIsError = false
    }

    func copySheet() {
        guard !sheet.isEmpty else {
            report("The sheet is empty.", error: true)
            return
        }
        writePasteboard(sheet)
    }

    func copyNote() {
        guard !note.isEmpty else {
            report("The note is empty.", error: true)
            return
        }
        writePasteboard(note)
    }

    func openNote() {
        chooseFile(destination: .note, title: "Open Note")
    }

    func openSheet() {
        chooseFile(destination: .sheet, title: "Open Sheet")
    }

    func openWords() {
        chooseFile(destination: .screen, title: "Open Words")
    }

    func exportSheet() {
        guard !sheet.isEmpty else {
            report("The sheet is empty.", error: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Sheet"
        panel.prompt = "Export"
        panel.nameFieldStringValue = DeskFile.exportName(forNoteFile: noteFileName)
        panel.message = "The sheet carries the salt, the nonce, and the codes. The four words stay off it."
        let snapshot = sheet
        present(panel) { [weak self] in
            guard let self, let url = panel.url else { return }
            var text = snapshot
            if !text.hasSuffix("\n") { text.append("\n") }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.report("Exported \(url.lastPathComponent).", error: false)
            } catch {
                self.report(error.localizedDescription, error: true)
            }
        }
    }

    func saveWords() {
        let four: [String]
        let sealed: Bool
        if let sealedWords {
            four = sealedWords
            sealed = true
        } else {
            do {
                four = try ScreenWords.validated(words)
                sealed = false
            } catch {
                report(error.localizedDescription, error: true)
                return
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Words"
        panel.prompt = "Save"
        panel.nameFieldStringValue = DeskFile.wordsName(forNoteFile: noteFileName)
        let typed = (try? ScreenWords.validated(words)) ?? []
        let differs = sealed && typed != four
        if sealed {
            panel.message = "Saves \(four.joined(separator: ", ")). Keep this file. Do not send it with the sheet."
            if differs {
                panel.message = (panel.message ?? "") + " These are the words that sealed the sheet, not the ones typed now."
            }
        } else {
            panel.message = "Saves \(four.joined(separator: ", ")). These words have not sealed a sheet yet."
        }
        let body = DeskFile.screenText(four)
        present(panel) { [weak self] in
            guard let self, let url = panel.url else { return }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                self.report(sealed
                    ? "Saved the four words that sealed this sheet."
                    : "Saved these four words.", error: false)
            } catch {
                self.report(error.localizedDescription, error: true)
            }
        }
    }

    func load(urls: [URL], destination: DeskFile.Role?) {
        var files: [DeskFile.Incoming] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                files.append(DeskFile.Incoming(name: url.lastPathComponent, text: try DeskFile.read(url)))
            } catch {
                report(error.localizedDescription, error: true)
                return
            }
        }
        load(files: files, destination: destination)
    }

    func fail(_ message: String) {
        report(message, error: true)
    }

    func load(files: [DeskFile.Incoming], destination: DeskFile.Role?) {
        let names = files.map(\.name)
        let texts = files.map(\.text)
        let now = ProcessInfo.processInfo.systemUptime
        if let recent = recentLoad,
           recent.names == names,
           recent.texts == texts,
           now - recent.time < 0.5 {
            if destination == nil || recent.destination == destination { return }
        }
        let placement = DeskFile.place(files, destination: destination)
        guard !placement.isError else {
            recentLoad = (names, texts, destination, now)
            report(placement.status, error: true)
            return
        }
        recentLoad = (names, texts, destination, now)
        if let note = placement.note {
            self.note = note.text
            noteFileName = note.name
        }
        if let sheet = placement.sheet {
            self.sheet = sheet.text
        }
        if let screen = placement.screen {
            words = screen
        }
        readings = []
        readingForSheet = nil
        report(placement.status, error: false)
    }

    private func chooseFile(destination: DeskFile.Role, title: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Open"
        present(panel) { [weak self] in
            self?.load(urls: panel.urls, destination: destination)
        }
    }

    private func present(_ panel: NSSavePanel, wrote: @escaping () -> Void) {
        guard !panelPresented else { return }
        panelPresented = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.panelPresented = false
            if response == .OK { wrote() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func writePasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showReadings(_ all: [CodeReading], for sheet: String) {
        readings = Array(all.prefix(48))
        readingForSheet = sheet
        readingOpen = true
    }

    private func listNote(_ count: Int) -> String {
        count > 48 ? " The word list shows the first 48." : ""
    }

    private func report(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

struct ContentView: View {
    @ObservedObject var model: DeskModel
    @State private var noteHover = false
    @State private var sheetHover = false
    @State private var screenHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            screenCard
            HStack(alignment: .top, spacing: 16) {
                editor(
                    title: "Note",
                    prompt: "Drop a text file, or type the note",
                    text: $model.note,
                    paper: .note,
                    monospaced: false,
                    hover: noteHover,
                    onHover: { noteHover = $0 },
                    destination: .note
                )
                editor(
                    title: "Sheet",
                    prompt: "Drop a sheet, or paste codes",
                    text: $model.sheet,
                    paper: .sheet,
                    monospaced: true,
                    hover: sheetHover,
                    onHover: { sheetHover = $0 },
                    destination: .sheet
                )
            }
            .frame(maxHeight: .infinity)
            controls
            if !model.readings.isEmpty {
                readingCard
            }
            Text("Unofficial cipher in the form of Decrypto, by Thomas Dagenais-Lespérance. Each sheet carries its salt and nonce.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.creamMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    receiveDrop(providers, destination: nil)
                }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.desk)
        .sheet(isPresented: $model.showHelp) {
            HelpView { model.showHelp = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECRYPTO")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .tracking(6)
                .foregroundStyle(Theme.cream)
            Text("A note, written as code cards. Each sheet draws a salt and a nonce.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.creamMuted)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            receiveDrop(providers, destination: nil)
        }
    }

    private var screenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCREEN")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Paper.note.muted)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(Theme.signal)
                            .frame(width: 14)
                        LineField(
                            placeholder: "word",
                            text: wordBinding(index),
                            ink: Paper.note.ink,
                            onFile: { model.load(urls: $0, destination: .screen) },
                            onHover: { screenHover = $0 }
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Text("Same four words, same order, on both sides. Capitals and accents fold together. Drop a saved screen here.")
                .font(.system(size: 12))
                .foregroundStyle(Paper.note.muted)
        }
        .paperCard(.note, pad: 14)
        .overlay {
            if screenHover {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.signal, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $screenHover) { providers in
            receiveDrop(providers, destination: .screen)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ActionButton(title: "Encrypt", primary: true) { model.encrypt() }
                ActionButton(title: "Decrypt") { model.decrypt() }
                ActionButton(title: "Copy Sheet") { model.copySheet() }
                ActionButton(title: "Export") { model.exportSheet() }
                ActionButton(title: "Save Words") { model.saveWords() }
                ActionButton(title: "Clear") { model.clearDesk() }
            }
            Text(model.status ?? " ")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            receiveDrop(providers, destination: nil)
        }
    }

    private var statusColor: Color {
        guard model.status != nil else { return .clear }
        return model.statusIsError ? Theme.alarm : Theme.moss
    }

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.readingOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(model.readingOpen ? "▾" : "▸")
                        .font(.system(size: 11, weight: .bold))
                    Text("ON YOUR SCREEN")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                    Spacer()
                    Text("Do not send this")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Paper.note.muted)
            }
            .buttonStyle(.plain)
            if model.readingOpen {
                Text("Each code names three of your words, in digit order. Give one clue per word if you are passing the round by voice.")
                    .font(.system(size: 12))
                    .foregroundStyle(Paper.note.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.readings.enumerated()), id: \.offset) { _, reading in
                            readingRow(reading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 168)
            }
        }
        .paperCard(.note, pad: 14)
    }

    private func readingRow(_ reading: CodeReading) -> some View {
        HStack(spacing: 14) {
            Text(reading.sheet)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Paper.note.ink)
                .frame(width: 72, alignment: .leading)
            Text(reading.words.joined(separator: "   "))
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Paper.note.ink)
            Spacer(minLength: 0)
        }
    }

    private func editor(
        title: String,
        prompt: String,
        text: Binding<String>,
        paper: Paper,
        monospaced: Bool,
        hover: Bool,
        onHover: @escaping (Bool) -> Void,
        destination: DeskFile.Role
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(paper.muted)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(monospaced ? .system(size: 15, design: .monospaced) : .system(size: 16, design: .serif))
                        .foregroundStyle(paper.muted.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                DeskEditor(
                    text: text,
                    ink: paper.inkNS,
                    monospaced: monospaced,
                    onFile: { urls in model.load(urls: urls, destination: destination) },
                    onHover: onHover
                )
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        }
        .paperCard(paper, pad: 14)
        .overlay {
            if hover {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.signal, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func receiveDrop(_ providers: [NSItemProvider], destination: DeskFile.Role?) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var incoming: [(Int, DeskFile.Incoming)] = []
        var failure: String?
        for (index, provider) in files.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                if let error {
                    lock.lock()
                    if failure == nil { failure = error.localizedDescription }
                    lock.unlock()
                    return
                }
                guard let url = DeskFile.url(from: item) else {
                    lock.lock()
                    if failure == nil { failure = "That drop was not a file." }
                    lock.unlock()
                    return
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try DeskFile.read(url)
                    lock.lock()
                    incoming.append((index, DeskFile.Incoming(name: url.lastPathComponent, text: text)))
                    lock.unlock()
                } catch {
                    lock.lock()
                    if failure == nil { failure = error.localizedDescription }
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            let message = failure
            let ordered = incoming.sorted { $0.0 < $1.0 }.map(\.1)
            lock.unlock()
            if let message {
                model.fail(message)
                return
            }
            model.load(files: ordered, destination: destination)
        }
        return true
    }

    private func wordBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.words[index] },
            set: { model.words[index] = $0 }
        )
    }
}

struct HelpView: View {
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How the cipher works")
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(Paper.note.ink)
            ScrollView {
                Text(HelpCopy.body)
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.note.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                ActionButton(title: "Done", primary: true, ink: Paper.note.ink, action: dismiss)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .background(Theme.ivory)
    }
}

enum HelpCopy {
    static let body = """
    The screen is four words, numbered 1 to 4. Both sides use the same four words in the same order. Capital letters and accents fold together. Oak and oak are the same word.

    A code is three different digits from 1 to 4, written the way the game writes it: 4.2.1. There are 24 such codes.

    Each seal draws a fresh 16-byte salt and a fresh 12-byte nonce. Both are written on the sheet, above the codes. The salt joins the four words and chooses how the deck is shuffled. The nonce joins them again for two further streams: one XORs the sealed bytes, and one shifts every digit before a card is chosen. Sealing the same note twice writes two different sheets.

    The note is padded with random bytes up to a size bucket: 32, 64, 128, 256, 512, 1024, 2048, 4096, or 8192. Notes that land in the same bucket leave the same number of codes. The real length sits inside the seal, with a CRC-16 over the length, the note, and the pad. That whole frame, marker included, is XORed with the keystream. Each whitened byte then becomes two cards.

    Encrypt writes the sheet. Decrypt reads the salt and the nonce from the sheet, and the four words from the screen. Send the sheet. Keep the words.

    Under the sheet, each code is listed with the three words it names, in digit order. That list is the encryptor’s view. To pass a short note the way a round is passed, give one clue for each of those words and keep the digits to yourself. The app leaves clues to you.

    You can also type a code as 4-2-1, 4·2·1, 421, or as three separate digits.

    Drop a text file on the note, or a sheet on the sheet. A file dropped on the rest of the window is a sheet when it begins with RECRYPTO/2 or every token is a code, a screen when it is a saved words file, and a note otherwise. Open Note is ⌘O. Open Sheet is ⌘⇧O.

    Export Sheet (⌘⇧S) writes the sheet as a text file, salt and nonce included. The file you dropped stays as it was. The four words stay off that file.

    Save Words (⌘⌥S) writes the four words that sealed the sheet, in a screen file of their own. Keep that file with you, and send the sheet on its own. Open Words is ⌘⌥O, and a screen file can be dropped on the screen.

    This is a puzzle cipher in the form of the game. Anyone who learns the four words can read the sheet. The salt and the nonce make each sheet its own shuffle. They are written on the sheet, so they are part of what you send.

    The self-test fuzzes the cipher: random notes, then sheets with a card, a salt digit, or the header disturbed. A damaged sheet is refused. RecryptoCipher --fuzz runs a longer pass.

    Encrypt is ⌘E. Decrypt is ⌘D. Clear wipes the four words, the note, and the sheet.

    Unofficial. Decrypto was designed by Thomas Dagenais-Lespérance and published by Le Scorpion Masqué.
    """
}
