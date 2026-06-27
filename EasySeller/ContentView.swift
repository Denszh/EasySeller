//
//  ContentView.swift
//  EasySeller
//
//  Created by DENG ZHIHAO on 2026/6/28.
//

import SwiftUI
import SwiftData
import UserNotifications
import Combine

// MARK: - ViewModel & Models
@MainActor
final class PomodoroViewModel: ObservableObject {
    enum Phase: String { case focus, shortBreak, longBreak }
    enum Reminder: String, CaseIterable, Identifiable { case silent, haptic, sound
        var id: String { rawValue }
        var title: String { switch self { case .silent: return "静音"; case .haptic: return "震动"; case .sound: return "提示音" } }
    }

    // Cycle configuration
    @Published var focusDuration: TimeInterval = 25*60
    @Published var shortBreakDuration: TimeInterval = 5*60
    @Published var longBreakDuration: TimeInterval = 15*60
    @Published var longBreakInterval: Int = 4 // after N focus sessions

    @Published var reminder: Reminder = .haptic
    @Published var notificationsEnabled: Bool = false

    // State
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var remaining: TimeInterval = 25*60
    @Published private(set) var completedFocusCount: Int = 0

    // Stats (in-memory for now)
    @Published private(set) var totalFocusSeconds: TimeInterval = 0
    @Published private(set) var todayFocusSeconds: TimeInterval = 0
    @Published private(set) var weekFocusSeconds: TimeInterval = 0

    private var timerTask: Task<Void, Never>? = nil
    private var lastTick: Date? = nil

    init() {
        remaining = focusDuration
    }

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationsEnabled = granted
        } catch {
            notificationsEnabled = false
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = Date()
        scheduleNotificationIfNeeded()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            guard let self else { return }
            await self.runTimer()
        }
    }

    func pause() {
        isRunning = false
    }

    func reset() {
        isRunning = false
        remaining = duration(for: phase)
    }

    func quickStart(minutes: Int) {
        phase = .focus
        focusDuration = TimeInterval(minutes*60)
        remaining = focusDuration
        start()
    }

    func togglePhase() {
        isRunning = false
        switch phase {
        case .focus:
            phase = .shortBreak
        case .shortBreak, .longBreak:
            phase = .focus
        }
        remaining = duration(for: phase)
    }

    private func runTimer() async {
        while !Task.isCancelled {
            guard isRunning else { try? await Task.sleep(nanoseconds: 50_000_000); continue }
            let now = Date()
            let delta = now.timeIntervalSince(lastTick ?? now)
            lastTick = now
            remaining = max(0, remaining - delta)
            if phase == .focus { totalFocusSeconds += delta; todayFocusSeconds += delta; weekFocusSeconds += delta }
            if remaining <= 0.0 { await handlePhaseCompletion() }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }

    private func handlePhaseCompletion() async {
        isRunning = false
        sendHapticOrSound()
        await fireCompletionNotification()

        switch phase {
        case .focus:
            completedFocusCount += 1
            if completedFocusCount % max(1, longBreakInterval) == 0 {
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
        case .shortBreak, .longBreak:
            phase = .focus
        }
        remaining = duration(for: phase)
        start() // auto-continue next phase
    }

    private func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return focusDuration
        case .shortBreak: return shortBreakDuration
        case .longBreak: return longBreakDuration
        }
    }

    private func sendHapticOrSound() {
        switch reminder {
        case .silent: break
        case .haptic:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        case .sound:
            // Simple system sound via notification; custom sounds can be added later
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }

    private func scheduleNotificationIfNeeded() {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = phase == .focus ? "专注结束" : (phase == .shortBreak ? "短休结束" : "长休结束")
        content.body = "下一阶段即将开始"
        if reminder == .sound { content.sound = .default }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false)
        let request = UNNotificationRequest(identifier: "pomodoro.nextPhase", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func fireCompletionNotification() async {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "阶段完成"
        content.body = phase == .focus ? "专注完成，休息一下吧" : "休息结束，继续专注！"
        if reminder == .sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: "pomodoro.completed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject private var vm = PomodoroViewModel()

    // Visual preferences
    @State private var theme: Theme = .neon
    @State private var reducedMotion: Bool = false

    var body: some View {
        ZStack {
            dynamicBackground
                .ignoresSafeArea()

            GeometryReader { proxy in
                let height = proxy.size.height
                let width = proxy.size.width
                let compact = height < 700
                let ringSize = min(width, height) * (compact ? 0.5 : 0.54)
                let topSpacing: CGFloat = compact ? 12 : 24
                let sectionSpacing: CGFloat = compact ? 14 : 24

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: sectionSpacing) {
                        header

                        ZStack {
                            progressRing(size: ringSize)
                                .frame(width: ringSize, height: ringSize)

                            VStack(spacing: 8) {
                                Text(titleForPhase(vm.phase))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity.combined(with: .scale))

                                Text(timeString(vm.remaining))
                                    .font(.system(size: min(52, ringSize * 0.22), weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.spring(response: 0.45, dampingFraction: 0.9), value: vm.remaining)
                            }
                        }
                        .padding(.top, topSpacing)

                        controls(compact: compact)

                        settingsSection
                        quickStartSection
                        statsSection
                    }
                    .padding(24)
                    .padding(.vertical, compact ? 8 : 16)
                    .frame(maxWidth: min(width * 0.92, 520))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .task { await vm.requestNotificationPermission() }
    }
}

// MARK: - Subviews & Sections
private extension ContentView {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("番茄定时器")
                    .font(.largeTitle.weight(.bold))
                Text(subtitleForPhase(vm.phase))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("主题", selection: $theme) {
                    ForEach(Theme.allCases) { t in
                        Text(t.title).tag(t)
                    }
                }
                Toggle("动效精简", isOn: $reducedMotion)
                Picker("提醒方式", selection: $vm.reminder) {
                    ForEach(PomodoroViewModel.Reminder.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                Toggle("允许通知", isOn: $vm.notificationsEnabled)
            } label: {
                Label("设置", systemImage: "gearshape")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    func controls(compact: Bool) -> some View {
        HStack(spacing: 18) {
            Button {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    if vm.isRunning { vm.pause() } else { vm.start() }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: vm.isRunning ? "pause.fill" : "play.fill")
                    Text(vm.isRunning ? "暂停" : "开始")
                }
                .font(.headline)
                .padding(.horizontal, compact ? 16 : 22)
                .padding(.vertical, compact ? 10 : 14)
                .background(angularGlow.gradient, in: Capsule())
                .foregroundStyle(.white)
                .shadow(color: angularGlow.shadowColor.opacity(0.35), radius: 18, y: 6)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                    vm.reset()
                }
            } label: {
                Label("重置", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(.horizontal, compact ? 14 : 18)
                    .padding(.vertical, compact ? 10 : 14)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    var settingsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("循环设置")
                    .font(.headline)
                Spacer()
            }

            HStack {
                Text("专注")
                Spacer()
                Stepper(value: $vm.focusDuration, in: 5*60...90*60, step: 60) {
                    Text("\(Int(vm.focusDuration/60)) 分钟").monospacedDigit()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack {
                Text("短休")
                Spacer()
                Stepper(value: $vm.shortBreakDuration, in: 1*60...30*60, step: 60) {
                    Text("\(Int(vm.shortBreakDuration/60)) 分钟").monospacedDigit()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack {
                Text("长休")
                Spacer()
                Stepper(value: $vm.longBreakDuration, in: 5*60...60*60, step: 60) {
                    Text("\(Int(vm.longBreakDuration/60)) 分钟").monospacedDigit()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack {
                Text("长休间隔")
                Spacer()
                Stepper(value: $vm.longBreakInterval, in: 2...8, step: 1) {
                    Text("每 \(vm.longBreakInterval) 次专注").monospacedDigit()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷开始").font(.headline)
            HStack(spacing: 12) {
                ForEach([15, 25, 50], id: \.self) { m in
                    Button("\(m) 分钟") { vm.quickStart(minutes: m) }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
            }
        }
    }

    var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("统计").font(.headline)
            HStack {
                Label("完成专注：\(vm.completedFocusCount) 次", systemImage: "checkmark.circle")
                Spacer()
                Label("累计：\(formatMinutes(vm.totalFocusSeconds))", systemImage: "clock")
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Progress & Background
private extension ContentView {
    func progressRing(size: CGFloat) -> some View {
        let total = vm.phase == .focus ? vm.focusDuration : (vm.phase == .shortBreak ? vm.shortBreakDuration : vm.longBreakDuration)
        let progress = max(0, min(1, 1 - vm.remaining / max(1, total)))
        let lineWidth: CGFloat = max(12, size * 0.06)

        return ZStack {
            Circle()
                .stroke(AngularGradient(gradient: Gradient(colors: angularGlow.colors), center: .center), lineWidth: lineWidth)
                .opacity(0.12)
                .blur(radius: 6)
                .scaleEffect(1.0)
                .animation(reducedMotion ? nil : .easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: vm.isRunning)

            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(gradient: Gradient(colors: angularGlow.colors), center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)

            Circle()
                .fill(angularGlow.colors.first ?? .blue)
                .frame(width: max(8, size*0.045), height: max(8, size*0.045))
                .offset(y: -(size/2))
                .rotationEffect(.degrees(Double(progress) * 360))
                .shadow(color: (angularGlow.colors.first ?? .blue).opacity(0.6), radius: 8)
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
        }
    }

    var dynamicBackground: some View {
        ZStack {
            LinearGradient(colors: vm.phase == .focus ? [Color(#colorLiteral(red: 0.08, green: 0.09, blue: 0.15, alpha: 1)), Color(#colorLiteral(red: 0.02, green: 0.02, blue: 0.06, alpha: 1))] : [Color(#colorLiteral(red: 0.04, green: 0.12, blue: 0.09, alpha: 1)), Color(#colorLiteral(red: 0.01, green: 0.05, blue: 0.04, alpha: 1))], startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(.easeInOut(duration: 0.6), value: vm.phase)

            Circle()
                .fill(AngularGradient(gradient: Gradient(colors: angularGlow.colors), center: .center))
                .blur(radius: 120)
                .opacity(0.18)
                .scaleEffect(vm.phase == .focus ? 1.1 : 0.9)
                .animation(.spring(response: 0.8, dampingFraction: 0.9), value: vm.phase)
                .frame(width: UIScreen.main.bounds.width * 1.2, height: UIScreen.main.bounds.width * 1.2)
        }
    }
}

// MARK: - Helpers & Theme
private extension ContentView {
    func titleForPhase(_ p: PomodoroViewModel.Phase) -> String { p == .focus ? "专注" : (p == .shortBreak ? "短休" : "长休") }
    func subtitleForPhase(_ p: PomodoroViewModel.Phase) -> String {
        switch p { case .focus: return "保持专注，完成一段高质量工作"; case .shortBreak: return "短暂放松，继续高效"; case .longBreak: return "深度放松，准备下一轮" }
    }
    func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds)); let m = s/60; let sec = s%60
        return String(format: "%02d:%02d", m, sec)
    }
    func formatMinutes(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds/60)
        return "\(mins) 分钟"
    }

    enum Theme: String, CaseIterable, Identifiable { case neon, warm, minimal
        var id: String { rawValue }
        var title: String { switch self { case .neon: return "霓虹"; case .warm: return "暖色"; case .minimal: return "极简" } }
        var colors: [Color] {
            switch self {
            case .neon: return [.pink, .purple, .blue]
            case .warm: return [.orange, .pink, .red]
            case .minimal: return [.teal, .cyan, .mint]
            }
        }
    }

    var angularGlow: (colors: [Color], gradient: LinearGradient, shadowColor: Color) {
        let colors: [Color] = theme.colors
        let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        let shadow = colors.last ?? .blue
        return (colors, gradient, shadow)
    }
}

#Preview { ContentView() }

