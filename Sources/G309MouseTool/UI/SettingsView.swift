import SwiftUI
import ServiceManagement

// MARK: - G HUB-inspired Color Palette

private extension Color {
    static let ghDeep       = Color(red: 0.05, green: 0.05, blue: 0.08)   // #0C0C14
    static let ghSurface    = Color(red: 0.10, green: 0.10, blue: 0.18)   // #1A1A2E
    static let ghElevated   = Color(red: 0.17, green: 0.17, blue: 0.24)   // #2A2A3C
    static let ghHover      = Color(red: 0.20, green: 0.20, blue: 0.29)   // #32324A
    static let ghAccent     = Color(red: 0.00, green: 0.83, blue: 0.78)   // #00D4C8
    static let ghTextPri    = Color.white
    static let ghTextSec    = Color(white: 0.74)                            // #BDBDBD
    static let ghTextTer    = Color(white: 0.42)                            // #6B6B7B
    static let ghBorder     = Color(red: 0.18, green: 0.18, blue: 0.25)   // #2D2D40
    static let ghRed        = Color(red: 0.98, green: 0.02, blue: 0.07)   // #FB0512
}

// MARK: - Main Settings View

struct SettingsView: View {
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var reverser = ScrollReverser.shared
    @ObservedObject private var remapper = ButtonRemapper.shared
    @ObservedObject private var capsLock = CapsLockManager.shared
    @ObservedObject private var fnKey = FnKeyManager.shared
    @State private var showEventLogger = false

    var body: some View {
        ZStack {
            Color.ghDeep.ignoresSafeArea()

            VStack(spacing: 10) {
                if !permissions.hasAllPermissions {
                    permissionBanner
                }
                scrollReverserCard
                buttonRemapperCard
                capsLockCard
                fnKeyCard
                Spacer(minLength: 0)
                footerSection
            }
            .padding(12)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .onAppear { permissions.checkState() }
        .sheet(isPresented: $showEventLogger) {
            eventLoggerSheet
        }
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text("권한 필요")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.ghTextPri)

                HStack(spacing: 8) {
                    if !permissions.accessibilityEnabled {
                        Button("손쉬운 사용") { permissions.requestAccessibility() }
                            .buttonStyle(GHLinkButton())
                    }
                    if !permissions.inputMonitoringEnabled {
                        Button("입력 모니터링") { permissions.requestInputMonitoring() }
                            .buttonStyle(GHLinkButton())
                    }
                }
            }

            Spacer()

            Button(action: { permissions.checkState() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(GHSmallButton())
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .cornerRadius(8)
    }

    // MARK: - Scroll Reverser Card

    private var scrollReverserCard: some View {
        GHCard {
            VStack(spacing: 10) {
                // Header with toggle
                HStack {
                    Image(systemName: "scroll.fill")
                        .foregroundColor(.ghAccent)
                        .font(.system(size: 14))
                    Text("스크롤 반전")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ghTextPri)
                    Spacer()
                    GHToggle(isOn: $reverser.isEnabled)
                }

                if reverser.isEnabled {
                    Divider().overlay(Color.ghBorder)

                    // Mouse section
                    VStack(spacing: 6) {
                        GHSectionLabel("마우스")
                        HStack(spacing: 16) {
                            GHMiniToggle("수직 ↕", isOn: $reverser.reverseMouseVertical)
                            GHMiniToggle("수평 ↔", isOn: $reverser.reverseMouseHorizontal)
                        }
                    }

                    // Trackpad section
                    VStack(spacing: 6) {
                        GHSectionLabel("트랙패드")
                        HStack(spacing: 16) {
                            GHMiniToggle("수직 ↕", isOn: $reverser.reverseTrackpadVertical)
                            GHMiniToggle("수평 ↔", isOn: $reverser.reverseTrackpadHorizontal)
                        }
                    }

                    // Scroll step
                    HStack {
                        Text("스크롤 스텝")
                            .font(.system(size: 11))
                            .foregroundColor(.ghTextSec)
                        Slider(
                            value: Binding(
                                get: { Double(reverser.discreteScrollStep) },
                                set: { reverser.discreteScrollStep = Int32($0) }
                            ),
                            in: 1...10, step: 1
                        )
                        .accentColor(.ghAccent)
                        Text("\(reverser.discreteScrollStep)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.ghAccent)
                            .frame(width: 20, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Button Remapper Card

    private var buttonRemapperCard: some View {
        GHCard {
            VStack(spacing: 10) {
                // Header with toggle
                HStack {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundColor(.ghAccent)
                        .font(.system(size: 14))
                    Text("Space 전환 제스처")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ghTextPri)
                    Spacer()
                    GHToggle(isOn: $remapper.isEnabled)
                }

                if remapper.isEnabled {
                    Divider().overlay(Color.ghBorder)

                    // Trigger button
                    HStack {
                        Text("트리거")
                            .font(.system(size: 11))
                            .foregroundColor(.ghTextSec)

                        Text(remapper.triggerDisplayName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.ghAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.ghAccent.opacity(0.1))
                            .cornerRadius(4)

                        Spacer()

                        Button(remapper.isDetecting ? "대기 중..." : "감지") {
                            if !remapper.isDetecting {
                                remapper.detectedButton = nil
                                remapper.isDetecting = true
                            }
                        }
                        .buttonStyle(GHSmallButton())
                    }

                    if let detected = remapper.detectedButton {
                        HStack {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text(detected.displayName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                            Spacer()
                            Button("적용") {
                                remapper.triggerButton = detected
                                remapper.detectedButton = nil
                            }
                            .buttonStyle(GHAccentButton())
                        }
                    }

                    // Threshold
                    HStack {
                        Text("임계값")
                            .font(.system(size: 11))
                            .foregroundColor(.ghTextSec)
                        Slider(
                            value: Binding(
                                get: { Double(remapper.thresholdPixels) },
                                set: { remapper.thresholdPixels = CGFloat($0) }
                            ),
                            in: 50...500, step: 10
                        )
                        .accentColor(.ghAccent)
                        Text("\(Int(remapper.thresholdPixels))px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.ghAccent)
                            .frame(width: 40, alignment: .trailing)
                    }

                    // Options
                    HStack(spacing: 16) {
                        GHMiniToggle("방향 반전", isOn: $remapper.invertDirection)
                        GHMiniToggle("연속 전환", isOn: $remapper.allowContinuousSwipe)
                    }

                    // Direction hint
                    Text(remapper.invertDirection
                        ? "마우스 ← 이동 → 오른쪽 Space (자연스러운 스크롤)"
                        : "마우스 → 이동 → 오른쪽 Space (표준)")
                        .font(.system(size: 10))
                        .foregroundColor(.ghTextTer)
                }
            }
        }
    }

    // MARK: - Caps Lock Card

    private var capsLockCard: some View {
        GHCard {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "capslock.fill")
                        .foregroundColor(.ghAccent)
                        .font(.system(size: 14))
                    Text("한/영 전환 딜레이 제거")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ghTextPri)
                    Spacer()
                    GHToggle(isOn: $capsLock.isEnabled)
                }

                if capsLock.isEnabled {
                    Text("Caps Lock → F18 리매핑 + 입력 소스 단축키 자동 설정")
                        .font(.system(size: 10))
                        .foregroundColor(.ghTextTer)
                }
            }
        }
    }

    // MARK: - Fn Key Card

    @State private var fnKeyTab: Int = 0

    private var fnKeyCard: some View {
        GHCard {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "keyboard")
                        .foregroundColor(.ghAccent)
                        .font(.system(size: 14))
                    Text("F1~F12 표준 기능키 사용")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ghTextPri)
                    Spacer()
                    GHToggle(isOn: $fnKey.useStandardFnKeys)
                }

                if fnKey.useStandardFnKeys {
                    // External / Internal keyboard tabs
                    Picker("", selection: $fnKeyTab) {
                        Text("외장 키보드").tag(0)
                        Text("내장 키보드").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if fnKeyTab == 0 {
                        Text("미디어키(볼륨/밝기 등)를 F1~F12로 변환합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.ghTextTer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            Text("시스템 기능키 모드")
                                .font(.system(size: 11))
                                .foregroundColor(.ghTextSec)
                            Spacer()
                            GHToggle(isOn: $fnKey.internalFnState)
                        }
                        Text("macOS 설정의 \"F1~F12를 표준 기능 키로 사용\"을 전환합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.ghTextTer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("KMC v1.9.0 by Jc")
                .font(.system(size: 10))
                .foregroundColor(.ghTextTer)

            Spacer()

            // Permission status indicators
            HStack(spacing: 6) {
                statusDot(permissions.accessibilityEnabled, label: "접근성")
                statusDot(permissions.inputMonitoringEnabled, label: "입력")
            }

            Spacer()

            HStack(spacing: 8) {
                Button("이벤트 로거") { showEventLogger = true }
                    .buttonStyle(GHSmallButton())

                Button(action: { LaunchAtLoginHelper.toggle() }) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                }
                .buttonStyle(GHSmallButton())
                .help("로그인 시 자동 시작")
            }
        }
        .padding(.horizontal, 4)
    }

    private func statusDot(_ enabled: Bool, label: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(enabled ? Color.green : Color.ghRed)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.ghTextTer)
        }
    }

    // MARK: - Event Logger Sheet

    private var eventLoggerSheet: some View {
        EventLoggerView()
            .frame(width: 500, height: 400)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Event Logger (Sheet)

struct EventLoggerView: View {
    @ObservedObject private var logger = EventLogger.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.ghDeep.ignoresSafeArea()

            VStack(spacing: 8) {
                HStack {
                    Text("이벤트 로거")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.ghTextPri)
                    Spacer()

                    Button(logger.isLogging ? "중지" : "시작") {
                        logger.isLogging ? logger.stopLogging() : logger.startLogging()
                    }
                    .buttonStyle(GHSmallButton())

                    Button("지우기") { logger.clearLog() }
                        .buttonStyle(GHSmallButton())
                        .disabled(logger.entries.isEmpty)

                    Button("닫기") { dismiss() }
                        .buttonStyle(GHSmallButton())
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Text("DPI 등 특수 버튼은 HID로만 감지됩니다")
                    .font(.system(size: 10))
                    .foregroundColor(.ghTextTer)
                    .padding(.horizontal, 12)

                List(logger.entries) { entry in
                    HStack(spacing: 6) {
                        Text(entry.timestamp, style: .time)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.ghTextTer)
                            .frame(width: 60, alignment: .leading)

                        Text(entry.source)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(entry.source == "HID" ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
                            .cornerRadius(3)
                            .frame(width: 45)

                        Text(entry.type)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.ghAccent)
                            .lineLimit(1)

                        if let btn = entry.buttonNumber {
                            Text("btn=\(btn)")
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 3)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(2)
                        }

                        if !entry.details.isEmpty {
                            Text(entry.details)
                                .font(.system(size: 9))
                                .foregroundColor(.ghTextSec)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .listRowBackground(Color.ghSurface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - Custom G HUB-style Components

struct GHCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(14)
            .background(Color.ghSurface)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ghBorder, lineWidth: 0.5))
    }
}

struct GHToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            RoundedRectangle(cornerRadius: 10)
                .fill(isOn ? Color.ghAccent : Color.ghElevated)
                .frame(width: 36, height: 20)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: isOn ? 8 : -8),
                    alignment: .center
                )
                .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

struct GHMiniToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { isOn.toggle() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? Color.ghAccent : Color.ghElevated)
                    .frame(width: 14, height: 14)
                    .overlay(
                        isOn ?
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.ghDeep)
                        : nil
                    )
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.ghTextSec)
        }
    }
}

struct GHSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.ghTextTer)
                .kerning(1)
            Spacer()
        }
    }
}

struct GHSmallButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.ghTextSec)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Color.ghHover : Color.ghElevated)
            .cornerRadius(4)
    }
}

struct GHAccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.ghDeep)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Color.ghAccent.opacity(0.8) : Color.ghAccent)
            .cornerRadius(4)
    }
}

struct GHLinkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.ghAccent)
            .underline(configuration.isPressed)
    }
}

// MARK: - Launch at Login Helper

enum LaunchAtLoginHelper {
    static func toggle() {
        let current = SMAppService.mainApp.status == .enabled
        setEnabled(!current)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            fputs("[LaunchAtLogin] Error: \(error)\n", stderr)
        }
    }
}
