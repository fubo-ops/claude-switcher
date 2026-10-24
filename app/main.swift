import SwiftUI
import AppKit
import Combine

// MARK: - 模型

enum RowState: Equatable { case pending, ok, warn, fail }

struct CheckRow: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var state: RowState = .pending
    var detail: String = ""
}

enum Phase: Equatable { case checking, ready, failed, switching, done, fixing }

/// checkdetail 的一行解析结果；row 为 UI 行下标，保证与 14 项顺序一致
struct ParsedRow: Equatable {
    let row: Int
    let state: RowState
    let detail: String
}

/// 菜单栏/状态胶囊共用的展示信息
struct StatusPresentation {
    let symbol: String
    let color: NSColor
    let headline: String
    let tooltip: String
}

// MARK: - 模型层

final class VM: ObservableObject {
    static let shared = VM()

    /// 与 core/claude-switch.sh 的 checkdetail 输出顺序严格一致
    static let rowNames: [String] = [
        "代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区",
        "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言",
        "ASN属性", "生态可达性",
    ]

    static func makeDefaultRows() -> [CheckRow] {[
        CheckRow(name: "代理内核", icon: "cpu"),
        CheckRow(name: "TUN 网卡", icon: "cable.connector"),
        CheckRow(name: "出口 IP", icon: "globe.americas"),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal"),
        CheckRow(name: "时区", icon: "clock"),
        CheckRow(name: "地区", icon: "flag"),
        CheckRow(name: "IPv6 关闭", icon: "6.circle"),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass"),
        CheckRow(name: "WebRTC", icon: "eye.slash"),
        CheckRow(name: "保镖在线", icon: "hand.raised"),
        CheckRow(name: "规则置顶", icon: "list.number"),
        CheckRow(name: "客户端语言", icon: "abc"),
        CheckRow(name: "ASN 属性", icon: "building.columns"),
        CheckRow(name: "生态可达性", icon: "antenna.radiowaves.left.and.right"),
    ]}

    @Published var rows: [CheckRow] = VM.makeDefaultRows()
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var hasB = false
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published var showNotice = false
    @Published var showFingerprint = false

    /// 动态展示用状态
    @Published var elapsed: TimeInterval = 0
    @Published var lastCheckAt: Date?
    @Published var matched = 0

    let core = NSHomeDirectory() + "/.local/bin/claude-switch.sh"

    private var ticker: Timer?
    private var autoTicker: Timer?
    /// 是否有脚本在跑（与 phase 解耦：初始 phase 就是 .checking，不能据此判断）
    private(set) var running = false
    /// 后台静默刷新时不算“忙”，避免每分钟闪一次扫描条
    private var autoRun = false

    var busy: Bool { running && !autoRun }

    var counts: (ok: Int, warn: Int, fail: Int) { VM.summary(of: rows) }

    var worst: RowState {
        if rows.contains(where: { $0.state == .fail }) { return .fail }
        if rows.contains(where: { $0.state == .warn }) { return .warn }
        if rows.allSatisfy({ $0.state == .ok }) { return .ok }
        return .pending
    }

    var presentation: StatusPresentation {
        let c = counts
        let acc = current == "?" ? "未初始化" : current
        switch phase {
        case .checking:
            return StatusPresentation(symbol: "shield.lefthalf.filled", color: .systemBlue,
                                      headline: "正在检查 14 项环境指标…",
                                      tooltip: "Claude 切换器 · 检查中 \(fmt(elapsed))")
        case .fixing:
            return StatusPresentation(symbol: "shield.lefthalf.filled", color: .systemOrange,
                                      headline: "正在一键修复…",
                                      tooltip: "Claude 切换器 · 修复中 \(fmt(elapsed))")
        case .switching:
            return StatusPresentation(symbol: "shield.lefthalf.filled", color: .systemBlue,
                                      headline: "正在切换账号…",
                                      tooltip: "Claude 切换器 · 切换中 \(fmt(elapsed))")
        default:
            if matched > 0 && matched < rows.count {
                return StatusPresentation(symbol: "shield.lefthalf.filled", color: .systemGray,
                                          headline: "检测结果不完整 \(matched)/\(rows.count)",
                                          tooltip: "Claude 切换器 · 结果不完整")
            }
            if c.fail > 0 {
                return StatusPresentation(symbol: "xmark.shield.fill", color: .systemRed,
                                          headline: "检查未过 · \(c.fail) 项失败",
                                          tooltip: "Claude 切换器 · 账号 \(acc) · \(c.fail) 项失败，禁止启动")
            }
            if c.warn > 0 {
                return StatusPresentation(symbol: "exclamationmark.shield.fill", color: .systemYellow,
                                          headline: "环境安全 · \(c.ok) 通过 / \(c.warn) 告警",
                                          tooltip: "Claude 切换器 · 账号 \(acc) · \(c.ok) 通过 / \(c.warn) 告警")
            }
            if c.ok == rows.count {
                return StatusPresentation(symbol: "checkmark.shield.fill", color: .systemGreen,
                                          headline: "环境安全 · 14 项全部通过",
                                          tooltip: "Claude 切换器 · 账号 \(acc) · 14 项全部通过")
            }
            return StatusPresentation(symbol: "shield", color: .secondaryLabelColor,
                                      headline: "尚未检查",
                                      tooltip: "Claude 切换器 · 尚未检查")
        }
    }

    // MARK: 状态栏图标（模板调色，菜单栏可显示彩色盾牌）

    /// 取图标平均色，用于自检彩色盾牌是否真的着色
    static func dominantColor(_ img: NSImage) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var r = 0, g = 0, b = 0, n = 0
        let stepX = max(1, rep.pixelsWide / 32)
        let stepY = max(1, rep.pixelsHigh / 32)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3 else { continue }
                r += Int(c.redComponent * 255)
                g += Int(c.greenComponent * 255)
                b += Int(c.blueComponent * 255)
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (r / n, g / n, b / n, n)
    }

    static func makeStatusImage(symbol: String, color: NSColor) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let palette = base.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude 切换器")?
            .withSymbolConfiguration(palette) else { return nil }
        img.isTemplate = false
        return img
    }

    // MARK: 纯函数：解析 checkdetail 输出（可被 --selftest 直接测试）

    static func parseCheckOutput(_ out: String) -> [ParsedRow] {
        var map: [Int: ParsedRow] = [:]
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let idx = rowNames.firstIndex(of: String(parts[0])) else { continue }
            let rhs = String(parts[1])
            let status = rhs.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = status.first else { continue }
            let code = String(first)
            let detail = status.count > 1 ? String(status[1]) : ""
            let state: RowState
            switch code {
            case "ok": state = .ok
            case "warn": state = .warn
            default: state = .fail
            }
            map[idx] = ParsedRow(row: idx, state: state, detail: detail)
        }
        return map.values.sorted { $0.row < $1.row }
    }

    static func summary(of rows: [CheckRow]) -> (ok: Int, warn: Int, fail: Int) {
        var ok = 0, warn = 0, fail = 0
        for r in rows {
            switch r.state {
            case .ok: ok += 1
            case .warn: warn += 1
            case .fail: fail += 1
            case .pending: break
            }
        }
        return (ok, warn, fail)
    }

    static func summary(of parsed: [ParsedRow]) -> (ok: Int, warn: Int, fail: Int) {
        var ok = 0, warn = 0, fail = 0
        for p in parsed {
            switch p.state {
            case .ok: ok += 1
            case .warn: warn += 1
            case .fail: fail += 1
            case .pending: break
            }
        }
        return (ok, warn, fail)
    }

    // MARK: 日志

    static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let path = "/tmp/switcher-debug.log"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func fmt(_ t: TimeInterval) -> String { String(format: "%.1fs", t) }

    // MARK: 计时（检查/切换/修复时长）

    func startTick() {
        ticker?.invalidate()
        elapsed = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 0.1
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stopTick() {
        ticker?.invalidate()
        ticker = nil
    }

    /// 常驻菜单栏后每 60 秒静默刷新一次；窗口不可见时不播逐行动画
    func startAutoRefresh(interval: TimeInterval = 60) {
        autoTicker?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            self.refresh(animated: false, auto: true)  // 后台静默刷新，只有手动/首次才播逐行动画
        }
        t.tolerance = 8
        RunLoop.main.add(t, forMode: .common)
        autoTicker = t
    }

    // MARK: 执行核心脚本

    func run(_ args: [String], timeout: TimeInterval = 45, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let tmp = "/tmp/switcher-out-\(UUID().uuidString).txt"
            FileManager.default.createFile(atPath: tmp, contents: nil)
            let p = Process()
            p.launchPath = "/bin/bash"
            p.arguments = [self.core] + args
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: tmp)) {
                p.standardOutput = fh
                p.standardError = fh
            }
            var timedOut = false
            let watchdog = DispatchWorkItem {
                if p.isRunning { timedOut = true; p.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            do { try p.launch() } catch {
                DispatchQueue.main.async { done("FAIL:无法启动脚本 \(error.localizedDescription)") }
                return
            }
            p.waitUntilExit()
            watchdog.cancel()
            if let fh = p.standardOutput as? FileHandle { try? fh.close() }
            let data = (try? Data(contentsOf: URL(fileURLWithPath: tmp))) ?? Data()
            let out = String(decoding: data, as: UTF8.self)  // 容错解码：坏字节替换而非整体失败
            try? FileManager.default.removeItem(atPath: tmp)
            VM.log("args=\(args) timedOut=\(timedOut) exit=\(p.terminationStatus) 耗时\(String(format: "%.1f", Date().timeIntervalSince(started)))s stdout=\(out.count)字符")
            if timedOut {
                DispatchQueue.main.async { done("FAIL:操作超时，请重试") }
                return
            }
            DispatchQueue.main.async { done(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // MARK: 检查（带逐行点亮动画）

    func refresh(animated: Bool = true, auto: Bool = false) {
        guard !running else { return }
        running = true
        autoRun = auto
        if !auto {
            phase = .checking
            banner = ""
            note = ""
            matched = 0
            for i in rows.indices { rows[i].state = .pending; rows[i].detail = "" }
            startTick()
        }
        VM.log("refresh start animated=\(animated) auto=\(auto)")
        run(["checkdetail"]) { out in
            // 输出为空时回退到脚本落盘的结果文件（双保险）
            var raw = out
            if raw.isEmpty,
               let diskData = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.claude-switcher/last-check.txt")),
               !diskData.isEmpty {
                raw = String(decoding: diskData, as: UTF8.self)
            }
            let parsed = VM.parseCheckOutput(raw)
            self.run(["status"]) { st in
                if st.contains("current=B") { self.current = "B" }
                else if st.contains("current=A") { self.current = "A" }
                else { self.current = "未初始化" }
                self.hasB = st.contains("hasB=1")
                self.apply(parsed: parsed, animated: animated)
            }
        }
    }

    func apply(parsed: [ParsedRow], animated: Bool) {
        running = false
        autoRun = false
        stopTick()
        lastCheckAt = Date()
        matched = parsed.count
        let allOk = !parsed.contains(where: { $0.state == .fail })
        let targetPhase: Phase = allOk ? .ready : .failed
        VM.log("apply parsed=\(parsed.count) targetPhase=\(targetPhase)")

        if parsed.count < rows.count {
            withAnimation(.easeInOut(duration: 0.3)) { phase = .failed }
            banner = "检测输出不完整(\(parsed.count)/\(rows.count))，请点重新检查"
            return
        }

        if animated && WindowBridge.isVisible {
            for (i, p) in parsed.enumerated() {
                let delay = 0.055 * Double(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 0.28)) {
                        if p.row < self.rows.count {
                            self.rows[p.row].state = p.state
                            self.rows[p.row].detail = p.detail
                        }
                    }
                }
            }
            let total = 0.055 * Double(parsed.count) + 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + total) {
                withAnimation(.easeInOut(duration: 0.32)) { self.phase = targetPhase }
                VM.log("reveal done phase=\(targetPhase)")
            }
        } else {
            for p in parsed where p.row < rows.count {
                rows[p.row].state = p.state
                rows[p.row].detail = p.detail
            }
            phase = targetPhase
        }
    }

    // MARK: 一键修复 / 切换账号

    func fixAll() {
        guard !running else { return }
        running = true
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        startTick()
        run(["fix"], timeout: 180) { out in
            let steps = out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("FIX:") }.map { String($0.dropFirst(4)) }
            self.running = false
            self.stopTick()
            self.banner = steps.last ?? ""
            self.refresh(animated: true)
        }
    }

    func switchTo(_ target: String) {
        guard phase == .ready || phase == .done, !running else { return }
        running = true
        let firstB = (target == "B" && !hasB)
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        startTick()
        VM.log("switch start target=\(target)")
        run(["switch", target], timeout: 180) { out in
            self.running = false
            self.stopTick()
            if out.hasPrefix("FAIL:") {
                self.phase = .failed
                self.banner = String(out.dropFirst(5))
                VM.log("switch failed: \(out)")
                return
            }
            self.current = target
            if target == "B" { self.hasB = true }
            self.phase = .done
            self.banner = out.hasPrefix("INFO:") ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = firstB && !out.hasPrefix("INFO:") ? "B 号首次使用：请在打开的 Claude 里登录 B 账号，登录一次即可。" : ""
            VM.log("switch done target=\(target) 用时会话结束")
            // 常驻菜单栏：切换完成后只收起窗口，不退出进程（旧版会 terminate）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { WindowBridge.hide() }
        }
    }
}

// MARK: - 窗口引用（菜单栏「打开主窗口」用）

enum WindowBridge {
    static weak var window: NSWindow?

    static var isVisible: Bool { window?.isVisible ?? false }

    static func show() {
        if window == nil {
            window = NSApp.windows.first(where: { $0.contentViewController != nil && $0.canBecomeMain })
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.10, green: 0.07, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 14) {
                header
                if vm.busy { scanBar.transition(.opacity) }
                checksCard
                if vm.phase == .ready || vm.phase == .switching || vm.phase == .done {
                    accountCard.transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if vm.phase == .failed || vm.phase == .fixing {
                    retryCard.transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
        }
        .frame(width: 440, height: 860)
        .onAppear { vm.refresh(animated: true) }
        .animation(.easeInOut(duration: 0.35), value: vm.phase)
    }

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude 账号切换器").font(.title3.bold()).foregroundColor(.white)
                Text(vm.busy ? "安全检查 · 已用 \(vm.fmt(vm.elapsed))" : "安全检查 · 切换 · 启动")
                    .font(.caption).foregroundColor(.white.opacity(0.55))
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                vm.fingerprint = "正在体检…"
                vm.showFingerprint = true
                vm.run(["fingerprint"], timeout: 90) { vm.fingerprint = $0 }
            } label: {
                Image(systemName: "waveform.path.ecg").font(.title3).foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("设备指纹体检(字体/GPU/虚拟机)")
            Button { vm.showNotice = true } label: {
                Image(systemName: "info.circle").font(.title3).foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("安全防护体系公告")
            statusPill
        }
        .sheet(isPresented: $vm.showNotice) { NoticeView() }
        .sheet(isPresented: $vm.showFingerprint) { FingerprintView(text: vm.fingerprint) }
    }

    var scanBar: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.3) / 1.3
                Capsule()
                    .fill(LinearGradient(colors: [Color.indigo.opacity(0), Color.indigo, Color.purple, Color.indigo.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * 0.34)
                    .offset(x: (geo.size.width + geo.size.width * 0.34) * t - geo.size.width * 0.34)
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .background(Color.white.opacity(0.06).clipShape(Capsule()))
    }

    var statusPill: some View {
        let p = vm.presentation
        return HStack(spacing: 5) {
            Image(systemName: p.symbol).font(.caption2)
            Text(shortStatus).font(.caption.bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(nsColor: p.color).opacity(0.18))
        .foregroundColor(Color(nsColor: p.color))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.3), value: shortStatus)
        .scaleEffect(vm.busy ? 1.03 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vm.busy)
    }

    var shortStatus: String {
        switch vm.phase {
        case .checking: return "检查中"
        case .ready: return vm.counts.warn > 0 ? "环境安全(告警)" : "环境安全"
        case .failed: return "检查未过"
        case .switching: return "切换中"
        case .fixing: return "修复中"
        case .done: return "完成"
        }
    }

    var checksCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: 10) {
                    Image(systemName: row.icon)
                        .frame(width: 20)
                        .foregroundColor(.white.opacity(0.65))
                    Text(row.name).font(.callout).foregroundColor(.white.opacity(0.9))
                    Spacer()
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.caption).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                            .transition(.opacity)
                    }
                    stateIcon(row.state)
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .opacity(row.state == .pending ? 0.5 : 1)
                .animation(.easeOut(duration: 0.3), value: row.state)
                if idx < vm.rows.count - 1 {
                    Divider().background(Color.white.opacity(0.08))
                }
            }
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }

    func stateIcon(_ s: RowState) -> some View {
        Group {
            switch s {
            case .pending: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
            }
        }
        .font(.callout)
        .transition(.scale.combined(with: .opacity))
        .animation(.easeOut(duration: 0.25), value: s)
    }

    var accountCard: some View {
        VStack(spacing: 12) {
            if vm.phase == .switching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("\(vm.banner) 已用 \(vm.fmt(vm.elapsed))")
                        .font(.callout).foregroundColor(.white.opacity(0.85))
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if vm.phase == .done {
                VStack(spacing: 4) {
                    Label(vm.banner, systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.callout.bold())
                    if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(.yellow.opacity(0.9)).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                HStack(spacing: 6) {
                    Text("当前账号").font(.caption).foregroundColor(.white.opacity(0.5))
                    Text(vm.current).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.3)).foregroundColor(.indigo.opacity(1.4))
                        .clipShape(Capsule())
                    Spacer()
                }
                HStack(spacing: 10) {
                    accountButton("A", subtitle: vm.current == "A" ? "当前" : "已建档")
                    accountButton("B", subtitle: vm.current == "B" ? "当前" : (vm.hasB ? "已建档" : "未初始化"))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }

    func accountButton(_ t: String, subtitle: String) -> some View {
        Button { vm.switchTo(t) } label: {
            VStack(spacing: 4) {
                Text("账号 \(t)").font(.headline).foregroundColor(.white)
                Text(subtitle).font(.caption2).foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                vm.current == t
                ? LinearGradient(colors: [Color.indigo.opacity(0.6), Color.purple.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.current == t ? Color.indigo : Color.white.opacity(0.1), lineWidth: 1.2))
            .scaleEffect(vm.current == t ? 1.0 : 0.985)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.current)
    }

    var retryCard: some View {
        VStack(spacing: 10) {
            if vm.phase == .fixing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("\(vm.banner) 已用 \(vm.fmt(vm.elapsed))")
                        .font(.callout).foregroundColor(.white.opacity(0.85))
                        .contentTransition(.numericText())
                }
            } else {
                if !vm.banner.isEmpty {
                    Text(vm.banner).font(.callout).foregroundColor(.red.opacity(0.95)).multilineTextAlignment(.center)
                }
                Text("存在未通过项，可一键修复或手动处理后重试").font(.caption).foregroundColor(.white.opacity(0.6))
                HStack(spacing: 10) {
                    Button { vm.fixAll() } label: {
                        Label("一键修复", systemImage: "wand.and.stars")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { vm.refresh() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.25)))
    }

    var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.caption2)
                Text("任何一项检查不过，都不会启动 Claude").font(.caption2)
            }
            .foregroundColor(.white.opacity(0.35))
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.caption2)
                Text(vm.lastCheckAt.map { "上次检查 \(hhmmss($0))" } ?? "尚未检查")
                Text("· 每 60 秒自动刷新")
            }
            .foregroundColor(.white.opacity(0.25)).font(.caption2)
        }
    }
}

func hhmmss(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

// MARK: - 设备指纹体检

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备指纹体检").font(.headline).foregroundColor(.white)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(.indigo)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(.caption).foregroundColor(.white.opacity(0.55))
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .background(Color(red: 0.07, green: 0.08, blue: 0.13))
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。任一指标不达标即 Block-on-Fail，杜绝带病启动。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.10, green: 0.07, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(.white)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(.indigo.opacity(1.3))
                                Text(s.1).font(.caption).foregroundColor(.white.opacity(0.7)).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
    }
}

// MARK: - AppDelegate：菜单栏常驻

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var lastSymbol = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：已有实例在跑就激活它并退出自己（替代“关窗即退出”的旧防重逻辑）
        let bundleID = Bundle.main.bundleIdentifier ?? "local.claude-switcher"
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != getpid() }) {
            VM.log("single-instance: found other pid=\(other.processIdentifier), exit self")
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        bind()
        VM.shared.startAutoRefresh()
        VM.log("app launched pid=\(getpid())")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = VM.makeStatusImage(symbol: "shield.lefthalf.filled", color: .secondaryLabelColor)
            b.imagePosition = .imageOnly
            b.toolTip = "Claude 切换器"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        VM.log("statusItem created visible=\(item.isVisible) button=\(item.button != nil) length=\(item.length)")
        menuNeedsUpdate(menu)  // 立即物化一次，便于自检
        refreshStatusItem()
    }

    private func bind() {
        VM.shared.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
        VM.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
        VM.shared.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let p = VM.shared.presentation
        button.image = VM.makeStatusImage(symbol: p.symbol, color: p.color)
        button.toolTip = p.tooltip
        if lastSymbol != p.symbol {
            lastSymbol = p.symbol
            VM.log("statusItem=\(p.symbol) headline=\(p.headline)")
        }
        statusItem?.menu?.update()
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let vm = VM.shared
        let p = vm.presentation
        let c = vm.counts

        let head = NSMenuItem(title: p.headline, action: nil, keyEquivalent: "")
        head.image = VM.makeStatusImage(symbol: p.symbol, color: p.color)
        head.isEnabled = false
        menu.addItem(head)

        menu.addItem(info("当前账号：\(vm.current == "?" ? "未初始化" : vm.current)"))
        menu.addItem(info("通过 \(c.ok) · 告警 \(c.warn) · 失败 \(c.fail)"))
        menu.addItem(info(vm.lastCheckAt.map { "上次检查：\(hhmmss($0))" } ?? "上次检查：尚未检查"))
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "重新检查", action: #selector(actRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !vm.running
        menu.addItem(refresh)

        let open = NSMenuItem(title: "打开主窗口", action: #selector(actOpen), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let canSwitch = (vm.phase == .ready || vm.phase == .done) && !vm.running
        for t in ["A", "B"] {
            let mi = NSMenuItem(title: "切换到账号 \(t)", action: #selector(actSwitch(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t
            mi.state = vm.current == t ? .on : .off
            mi.isEnabled = canSwitch
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let autoInfo = info("每 60 秒自动检查")
        autoInfo.state = .on
        menu.addItem(autoInfo)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Claude 切换器", action: #selector(actQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        VM.log("menu build items=\(menu.items.count)")
    }

    private func info(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func actRefresh() { VM.shared.refresh(animated: true) }

    @objc private func actOpen() {
        WindowBridge.show()
        if VM.shared.phase == .done { VM.shared.refresh(animated: true) }
    }

    @objc private func actSwitch(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        VM.shared.switchTo(t)
    }

    @objc private func actQuit() { NSApplication.shared.terminate(nil) }

    // MARK: 生命周期

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 菜单栏常驻：关窗不退出；防重复实例由启动时的单实例检查负责
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowBridge.show()
        return true
    }
}

// MARK: - App

struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(vm: VM.shared)
                .background(WindowAccessor { win in
                    guard let w = win else { return }
                    w.title = "Claude 切换器"
                    w.titlebarAppearsTransparent = true
                    w.titleVisibility = .hidden
                    w.styleMask.insert(.fullSizeContentView)
                    w.isMovableByWindowBackground = true
                    w.isReleasedWhenClosed = false
                    w.standardWindowButton(.zoomButton)?.isEnabled = false
                    WindowBridge.window = w
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let cb: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { self.cb(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 无头自检（不启动 GUI、不碰 Claude）

func runSelfTest() -> Bool {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("SELFTEST ok: \(name)") }
        else { failures += 1; print("SELFTEST FAIL: \(name)") }
    }

    let fixture = """
    # 2026-10-24 05:00:00 pid=1 开始
    代理内核=ok:Shadowrocket 已连接
    TUN网卡=ok
    出口IP=ok:203.0.113.9/US
    IP一致=ok
    时区=ok
    地区=ok
    IPv6=ok:已关闭
    DNS=ok:走隧道
    WebRTC=ok:UDP不出网,零暴露
    保镖=ok:待命
    规则置顶=ok:行为检测通过
    客户端语言=ok:跟随系统(英文)
    ASN属性=warn:疑似机房(AS12345 Example)
    生态可达性=ok:claude.ai:403 api:401
    # 结束
    """

    let parsed = VM.parseCheckOutput(fixture)
    check(parsed.count == 14, "14 行全部解析")
    check(parsed.first?.row == 0, "行序从 0 开始")
    check(parsed[2].state == .ok, "出口IP=ok")
    check(parsed[12].state == .warn && parsed[12].row == 12, "ASN 行为 warn")
    let s = VM.summary(of: parsed)
    check(s.ok == 13 && s.warn == 1 && s.fail == 0, "汇总 13 ok / 1 warn / 0 fail")

    let partial = VM.parseCheckOutput("代理内核=ok\nTUN网卡=fail:不在线")
    check(partial.count == 2, "部分输出解析")
    check(partial.last?.state == .fail, "fail 状态解析")

    let messy = VM.parseCheckOutput("垃圾行\n=foo\n代理内核=fail:异常:嵌套")
    check(messy.count == 1, "垃圾行忽略")
    check(messy.first?.detail == "异常:嵌套", "嵌套冒号保留")

    let invalidUTF8 = String(decoding: Data([0xff, 0xfe, 0x00, 0x41]), as: UTF8.self) + "\n代理内核=ok"
    check(VM.parseCheckOutput(invalidUTF8).count == 1, "非法 UTF-8 容错")

    let longOut = VM.parseCheckOutput("代理内核=fail:" + String(repeating: "x", count: 500))
    check(longOut.count == 1, "超长 detail 不影响解析")

    // 图标映射（菜单栏彩色盾牌）
    let icons = [
        ("checkmark.shield.fill", NSColor.systemGreen),
        ("exclamationmark.shield.fill", NSColor.systemYellow),
        ("xmark.shield.fill", NSColor.systemRed),
        ("shield.lefthalf.filled", NSColor.secondaryLabelColor),
    ]
    for (symbol, color) in icons {
        check(VM.makeStatusImage(symbol: symbol, color: color) != nil, "图标可生成 \(symbol)")
    }
    if let gi = VM.makeStatusImage(symbol: "checkmark.shield.fill", color: .systemGreen),
       let d = VM.dominantColor(gi) {
        check(d.g > d.r && d.g > d.b, "绿色盾牌像素偏绿 (r=\(d.r) g=\(d.g) b=\(d.b))")
    } else { check(false, "绿色盾牌像素可读取") }
    if let ri = VM.makeStatusImage(symbol: "xmark.shield.fill", color: .systemRed),
       let d = VM.dominantColor(ri) {
        check(d.r > d.g && d.r > d.b, "红色盾牌像素偏红 (r=\(d.r) g=\(d.g) b=\(d.b))")
    } else { check(false, "红色盾牌像素可读取") }

    print(failures == 0 ? "SELFTEST: PASS" : "SELFTEST: FAIL \(failures)")
    return failures == 0
}

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(runSelfTest() ? 0 : 1)
        }
        SwitcherApp.main()
    }
}
