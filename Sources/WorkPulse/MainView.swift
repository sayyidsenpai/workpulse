import SwiftUI
import WorkPulseCore

/// The main window: sections on the left, the selected screen on the right, on one glass panel.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(text: banner) { model.banner = nil }.padding([.horizontal, .top], 16)
                }
                screen
                    .id(model.tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WP.content.ignoresSafeArea())
        }
        .background { Backdrop() }
        .frame(minWidth: 920, minHeight: 620)
    }

    @ViewBuilder private var screen: some View {
        switch model.tab {
        case .history: HistoryView()
        case .reports: ReportsView()
        case .work: WorkView()
        case .rules: RulesView()
        case .sleep: SleepView()
        case .settings: SettingsView()
        }
    }
}

/// Wraps one screen: scrolls, keeps a readable width and the same margins everywhere.
struct Screen<Content: View>: View {
    var maxWidth: CGFloat = 980
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                Text("WorkPulse").font(WP.font(15, .bold)).tracking(-0.2).foregroundStyle(WP.ink)
            }
            .padding(.horizontal, 6)
            VStack(spacing: 2) {
                ForEach(MainTab.allCases) { tab in
                    SidebarItem(tab: tab, selected: model.tab == tab) {
                        withAnimation(.easeOut(duration: 0.15)) { model.tab = tab }
                    }
                }
            }
            Spacer(minLength: 12)
            StatusCard()
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
        .frame(width: 210)
        .overlay(alignment: .trailing) { Rectangle().fill(WP.hairline).frame(width: 1).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct SidebarItem: View {
    let tab: MainTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(tab.rawValue).font(WP.font(13, selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : WP.ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? WP.cobalt : hovered ? WP.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: selected ? WP.cobalt.opacity(0.3) : .clear, radius: 5, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The current status, small: the same colour, icon and words as the popover.
private struct StatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hero = model.hero
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: hero.symbol).font(.system(size: 12, weight: .bold)).modifier(Pulse(active: hero.live))
                    .id(hero.symbol + (hero.live ? "-live" : ""))
                Text(hero.title).font(WP.font(12, .semibold)).lineLimit(1)
            }
            Live { now in
                Text(hero.big(now)).font(WP.font(20, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            // The short form when the application name does not fit: the text is never cut.
            let today = "Today \(Fmt.duration(model.summary.today.work, seconds: false))"
            ViewThatFits(in: .horizontal) {
                if let app = model.frontApp?.name { Text("\(app) · \(today)") }
                Text(today)
            }
            .font(WP.font(12)).foregroundStyle(hero.sub).lineLimit(1)
        }
        .foregroundStyle(hero.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                hero.fill
                LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.03))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: hero.fill.opacity(0.3), radius: 9, y: 8)
        .animation(.easeInOut(duration: 0.5), value: hero.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
    }
}
