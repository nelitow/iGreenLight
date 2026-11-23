import SwiftUI

/// The console-dashboard look: near-black surfaces, Xbox green accent, square-ish tiles, a white focus ring.
enum Xbox {
    static let green = Color(red: 0.063, green: 0.486, blue: 0.063)        // #107C10
    static let brightGreen = Color(red: 0.61, green: 0.94, blue: 0.04)     // #9BF00B
    static let background = Color(red: 0.055, green: 0.058, blue: 0.062)
    static let surface = Color.white.opacity(0.07)
    static let surfaceRaised = Color.white.opacity(0.13)
    static let secondaryText = Color.white.opacity(0.62)
    static let corner: CGFloat = 8
}

/// Dark backdrop with a faint green glow from the top-left corner.
struct XboxBackground: View {
    var body: some View {
        ZStack {
            Xbox.background
            RadialGradient(colors: [Xbox.green.opacity(0.38), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// White ring with a green glow and a slight lift, as on the Xbox dashboard.
    func xboxFocus(_ focused: Bool, corner: CGFloat = Xbox.corner, scale: CGFloat = 1.04) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: corner + 3).strokeBorder(.white, lineWidth: 3).padding(-5).opacity(focused ? 1 : 0))
            .shadow(color: Xbox.brightGreen.opacity(focused ? 0.55 : 0), radius: 14)
            .scaleEffect(focused ? scale : 1)
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A button the controller can reach. The label is told whether it has the focus.
struct PadButton<Label: View>: View {
    let id: String
    var priority = 0
    var corner: CGFloat = Xbox.corner
    var scale: CGFloat = 1.04
    var adjust: ((Int) -> Void)? = nil
    let action: () -> Void
    @ViewBuilder var label: (_ focused: Bool) -> Label
    @ObservedObject private var nav = PadNavigator.shared

    var body: some View {
        let focused = nav.isFocused(id)
        Button {
            nav.pointerUsed()
            action()
        } label: {
            label(focused).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xboxFocus(focused, corner: corner, scale: scale)
        .padFocusable(id, priority: priority, adjust: adjust, action: action)
    }
}

/// Green call-to-action / grey secondary button.
struct XboxButton: View {
    let id: String
    let title: String
    var systemImage: String? = nil
    var prominent = true
    var destructive = false
    let action: () -> Void

    var body: some View {
        PadButton(id: id, action: action) { _ in
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .foregroundStyle(destructive ? Color(red: 1, green: 0.45, blue: 0.42) : .white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .frame(minWidth: 120)
            .background(prominent ? Xbox.green : Xbox.surfaceRaised, in: RoundedRectangle(cornerRadius: Xbox.corner))
        }
    }
}

/// Controller button glyphs for the hint bar.
struct PadGlyph: View {
    enum Kind { case a, b, x, y, lb, rb, sticks }
    let kind: Kind

    var body: some View {
        switch kind {
        case .a: face("A", Color(red: 0.42, green: 0.85, blue: 0.35))
        case .b: face("B", Color(red: 0.95, green: 0.33, blue: 0.30))
        case .x: face("X", Color(red: 0.30, green: 0.62, blue: 0.98))
        case .y: face("Y", Color(red: 0.98, green: 0.82, blue: 0.25))
        case .lb: bumper("LB")
        case .rb: bumper("RB")
        case .sticks: bumper("L3+R3")
        }
    }

    private func face(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
            .frame(width: 20, height: 20).background(c, in: Circle())
    }

    private func bumper(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
            .padding(.horizontal, 6).frame(height: 18).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// "Ⓐ Select  Ⓑ Back …" along the bottom, shown while a controller is connected.
struct PadHints: View {
    let hints: [(PadGlyph.Kind, String)]
    @ObservedObject private var nav = PadNavigator.shared

    var body: some View {
        if nav.padConnected {
            HStack(spacing: 14) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 6) {
                        PadGlyph(kind: h.0)
                        if !h.1.isEmpty { Text(h.1).font(.footnote.weight(.medium)).foregroundStyle(Xbox.secondaryText) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(.black.opacity(0.35))
        }
    }
}

// MARK: Settings rows (also used by the in-stream menu)

/// One line of a settings list: title, optional explanation, value on the right.
struct XboxRow<Value: View>: View {
    let id: String
    let title: String
    var detail: String? = nil
    var adjust: ((Int) -> Void)? = nil
    let action: () -> Void
    @ViewBuilder var value: () -> Value

    var body: some View {
        PadButton(id: id, scale: 1.0, adjust: adjust, action: action) { focused in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.white)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Xbox.secondaryText).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                value()
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(focused ? Xbox.surfaceRaised : Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
        }
    }
}

struct XboxToggleRow: View {
    let id: String
    let title: String
    var detail: String? = nil
    var disabled = false
    @Binding var isOn: Bool

    var body: some View {
        XboxRow(id: id, title: title, detail: detail, adjust: { d in if !disabled { isOn = d > 0 } }, action: { if !disabled { isOn.toggle() } }) {
            // A click on the switch or anywhere on the row flips it.
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(XboxSwitchStyle())
                .disabled(disabled)
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

/// The system switch's shape, but green whenever it is on: the stock macOS switch turns grey in an inactive
/// window, which on this dark theme makes on and off look alike.
struct XboxSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Xbox.green : Color.white.opacity(0.16))
            .overlay(Capsule().strokeBorder(.white.opacity(configuration.isOn ? 0 : 0.12), lineWidth: 1))
            .frame(width: 38, height: 22)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
    }
}

/// Pick one of a list. With the pointer (or a tap) the row opens a menu of all the values, the current one
/// checked, like a system pop-up button. With a controller A steps to the next value and left / right step
/// either way, since a system menu can't be driven from the pad.
struct XboxChoiceRow<T: Hashable>: View {
    let id: String
    let title: String
    var detail: String? = nil
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @ObservedObject private var nav = PadNavigator.shared

    private func step(_ d: Int) {
        guard !options.isEmpty else { return }
        let i = options.firstIndex(of: selection) ?? 0
        selection = options[((i + d) % options.count + options.count) % options.count]
    }

    var body: some View {
        let focused = nav.isFocused(id)
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.white)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Xbox.secondaryText).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text(label(selection)).font(.callout.weight(.semibold)).foregroundStyle(Xbox.brightGreen)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Xbox.secondaryText)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 260, alignment: .trailing)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(focused ? Xbox.surfaceRaised : Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { nav.pointerUsed() })
        .xboxFocus(focused, corner: Xbox.corner, scale: 1.0)
        .padFocusable(id, adjust: step, action: { step(1) })
    }
}

/// Game audio volume: a slider with the pointer, left / right in steps of 10 with a controller, A mutes and
/// unmutes.
struct XboxVolumeRow: View {
    let id: String
    var title = "Volume"
    var detail: String? = nil
    @Binding var volume: Int
    @State private var beforeMute = 100
    @ObservedObject private var nav = PadNavigator.shared

    private var icon: String {
        switch volume {
        case 0: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private func toggleMute() {
        if volume > 0 { beforeMute = volume; volume = 0 } else { volume = max(beforeMute, 10) }
    }

    var body: some View {
        let focused = nav.isFocused(id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.white)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Xbox.secondaryText).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Text("\(volume)%").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Xbox.brightGreen)
            }
            HStack(spacing: 10) {
                Button { nav.pointerUsed(); toggleMute() } label: {
                    Image(systemName: icon).frame(width: 22).foregroundStyle(volume == 0 ? Xbox.secondaryText : .white)
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { Double(volume) }, set: { volume = Int($0.rounded()) }), in: 0...100)
                    .tint(Xbox.green)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(focused ? Xbox.surfaceRaised : Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
        .xboxFocus(focused, corner: Xbox.corner, scale: 1.0)
        .padFocusable(id, adjust: { d in volume = min(100, max(0, volume + d * 10)) }, action: toggleMute)
    }
}

struct XboxSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Xbox.secondaryText)
                .padding(.top, 14).padding(.leading, 4)
            content()
        }
    }
}
