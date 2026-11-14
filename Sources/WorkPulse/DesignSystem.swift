import AppKit
import SwiftUI
import WorkPulseCore

// The visual language of WorkPulse: one palette, one type scale, one set of controls.
// Colour always comes with a second signal (an icon, a text or a pattern), never alone.

private func rgb(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

private func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
}

enum WP {
    // Brand and semantic colours. Fixed colours carry their own text colour (see `Hero`).
    static let cobalt = Color(nsColor: rgb(0x2261E3))          // work, primary action
    static let navy = Color(nsColor: rgb(0x0D1B4D))            // overtime, sleep
    static let amber = Color(nsColor: rgb(0xF5A524))           // idle, attention
    static let amberInk = Color(nsColor: rgb(0x2B1700))
    static let amberHatch = Color(nsColor: rgb(0xB45309))
    static let slate = Color(nsColor: rgb(0x3F4A5A))           // paused
    static let switchOff = Color(nsColor: rgb(0x6B7686))
    static let red = dyn(rgb(0xC62828), rgb(0xFF8A80))         // delete only
    // Text on the fixed colours above (the same in light and dark appearance).
    static let fixedInk = Color(nsColor: rgb(0x0D1117))
    static let fixedBlue = Color(nsColor: rgb(0x1A4FC4))
    static let onCobalt = Color(nsColor: rgb(0xEAF1FF))
    static let onNavy = Color(nsColor: rgb(0xDCE6F7))
    static let onSlate = Color(nsColor: rgb(0xE8ECF4))

    // Text.
    static let ink = dyn(rgb(0x0D1117), rgb(0xF2F5FA))
    static let secondary = dyn(rgb(0x3F4A5A), rgb(0xC9D0DC))
    static let caption = dyn(rgb(0x4B5565), rgb(0xAEB7C6))
    static let textBlue = dyn(rgb(0x1A4FC4), rgb(0x9DBEFF))

    // Status backgrounds with their text colours.
    static let green = dyn(rgb(0x1A7F45), rgb(0x3FBF7A))       // goal reached, connected
    static let greenInk = dyn(rgb(0x125C32), rgb(0x9BE5BB))
    static let greenBg = dyn(rgb(0xE3F4EA), rgb(0x12351F))
    static let infoBg = dyn(rgb(0xE6EEFF), rgb(0x16264F))
    static let warnBg = dyn(rgb(0xFFF1D6), rgb(0x3A2A08))
    static let warnInk = dyn(rgb(0x5C2E00), rgb(0xFFD899))
    static let heroLight = dyn(rgb(0xE8ECF4), rgb(0x2A3242))   // Personal, non-work

    // Surfaces and lines.
    /// The glass panel that fills a window, over the wallpaper.
    static let panel = dyn(rgb(0xFFFFFF, 0.62), rgb(0x0B1020, 0.45))
    /// The content area of the main window, one step lighter than the sidebar.
    static let content = dyn(rgb(0xFFFFFF, 0.50), rgb(0xFFFFFF, 0.04))
    static let card = dyn(rgb(0xFFFFFF, 0.66), rgb(0xFFFFFF, 0.07))
    static let cardStrong = dyn(rgb(0xFFFFFF, 0.78), rgb(0xFFFFFF, 0.10))
    static let field = dyn(rgb(0xFFFFFF), rgb(0x1B2130))
    static let border = dyn(rgb(0x0D1B4D, 0.55), rgb(0xFFFFFF, 0.50))   // control outlines, 3:1 or more
    static let hairline = dyn(rgb(0x0D1B4D, 0.10), rgb(0xFFFFFF, 0.12))
    static let track = dyn(rgb(0x0D1B4D, 0.12), rgb(0xFFFFFF, 0.16))
    static let sliderTrack = dyn(rgb(0x0D1B4D, 0.22), rgb(0xFFFFFF, 0.24))
    static let hover = dyn(rgb(0x0D1B4D, 0.08), rgb(0xFFFFFF, 0.10))

    /// Type scale: 11 · 12 · 13 · 14 · 15 · 20 · 24 · 32 · 44 · 48.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

// MARK: - Formats

extension Fmt {
    /// Clock time as "08.00" (24-hour, as in the whole interface).
    static func time(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d.%02d", m / 60, m % 60)
    }

    static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return time(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// "Fri 08.00"
    static func dayTime(_ date: Date) -> String {
        "\(Calendar.current.shortWeekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]) \(time(date))"
    }

    /// A whole number of minutes as "6h 00m" or "30m".
    static func minutes(_ minutes: Int) -> String { duration(Double(max(0, minutes)) * 60, seconds: false) }
}

// MARK: - Backgrounds

/// The soft blue, cyan and peach wallpaper behind every glass surface.
struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(nsColor: rgb(0x0B1020)) : Color(nsColor: rgb(0xDCE6F7)))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height, side = max(w, h)
                ZStack {
                    blob(rgb(dark ? 0x1D3E8F : 0x8FB8FF), at: UnitPoint(x: 0.06, y: 0.06), radius: side * 0.55)
                    blob(rgb(dark ? 0x12506B : 0xB8ECFF), at: UnitPoint(x: 0.96, y: 0.22), radius: side * 0.5)
                    blob(rgb(dark ? 0x5A3320 : 0xFFD2AE), at: UnitPoint(x: 0.85, y: 1), radius: side * 0.5)
                }
                .frame(width: w, height: h)
            }
        }
        .accessibilityHidden(true)
    }

    private func blob(_ color: NSColor, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [Color(nsColor: color), Color(nsColor: color.withAlphaComponent(0))],
                       center: center, startRadius: 0, endRadius: radius)
    }
}

/// The background of a window: the blurred desktop, the wallpaper colours, then the glass panel.
struct Backdrop: View {
    /// Profiling switch (debug runs): draw the backdrop without the behind-window blur.
    nonisolated(unsafe) static var glass = true

    var body: some View {
        ZStack {
            if Self.glass { Glass() }
            Wallpaper().opacity(0.85)
            WP.panel
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Real translucency: the desktop shows through, blurred by macOS.
struct Glass: NSViewRepresentable {
    var material = NSVisualEffectView.Material.underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Diagonal stripes: the second signal for agent time (on cobalt) and idle time (on amber).
struct Hatch: View {
    var color: Color
    var width: CGFloat = 2
    var gap: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += width + gap
            }
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

extension View {
    /// A glass card: the unit of grouping on every screen.
    func wpCard(padding: CGFloat = 16, radius: CGFloat = 14, strong: Bool = false) -> some View {
        self.padding(padding)
            .background(strong ? WP.cardStrong : WP.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(WP.hairline))
    }

    /// Content rises into place when a screen opens (skipped with Reduce Motion).
    func wpRise(_ index: Int = 0) -> some View { modifier(Rise(index: index)) }

    /// The standard outline for text fields and menus.
    func wpField(height: CGFloat = 32, radius: CGFloat = 8) -> some View {
        self.padding(.horizontal, 10)
            .frame(height: height)
            .background(WP.field, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(WP.border))
    }
}

/// Entrance animations can be switched off (the snapshot harness draws finished screens).
@MainActor enum Motion { static var off = false }

private struct Rise: ViewModifier {
    let index: Int
    @State private var shown = Motion.off
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0.3)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.52).delay(Double(index) * 0.06)) { shown = true }
            }
    }
}

/// Screen title with one line that says what the screen is for.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(WP.font(24, .bold)).tracking(-0.4).foregroundStyle(WP.ink)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// Card heading.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(WP.font(15, .bold)).foregroundStyle(WP.ink).accessibilityAddTraits(.isHeader)
    }
}

/// Small label above a control.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { Text(text).font(WP.font(12, .medium)).foregroundStyle(WP.caption) }
}

// MARK: - Controls

/// The switch itself: track, knob and check mark. It draws its own focus ring in the shape of
/// the track (the system ring is a rectangle and shows as a box behind the switch).
struct WPSwitch: View {
    @Binding var isOn: Bool
    var width: CGFloat = 44
    var height: CGFloat = 26
    /// A light outline, for a switch on a dark surface.
    var outlined = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // The outline is a light capsule under the track. A stroked border draws stray marks at both ends.
            if outlined { Capsule().fill(.white.opacity(0.6)) }
            Capsule().fill(isOn ? WP.cobalt : WP.switchOff).padding(outlined ? 1.5 : 0)
            Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: height * 0.38, weight: .heavy)).foregroundStyle(WP.fixedBlue)
                    }
                }
                .frame(width: height - 4, height: height - 4)
                .padding(2)
        }
        .frame(width: width, height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        .background {
            // Focus ring: 3 pt blue outside 2 pt white, as filled capsules under the track.
            if focused {
                Capsule().fill(WP.textBlue).padding(-5)
                Capsule().fill(.white).padding(-2)
            }
        }
        // Like a button: it takes keyboard focus only when keyboard navigation is on.
        .focusable(true, interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { isOn.toggle(); return .handled }
    }
}

/// Switch with a check mark and the word On or Off: the state never depends on colour alone.
struct WPSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label.font(WP.font(13, .medium)).foregroundStyle(WP.ink)
            Spacer(minLength: 8)
            Text(configuration.isOn ? "On" : "Off").font(WP.font(13, .semibold)).foregroundStyle(WP.secondary)
                .frame(minWidth: 22, alignment: .trailing).accessibilityHidden(true)
            WPSwitch(isOn: configuration.$isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// A slider in steps: a cobalt fill to the left of a white thumb. Drag it, or use the arrow keys.
struct WPSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var label = ""
    /// What VoiceOver reads as the value, for example "6h 00m".
    var valueText = ""
    /// Runs when a change is complete (the drag ends, or a key was pressed).
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    private let thumb: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let span = max(1, range.upperBound - range.lowerBound)
            let fraction = CGFloat(min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / CGFloat(span)
            let travel = max(1, geo.size.width - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(WP.sliderTrack).frame(height: 8)
                Capsule().fill(WP.cobalt).frame(width: thumb / 2 + travel * fraction, height: 8)
                ZStack {
                    if focused { Circle().fill(WP.textBlue).padding(-5); Circle().fill(.white).padding(-2) }
                    Circle().fill(WP.cobalt)
                    Circle().fill(.white).padding(2)
                }
                .frame(width: thumb, height: thumb)
                .shadow(color: WP.navy.opacity(0.28), radius: 3, y: 2)
                .offset(x: travel * fraction)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let at = min(1, max(0, (drag.location.x - thumb / 2) / travel))
                    set(Double(range.lowerBound) + Double(at) * Double(span))
                }
                .onEnded { _ in onCommit() })
        }
        .frame(height: thumb)
        .opacity(enabled ? 1 : 0.45)
        .focusable(enabled, interactions: .activate).focused($focused).focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in set(Double(value - step)); onCommit(); return .handled }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in set(Double(value + step)); onCommit(); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            set(Double(value + (direction == .increment ? step : -step)))
            onCommit()
        }
    }

    /// Stores the nearest step inside the range.
    private func set(_ raw: Double) {
        let stepped = Int((raw / Double(step)).rounded()) * step
        value = min(range.upperBound, max(range.lowerBound, stepped))
    }
}

/// A date or time, typed or stepped with the arrow keys (the native control without its own
/// frame). Put it in `.wpField()` so it looks like the menus and text fields beside it.
struct WPDateField: NSViewRepresentable {
    @Binding var selection: Date
    var elements: NSDatePicker.ElementFlags = .hourMinute
    var maxDate: Date? = nil
    var minDate: Date? = nil
    var size: CGFloat = 13
    var weight: NSFont.Weight = .medium

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none   // the selected part is highlighted; the field has the outline
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.datePickerElements = elements
        picker.maxDate = maxDate
        picker.minDate = minDate
        picker.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        picker.textColor = .labelColor
        picker.isEnabled = context.environment.isEnabled
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    final class Coordinator: NSObject {
        var parent: WPDateField
        init(_ parent: WPDateField) { self.parent = parent }
        @MainActor @objc func changed(_ sender: NSDatePicker) { parent.selection = sender.dateValue }
    }
}

/// A menu with one selected value, drawn as an outlined field: the same height, border and
/// corner as the buttons and text fields beside it.
struct WPMenu<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.isEnabled) private var enabled

    init(_ label: String, selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self.label = label
        self._selection = selection
        self.options = options
    }

    var body: some View {
        let current = options.first { $0.value == selection }?.title ?? ""
        Menu {
            Picker(label, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { Text($0.element.title).tag($0.element.value) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current).font(WP.font(13, .medium)).foregroundStyle(WP.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(WP.caption)
            }
            .wpField()
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityValue(current)
    }
}

/// Filled button. `fill` and `text` are given by the surface it sits on.
struct WPButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }
    var kind = Kind.secondary
    var fill: Color?
    var text: Color?
    var height: CGFloat = 32
    var radius: CGFloat = 8
    var expand = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = fill ?? {
            switch kind {
            case .primary: WP.cobalt
            case .destructive: Color(nsColor: rgb(0xC62828))
            case .secondary: WP.field
            case .plain: WP.hover
            }
        }()
        let foreground: Color = text ?? (kind == .primary || kind == .destructive ? .white : WP.ink)
        return configuration.label
            .font(WP.font(height >= 40 ? 14 : 13, kind == .secondary && fill == nil ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if kind == .secondary && fill == nil {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(WP.border)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Progress bar. The fill grows from the left when it appears.
struct WPBar: View {
    var fraction: Double
    var color: Color = WP.cobalt
    var height: CGFloat = 8
    var label = ""

    var body: some View {
        let value = min(1, max(0, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WP.track)
                Capsule().fill(color).frame(width: max(value > 0 ? height : 0, geo.size.width * value))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.2), value: value)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Work-day buttons, Monday style order from the first weekday. A check mark shows the selected days.
struct DayChips: View {
    @Binding var days: Set<Int>
    let firstWeekday: Int
    /// The last selected day cannot be removed when this is true.
    var keepOne = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach((0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { if !keepOne || days.count > 1 { days.remove(day) } } else { days.insert(day) }
                } label: {
                    HStack(spacing: 3) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)) }
                        Text(Calendar.current.shortWeekdaySymbols[day - 1]).font(WP.font(12, on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Color.white : WP.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(on ? WP.cobalt : WP.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? WP.cobalt : WP.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A coloured note with an icon: information (blue), attention (amber) or success (green).
struct Note: View {
    enum Tone { case info, warn, good }
    var tone = Tone.info
    let text: String

    var body: some View {
        let (symbol, ink, background): (String, Color, Color) = switch tone {
        case .info: ("info.circle", WP.textBlue, WP.infoBg)
        case .warn: ("exclamationmark.triangle", WP.warnInk, WP.warnBg)
        case .good: ("checkmark.circle", WP.greenInk, WP.greenBg)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            Text(text).font(WP.font(13)).foregroundStyle(WP.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Application icons by bundle identifier, read once from macOS.
@MainActor
enum AppIcons {
    // ponytail: no refresh; an application installed while WorkPulse runs gets its icon at the next launch.
    private static var cache: [String: NSImage?] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.hasPrefix("agent.") else { return nil }
        if let known = cache[bundleID] { return known }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

/// The picture of an application: its real icon when macOS knows the application, a terminal
/// symbol for an AI agent, a given symbol, or else its first letter on navy.
struct AppTile: View {
    let name: String?
    var bundleID: String? = nil
    var symbol: String? = nil
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let icon = AppIcons.icon(bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Group {
                    if let glyph = symbol ?? (bundleID?.hasPrefix("agent.") == true ? "terminal" : nil) {
                        Image(systemName: glyph).font(.system(size: size * 0.45, weight: .bold))
                    } else {
                        Text(name?.first.map { String($0).uppercased() } ?? "–").font(WP.font(size * 0.42, .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(WP.navy, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The "live" pulse as a Core Animation layer animation: it runs in the render server, so the app
/// does no work per frame (a SwiftUI opacity animation, or a symbol effect, updated the view graph
/// about 60 times a second while a window was open). It stops with Reduce Motion.
enum LayerPulse {
    @MainActor static func apply(to layer: CALayer?, active: Bool) {
        guard let layer else { return }
        let on = active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if on, layer.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        } else if !on {
            layer.removeAnimation(forKey: "pulse")
        }
    }
}

/// A status symbol that pulses while `live` is true.
struct LiveSymbol: NSViewRepresentable {
    let name: String
    let size: CGFloat
    let color: Color
    var live = false

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        view.contentTintColor = NSColor(color)
        LayerPulse.apply(to: view.layer, active: live)
    }
}

/// A small round dot that pulses (the "Now" badge).
struct LiveDot: NSViewRepresentable {
    let size: CGFloat
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.backgroundColor = NSColor(color).cgColor
        LayerPulse.apply(to: view.layer, active: true)
    }
}

/// A slow pulse for the "live" indicator (still with Reduce Motion).
struct Pulse: ViewModifier {
    var active = true
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.opacity(active && dim && !reduceMotion ? 0.45 : 1)
            .onAppear {
                guard active, !reduceMotion, !Motion.off else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
