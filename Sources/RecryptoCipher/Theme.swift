import AppKit
import SwiftUI

enum Theme {
    static let desk = Color(red: 0.07, green: 0.09, blue: 0.14)
    static let deskNS = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)
    static let ivory = Color(red: 0.96, green: 0.93, blue: 0.88)
    static let ivoryInk = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let ivoryMuted = Color(red: 0.40, green: 0.42, blue: 0.48)
    static let graphite = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let graphiteInk = Color(red: 0.95, green: 0.93, blue: 0.88)
    static let graphiteMuted = Color(red: 0.66, green: 0.68, blue: 0.72)
    static let cream = Color(red: 0.94, green: 0.91, blue: 0.84)
    static let creamMuted = Color(red: 0.62, green: 0.64, blue: 0.70)
    static let signal = Color(red: 0.93, green: 0.62, blue: 0.22)
    static let alarm = Color(red: 0.86, green: 0.32, blue: 0.28)
    static let moss = Color(red: 0.55, green: 0.76, blue: 0.62)
    static let ivoryInkNS = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
    static let graphiteInkNS = NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.88, alpha: 1)
}

struct Paper {
    var paper: Color
    var ink: Color
    var muted: Color
    var scheme: ColorScheme
    var inkNS: NSColor

    static let note = Paper(paper: Theme.ivory, ink: Theme.ivoryInk, muted: Theme.ivoryMuted, scheme: .light, inkNS: Theme.ivoryInkNS)
    static let sheet = Paper(paper: Theme.graphite, ink: Theme.graphiteInk, muted: Theme.graphiteMuted, scheme: .dark, inkNS: Theme.graphiteInkNS)
}

extension View {
    func paperCard(_ paper: Paper, pad: CGFloat = 16) -> some View {
        padding(pad)
            .background(paper.paper)
            .foregroundStyle(paper.ink)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, paper.scheme)
    }
}

struct ActionStyle: ButtonStyle {
    var primary: Bool
    var ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(primary ? Color.white : ink)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary
                          ? Theme.signal.opacity(configuration.isPressed ? 0.8 : 1)
                          : ink.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(primary ? Color.clear : ink.opacity(0.35), lineWidth: 1)
            )
    }
}

struct ActionButton: View {
    var title: String
    var primary = false
    var ink: Color = Theme.cream
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: primary ? 120 : 0)
        }
        .buttonStyle(ActionStyle(primary: primary, ink: ink))
    }
}

struct LineField: View {
    var placeholder: String
    @Binding var text: String
    var ink: Color
    var onFile: (([URL]) -> Void)? = nil
    var onHover: ((Bool) -> Void)? = nil

    var body: some View {
        WordField(text: $text, placeholder: placeholder, ink: Theme.ivoryInkNS, onFile: onFile, onHover: onHover)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ink.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ink.opacity(0.28), lineWidth: 1)
            )
    }
}
