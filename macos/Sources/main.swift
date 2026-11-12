// LoadWatch: 메뉴바에 상주하며 이 맥의 부하를 원인별(빌드·시뮬·세션 등)로 묶어 보여 준다.
// `LoadWatch status` / `LoadWatch json` 은 앱이 남긴 상태 파일을 읽어 출력만 하고 끝난다.
import Cocoa
import Darwin
import UserNotifications

let sampleInterval: TimeInterval = 5
let historyLen = 120  // 5초 × 120 = 10분
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LoadWatch")
let stateURL = supportDir.appendingPathComponent("state.json")
let eventsLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/LoadWatch/events.log")

// MARK: - 그룹

enum GroupID: String, CaseIterable, Codable {
    case session, claudeApp, xcode, sim, android, node, go, docker, runner, spotlight, browser, window, other, unattributed

    var label: String {
        switch self {
        case .session: return "Claude 세션"
        case .claudeApp: return "Claude 앱"
        case .xcode: return "Xcode·iOS 빌드"
        case .sim: return "iOS 시뮬레이터"
        case .android: return "Android·Gradle"
        case .node: return "Node·Metro"
        case .go: return "Go 빌드"
        case .docker: return "Docker·VM"
        case .runner: return "CI 러너"
        case .spotlight: return "Spotlight 색인"
        case .browser: return "브라우저"
        case .window: return "화면(WindowServer)"
        case .other: return "기타"
        case .unattributed: return "시스템·미집계"
        }
    }

    var short: String {
        switch self {
        case .session: return "세션"
        case .claudeApp: return "Claude앱"
        case .xcode: return "iOS빌드"
        case .sim: return "시뮬"
        case .android: return "안드"
        case .node: return "Node"
        case .go: return "Go"
        case .docker: return "Docker"
        case .runner: return "CI"
        case .spotlight: return "색인"
        case .browser: return "브라우저"
        case .window: return "화면"
        case .other: return "기타"
        case .unattributed: return "시스템"
        }
    }

    // 상태색(초록·주황·빨강)은 등급 전용이라 쓰지 않는다. 지금 하는 작업 5종만 색을 주고
    // 늘 깔려 있는 것은 회색 3단으로 눌러 둔다. 5색은 dataviz 검증기(색각·대비)를 통과한 조합.
    var color: NSColor {
        switch self {
        case .xcode: return dynamicColor(0x2a78d6, 0x3987e5)
        case .android: return dynamicColor(0xe87ba4, 0xd55181)
        case .runner: return dynamicColor(0xeda100, 0xc98500)
        case .sim: return dynamicColor(0x1baf7a, 0x199e70)
        case .session: return dynamicColor(0x6250d6, 0x9085e9)
        case .node, .go, .docker: return dynamicColor(0x7f8792, 0x8a919b)
        case .claudeApp, .spotlight, .browser, .window: return dynamicColor(0xb4b9c0, 0x5c6168)
        case .other, .unattributed: return dynamicColor(0xd7dade, 0x44474c)
        }
    }

    // 시작·끝 이벤트를 남기는 그룹. 세션·앱·화면처럼 늘 떠 있는 것은 뺀다.
    var tracksActivity: Bool {
        switch self {
        case .xcode, .sim, .android, .node, .go, .docker, .runner, .spotlight: return true
        default: return false
        }
    }
}

let xcodeNames: Set<String> = [
    "xcodebuild", "XCBBuildService", "SWBBuildService", "swift-frontend", "swift-driver", "swift-build",
    "swiftc", "swift", "clang", "clang++", "ld", "ld64", "ibtool", "ibtoold", "actool", "AssetCatalogAgent",
    "SourceKitService", "sourcekit-lsp", "swift-plugin-server", "dsymutil", "lipo", "pod",
]
let androidNames: Set<String> = ["java", "gradle", "aapt2", "kotlin-daemon", "adb"]
let nodeNames: Set<String> = ["node", "bun", "deno", "watchman", "esbuild", "pnpm", "npm", "yarn", "hermesc", "turbo"]
let goNames: Set<String> = ["go", "compile", "link", "asm", "cgo", "vet", "gopls", "golangci-lint"]
let spotlightNames: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd"]

func dynamicColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func make(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light) }
}

func ruleGroup(_ path: String) -> GroupID? {
    let name = (path as NSString).lastPathComponent
    if path.contains("/claude-code/") || name == "codex" { return .session }
    if path.hasSuffix("/Claude.app/Contents/Helpers/disclaimer") { return .session }
    if path.contains("/Claude.app/") { return .claudeApp }
    if path.contains("actions-runner") || name.hasPrefix("Runner.") { return .runner }
    if path.contains("/CoreSimulator/") || path.contains("/Simulator.app/") || name == "launchd_sim"
        || name == "simctl" || name.hasPrefix("com.apple.CoreSimulator") { return .sim }
    if xcodeNames.contains(name) || (path.contains("/Xcode") && path.contains(".app/")) { return .xcode }
    if name.hasPrefix("qemu-system") || path.contains("/Android/sdk/") || path.contains("JavaVirtualMachines")
        || androidNames.contains(name) { return .android }
    if nodeNames.contains(name) { return .node }
    if goNames.contains(name) || path.contains("/go-build") { return .go }
    if path.contains("Docker.app") || name.hasPrefix("com.docker") || name.contains("Virtualization.VirtualMachine") {
        return .docker
    }
    if spotlightNames.contains(name) { return .spotlight }
    if path.contains("Google Chrome") || path.contains("/Safari.app/") || path.contains("/Arc.app/")
        || path.contains("/Firefox.app/") || path.contains("Microsoft Edge") || name == "com.apple.WebKit.WebContent" {
        return .browser
    }
    if name == "WindowServer" { return .window }
    return nil
}

// MARK: - 측정

enum ProcKind { case plain, claudeSession, simulator, emulator }

struct ProcRow {
    let pid: Int32
    let ppid: Int32
    let mine: Bool
    let path: String
    let rule: GroupID?
    let kind: ProcKind
}

func procKind(_ path: String) -> ProcKind {
    let name = (path as NSString).lastPathComponent
    if path.contains("/claude-code/") && name == "claude" { return .claudeSession }
    if name == "launchd_sim" { return .simulator }
    if name.hasPrefix("qemu-system") { return .emulator }
    return .plain
}

let myUID = getuid()

// 프로세스 목록은 프로세스를 띄우지 않고 libproc 로 읽는다(ps 한 번이 CPU 30~70ms 라 매번 쓰기엔 비싸다).
// 경로·규칙 판정은 (pid, 시작 시각)마다 한 번만 한다.
final class ProcTable {
    private var cache: [Int32: (start: UInt64, path: String, rule: GroupID?, kind: ProcKind)] = [:]
    private var pids = [Int32](repeating: 0, count: 4096)

    func list() -> [ProcRow] {
        var n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        if Int(n) >= pids.count {
            pids = [Int32](repeating: 0, count: Int(n) * 2)
            n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        }
        var rows: [ProcRow] = []
        rows.reserveCapacity(Int(n))
        var alive = Set<Int32>()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            // 전체 정보는 내 프로세스만 열린다. 남의 계정(root 등)은 짧은 정보(부모·uid)만 읽고
            // 시작 시각 대신 이름 해시로 pid 재사용을 가린다.
            var ppid: Int32, uid: uid_t, start: UInt64
            var comm: String
            var bi = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size {
                ppid = Int32(bi.pbi_ppid); uid = bi.pbi_uid
                start = UInt64(bi.pbi_start_tvsec) &* 1_000_000 &+ UInt64(bi.pbi_start_tvusec)
                comm = withUnsafeBytes(of: bi.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            } else {
                var sb = proc_bsdshortinfo()
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sb, shortSize) == shortSize else { continue }
                ppid = Int32(sb.pbsi_ppid); uid = sb.pbsi_uid
                comm = withUnsafeBytes(of: sb.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                start = UInt64(bitPattern: Int64(comm.hashValue))
            }
            var entry = cache[pid]
            if entry?.start != start {
                var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                var path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
                if path.isEmpty { path = comm }
                entry = (start, path, ruleGroup(path), procKind(path))
                cache[pid] = entry
            }
            alive.insert(pid)
            rows.append(ProcRow(pid: pid, ppid: ppid, mine: uid == myUID, path: entry!.path, rule: entry!.rule,
                                kind: entry!.kind))
        }
        if cache.count > alive.count + 256 { cache = cache.filter { alive.contains($0.key) } }
        return rows
    }
}

func parseCPUTime(_ s: Substring) -> Double {
    var days = 0.0
    var rest = s
    if let dash = s.firstIndex(of: "-") {
        days = Double(s[..<dash]) ?? 0
        rest = s[s.index(after: dash)...]
    }
    var total = 0.0
    for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
    return days * 86400 + total
}

// 남의 계정(root·_windowserver 등) 프로세스 CPU 는 내 권한으로 못 읽는다. setuid 인 ps 로만 보이므로
// 원인 모를 부하가 클 때만 드물게 돌린다. 반환: pid → 누적 CPU 초
func otherUsersCPU() -> [Int32: Double] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-A", "-o", "pid=,uid=,cputime="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    var out: [Int32: Double] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]), let uid = UInt32(parts[1]), uid != myUID else { continue }
        out[pid] = parseCPUTime(parts[2])
    }
    return out
}

let machToSeconds: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1e9
}()

// 내 프로세스는 proc_pid_rusage 로 「자기 + 거둔 자식」 시간까지 읽는다.
// 빌드가 띄웠다 바로 끝나는 clang·swift-frontend 같은 짧은 프로세스는 ps 표본에 안 잡히지만
// 부모가 거두는 순간 부모의 자식 시간에 들어오므로 이 값으로 잡힌다.
func processUsage(_ pid: Int32) -> (own: Double, child: Double, footprint: UInt64)? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard r == 0 else { return nil }
    return (Double(ri.ri_user_time &+ ri.ri_system_time) * machToSeconds,
            Double(ri.ri_child_user_time &+ ri.ri_child_system_time) * machToSeconds,
            ri.ri_phys_footprint)
}

func inclusiveUsage(_ pid: Int32) -> (seconds: Double, footprint: UInt64)? {
    processUsage(pid).map { ($0.own + $0.child, $0.footprint) }
}

final class CPUTicks {
    private var prev: [UInt32] = []

    // 전체 코어 기준 사용률(0~100)
    func sample() -> Double? {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let now = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { prev = now }
        guard prev.count == now.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(numCPU) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(now[base + Int(CPU_STATE_USER)] &- prev[base + Int(CPU_STATE_USER)])
            let sys = UInt64(now[base + Int(CPU_STATE_SYSTEM)] &- prev[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(now[base + Int(CPU_STATE_NICE)] &- prev[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(now[base + Int(CPU_STATE_IDLE)] &- prev[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return total == 0 ? nil : Double(busy) / Double(total) * 100
    }
}

struct MemorySample {
    var usedBytes: Double
    var totalBytes: Double
    var swapUsedBytes: Double
    var pressure: Int32  // 1 정상, 2 경고, 4 위험
}

func sampleMemory() -> MemorySample {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    let page = Double(vm_kernel_page_size)
    // 활성 상태 보기의 「사용된 메모리」= 앱 메모리 + 와이어드 + 압축
    let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

    return MemorySample(usedBytes: used, totalBytes: Double(ProcessInfo.processInfo.physicalMemory),
                        swapUsedBytes: Double(swap.xsu_used), pressure: level)
}

// MARK: - 상태

enum Level: Int, Codable, Comparable {
    case green = 0, yellow = 1, red = 2
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var name: String { ["여유", "빠듯", "과부하"][rawValue] }
    var emoji: String { ["🟢", "🟡", "🔴"][rawValue] }
    var advice: String { ["새 세션 가능", "새 세션 보류", "새 세션 금지"][rawValue] }
    var headline: String { "\(name) · \(advice)" }
    var color: NSColor { [NSColor.systemGreen, NSColor.systemOrange, NSColor.systemRed][rawValue] }
}

struct GroupStat: Codable {
    let id: GroupID
    let label: String
    let cpu: Double     // 전체 대비 %, 최근 약 10초
    let memoryGB: Double
    let processes: Int
}

struct LoadEvent: Codable {
    enum Kind: String, Codable { case level, work, count }
    let at: Date
    let kind: Kind
    let text: String
}

struct Snapshot: Codable {
    var updatedAt = Date()
    var level = Level.green
    var levelName = ""
    var advice = ""
    var reason = ""
    var cpuNow = 0.0
    var cpu30s = 0.0
    var trend = ""
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var memUsedGB = 0.0
    var memTotalGB = 0.0
    var swapUsedGB = 0.0
    var memoryPressure = "정상"
    var thermal = "정상"
    var claudeSessions = 0
    var sessionAvgMemoryGB = 0.0
    var bootedSimulators = 0
    var androidEmulators = 0
    var groups: [GroupStat] = []
    var activeGroups: [GroupID] = []
    var events: [LoadEvent] = []
}

final class Activity {
    var active = false
    var startedAt = Date()
    var peak = 0.0
    var quietSince: Date?
}

// 화면이 읽는 값 묶음. 측정은 백그라운드 큐에서 하고, 이 복사본만 메인 스레드로 넘긴다.
struct MonitorView {
    var snapshot = Snapshot()
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var groupHistory: [[GroupID: Double]] = []
    var groupNow: [GroupID: Double] = [:]
    var selfCPU = 0.0
}

final class Monitor {
    private let ticks = CPUTicks()
    private let table = ProcTable()
    private var prev: [Int32: Usage] = [:]  // 내 계정 프로세스만
    private struct Usage {
        let own: Double
        let child: Double
        let path: String
        let ppid: Int32
        let group: GroupID
    }
    private var otherPrev: [Int32: Double] = [:]
    private var otherPrevAt: Date?
    private var otherPct: [GroupID: Double] = [:]
    private var otherFetching = false
    private var otherResult: (at: Date, cpu: [Int32: Double])?  // 백그라운드 ps 결과, 다음 표본에서 반영
    private var rawUnattributedEMA = 0.0
    private var selfPrev: Double?
    private var lastSampleAt: Date?
    private var groupEMA: [GroupID: Double] = [:]
    private var activities: [GroupID: Activity] = [:]
    private var cpuFast = 0.0, cpuSlow = 0.0, cpuMinute = 0.0
    private var primed = false
    private var lastLevelChangeNotify = Date.distantPast
    private var prevSessions = -1, prevSims = -1, prevEmus = -1

    var snapshot = Snapshot()
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var groupHistory: [[GroupID: Double]] = []  // 표본마다 그룹별 CPU(전체 대비 %)
    var groupNow: [GroupID: Double] { groupEMA }
    var selfCPU = 0.0  // 이 앱 자신(ps 자식 포함), 코어 1개 기준 %
    var onEvent: ((LoadEvent, _ notify: Bool) -> Void)?
    var view: MonitorView {
        MonitorView(snapshot: snapshot, cpuHistory: cpuHistory, memHistory: memHistory,
                    groupHistory: groupHistory, groupNow: groupNow, selfCPU: selfCPU)
    }

    func tick() {
        let now = Date()
        let rows = table.list()
        let cpuTotal = ticks.sample()
        let mem = sampleMemory()
        let dt = lastSampleAt.map { now.timeIntervalSince($0) } ?? sampleInterval
        lastSampleAt = now
        func ema(_ old: Double, _ new: Double, tau: Double) -> Double {
            old + (new - old) * (1 - exp(-dt / tau))
        }

        // 그룹 판정: 이름 규칙 → 없으면 가장 가까운 조상의 그룹. CI 러너 밑은 무엇이든 CI.
        var byPid: [Int32: ProcRow] = [:]
        for r in rows { byPid[r.pid] = r }
        var memo: [Int32: GroupID] = [:]
        func group(of pid: Int32) -> GroupID {
            if let g = memo[pid] { return g }
            var chain: [Int32] = []
            var cur = pid
            var found: GroupID = .other
            var underRunner = false
            var depth = 0
            while let row = byPid[cur], cur > 1, depth < 64 {
                if let g = memo[cur] { found = g; if g == .runner { underRunner = true }; break }
                chain.append(cur)
                if row.rule == .runner { underRunner = true }
                cur = row.ppid
                depth += 1
            }
            // 위에서부터 내려오며 규칙이 있으면 바꾸고, 없으면 위쪽 그룹을 물려받는다.
            var inherited = found
            for p in chain.reversed() {
                if let g = byPid[p]!.rule { inherited = g }
                memo[p] = inherited
            }
            if underRunner { memo[pid] = .runner }
            return memo[pid] ?? .other
        }

        var cpuSec: [GroupID: Double] = [:]
        var memBytes: [GroupID: UInt64] = [:]
        var procCount: [GroupID: Int] = [:]
        var next: [Int32: Usage] = [:]
        var reaped: [Int32: Double] = [:]  // 이번 구간에 거둔 자식들의 누적 시간
        var sessions = 0, sims = 0, emus = 0
        var sessionMem: UInt64 = 0

        for r in rows {
            let g = group(of: r.pid)
            procCount[g, default: 0] += 1
            switch r.kind {
            case .claudeSession: sessions += 1
            case .simulator: sims += 1
            case .emulator: emus += 1
            case .plain: break
            }

            guard r.mine, let u = processUsage(r.pid) else { continue }
            if primed {
                if let p = prev[r.pid], p.path == r.path {
                    cpuSec[g, default: 0] += max(0, u.own - p.own)
                    reaped[r.pid] = max(0, u.child - p.child)
                } else {
                    cpuSec[g, default: 0] += u.own + u.child  // 이번 구간에 태어난 프로세스
                }
            }
            memBytes[g, default: 0] += u.footprint
            if g == .session { sessionMem += u.footprint }
            next[r.pid] = Usage(own: u.own, child: u.child, path: r.path, ppid: r.ppid, group: g)
        }
        // 끝난 프로세스의 시간은 살아 있는 조상이 거둘 때 그 조상의 자식 시간으로 통째로 넘어온다.
        // 지난 표본까지 이미 센 몫은 빼고, 남은 몫은 끝난 쪽 그룹으로 돌려준다
        // (세션이 돌린 swiftc 가 끝나면 마지막 몫도 세션이 아니라 빌드로).
        if primed {
            var credit: [Int32: Double] = [:]
            var reapedGroups: [Int32: [GroupID: Double]] = [:]
            for (pid, p) in prev where next[pid]?.path != p.path {
                var anc = p.ppid
                var hops = 0
                while next[anc] == nil, let up = prev[anc], hops < 16 { anc = up.ppid; hops += 1 }
                guard anc > 1, next[anc] != nil else { continue }
                credit[anc, default: 0] += p.own + p.child
                reapedGroups[anc, default: [:]][p.group, default: 0] += p.own + p.child + 0.001
            }
            for (pid, d) in reaped where d > 0 {
                let rest = d - (credit[pid] ?? 0)
                guard rest > 0, let me = next[pid] else { continue }
                let target = reapedGroups[pid]?.max { $0.value < $1.value }?.key ?? me.group
                cpuSec[target, default: 0] += rest
            }
        }
        prev = next

        if let me = inclusiveUsage(getpid()) {
            if let before = selfPrev { selfCPU = ema(selfCPU, max(0, me.seconds - before) / dt * 100, tau: 30) }
            selfPrev = me.seconds
        }

        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var groupPct: [GroupID: Double] = [:]
        if primed {
            for (g, s) in cpuSec { groupPct[g] = max(0, s) / dt / cores * 100 }
            if let total = cpuTotal {
                rawUnattributedEMA = ema(rawUnattributedEMA, max(0, total - groupPct.values.reduce(0, +)), tau: 15)
            }
            // 원인 모를 몫이 클 때만 60초마다 ps 로 남의 계정 프로세스(Spotlight·WindowServer 등) 몫을 나눈다.
            // ps 는 0.1초 남짓 걸려서 메인 스레드를 막지 않게 백그라운드에서 돌리고 결과는 다음 표본에서 쓴다.
            if let result = otherResult {
                otherResult = nil
                if let at = otherPrevAt, result.at.timeIntervalSince(at) < 180 {
                    let span = result.at.timeIntervalSince(at)
                    var pct: [GroupID: Double] = [:]
                    for (pid, t) in result.cpu {
                        guard let p = otherPrev[pid] else { continue }
                        pct[group(of: pid), default: 0] += max(0, t - p) / span / cores * 100
                    }
                    otherPct = pct
                }
                otherPrev = result.cpu
                otherPrevAt = result.at
            }
            if rawUnattributedEMA >= 8 {
                if !otherFetching && now.timeIntervalSince(otherPrevAt ?? .distantPast) >= 60 {
                    otherFetching = true
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let cpu = otherUsersCPU()
                        let at = Date()
                        DispatchQueue.main.async {
                            self?.otherResult = (at, cpu)
                            self?.otherFetching = false
                        }
                    }
                }
            } else if !otherPct.isEmpty {
                otherPct = [:]
                otherPrev = [:]
                otherPrevAt = nil
            }
            for (g, v) in otherPct { groupPct[g, default: 0] += v }
            if let total = cpuTotal {
                groupPct[.unattributed] = max(0, total - groupPct.values.reduce(0, +))
            }
        }

        if let total = cpuTotal {
            if !primed || cpuHistory.isEmpty {
                cpuFast = total; cpuSlow = total; cpuMinute = total
            } else {
                cpuFast = ema(cpuFast, total, tau: 9)
                cpuSlow = ema(cpuSlow, total, tau: 30)
                cpuMinute = ema(cpuMinute, total, tau: 90)
            }
            cpuHistory.append(total)
            if cpuHistory.count > historyLen { cpuHistory.removeFirst() }
        }
        memHistory.append(mem.usedBytes / mem.totalBytes * 100)
        if memHistory.count > historyLen { memHistory.removeFirst() }

        if primed {
            for g in GroupID.allCases {
                groupEMA[g] = ema(groupEMA[g] ?? (groupPct[g] ?? 0), groupPct[g] ?? 0, tau: 10)
            }
            groupHistory.append(groupPct)
            if groupHistory.count > historyLen { groupHistory.removeFirst() }
            trackActivity(now: now)
            trackCounts(sessions: sessions, sims: sims, emus: emus, now: now)
        }
        primed = true

        // 판정
        let oldLevel = snapshot.level
        var level = Level.green
        var reasons: [String] = []
        let redAt = oldLevel == .red ? 75.0 : 80.0
        let yellowAt = oldLevel >= .yellow ? 50.0 : 55.0
        if cpuSlow >= redAt { level = .red; reasons.append("CPU 30초 평균 \(Int(cpuSlow))%") }
        else if cpuSlow >= yellowAt { level = .yellow; reasons.append("CPU 30초 평균 \(Int(cpuSlow))%") }
        if mem.pressure >= 4 { level = .red; reasons.append("메모리 압박 위험") }
        else if mem.pressure >= 2 { level = max(level, .yellow); reasons.append("메모리 압박 경고") }
        if mem.usedBytes / mem.totalBytes >= 0.92 { level = max(level, .yellow); reasons.append("메모리 92% 이상 사용") }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical { level = .red; reasons.append("발열 위험") }
        else if thermal == .serious { level = max(level, .yellow); reasons.append("발열 높음") }

        let stats = GroupID.allCases.map { g in
            GroupStat(id: g, label: g.label, cpu: groupEMA[g] ?? 0,
                      memoryGB: Double(memBytes[g] ?? 0) / 1_073_741_824, processes: procCount[g] ?? 0)
        }.filter { $0.cpu >= 0.5 || $0.memoryGB >= 0.5 }.sorted { $0.cpu > $1.cpu }
        let top = stats.first.flatMap { $0.cpu >= 3 ? $0 : nil }
        if let top { reasons.append("주원인 \(top.label) \(Int(top.cpu.rounded()))%") }

        let freeGB = (mem.totalBytes - mem.usedBytes) / 1_073_741_824
        let perSession = sessions > 0 ? Double(sessionMem) / Double(sessions) / 1_073_741_824 : 0
        if level == .green {
            var room = "CPU 여유 \(max(0, Int(100 - cpuSlow)))% · 메모리 여유 \(String(format: "%.1f", freeGB))GB"
            if perSession > 0.05 { room += "(세션 약 \(Int(freeGB / perSession))개분)" }
            reasons.insert(room, at: 0)
        }

        snapshot.updatedAt = now
        snapshot.level = level
        snapshot.levelName = level.name
        snapshot.advice = level.advice
        snapshot.reason = reasons.joined(separator: " · ")
        snapshot.cpuNow = cpuFast
        snapshot.cpu30s = cpuSlow
        snapshot.trend = cpuFast - cpuMinute > 10 ? "올라가는 중" : (cpuMinute - cpuFast > 10 ? "내려가는 중" : "")
        snapshot.memUsedGB = mem.usedBytes / 1_073_741_824
        snapshot.memTotalGB = mem.totalBytes / 1_073_741_824
        snapshot.swapUsedGB = mem.swapUsedBytes / 1_073_741_824
        snapshot.memoryPressure = mem.pressure >= 4 ? "위험" : (mem.pressure >= 2 ? "경고" : "정상")
        snapshot.thermal = [.nominal: "정상", .fair: "약간 높음", .serious: "높음", .critical: "위험"][thermal] ?? "?"
        snapshot.claudeSessions = sessions
        snapshot.sessionAvgMemoryGB = perSession
        snapshot.bootedSimulators = sims
        snapshot.androidEmulators = emus
        snapshot.groups = stats
        snapshot.activeGroups = GroupID.allCases.filter { activities[$0]?.active == true }

        if level != oldLevel && cpuHistory.count > 3 {
            let escalated = level > oldLevel
            let text = "\(oldLevel.name) → \(level.headline)"
                + (top.map { " · 주원인 \($0.label) \(Int($0.cpu.rounded()))%" } ?? "")
            // 내려올 때 알림은 1분에 한 번까지(경계에서 깜빡이는 것 막기)
            let notify = escalated || now.timeIntervalSince(lastLevelChangeNotify) > 60
            if notify { lastLevelChangeNotify = now }
            emit(.level, text, notify: notify, now: now)
        }
        writeState()
    }

    private func trackActivity(now: Date) {
        for g in GroupID.allCases where g.tracksActivity {
            let v = groupEMA[g] ?? 0
            let a = activities[g] ?? Activity()
            activities[g] = a
            if !a.active {
                if v >= 15 {
                    a.active = true; a.startedAt = now; a.peak = v; a.quietSince = nil
                    emit(.work, "\(g.label) 시작 · \(Int(v.rounded()))%", notify: true, now: now)
                }
            } else {
                a.peak = max(a.peak, v)
                if v < 5 {
                    let quiet = a.quietSince ?? now
                    a.quietSince = quiet
                    if now.timeIntervalSince(quiet) >= 20 {
                        a.active = false
                        let dur = quiet.timeIntervalSince(a.startedAt)
                        emit(.work, "\(g.label) 끝 · \(formatDuration(dur)) · 최대 \(Int(a.peak.rounded()))%",
                             notify: dur >= 30, now: now)
                    }
                } else {
                    a.quietSince = nil
                }
            }
        }
    }

    private func trackCounts(sessions: Int, sims: Int, emus: Int, now: Date) {
        if prevSessions >= 0 && sessions != prevSessions {
            emit(.count, "Claude 세션 \(prevSessions)→\(sessions)개", notify: false, now: now)
        }
        if prevSims >= 0 && sims != prevSims {
            emit(.count, "시뮬레이터 \(prevSims)→\(sims)대", notify: false, now: now)
        }
        if prevEmus >= 0 && emus != prevEmus {
            emit(.count, "에뮬레이터 \(prevEmus)→\(emus)대", notify: false, now: now)
        }
        prevSessions = sessions; prevSims = sims; prevEmus = emus
    }

    private func emit(_ kind: LoadEvent.Kind, _ text: String, notify: Bool, now: Date) {
        let e = LoadEvent(at: now, kind: kind, text: text)
        snapshot.events.insert(e, at: 0)
        if snapshot.events.count > 40 { snapshot.events.removeLast() }
        appendEventLog(e)
        onEvent?(e, notify)
    }

    private func appendEventLog(_ e: LoadEvent) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let line = "\(f.string(from: e.at)) cpu=\(Int(cpuFast)) \(e.text)\n"
        let dir = eventsLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: eventsLogURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: eventsLogURL)
        }
    }

    private func writeState() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}

func formatDuration(_ s: TimeInterval) -> String {
    let m = Int(s) / 60, sec = Int(s) % 60
    if m >= 60 { return "\(m / 60)시간 \(m % 60)분" }
    return m > 0 ? "\(m)분 \(sec)초" : "\(sec)초"
}

// MARK: - 메뉴바

// 아래부터 쌓는 순서: 자주 오르내리는 작업을 바닥에, 늘 깔려 있는 것을 위에.
let stackOrder: [GroupID] = [.xcode, .android, .runner, .sim, .session, .node, .go, .docker, .claudeApp,
                             .spotlight, .browser, .window, .other, .unattributed]

func drawStack(_ hist: [[GroupID: Double]], slots: Int, in plot: NSRect) {
    guard hist.count > 1 else { return }
    let step = plot.width / CGFloat(slots - 1)
    let x0 = plot.maxX - CGFloat(hist.count - 1) * step
    func y(_ v: Double) -> CGFloat { plot.minY + plot.height * CGFloat(min(100, v) / 100) }
    var base = [Double](repeating: 0, count: hist.count)
    for g in stackOrder {
        let top = hist.indices.map { base[$0] + (hist[$0][g] ?? 0) }
        guard zip(top, base).contains(where: { $0 - $1 >= 0.05 }) else { continue }
        let p = NSBezierPath()
        for i in hist.indices {
            let pt = NSPoint(x: x0 + CGFloat(i) * step, y: y(top[i]))
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        for i in hist.indices.reversed() { p.line(to: NSPoint(x: x0 + CGFloat(i) * step, y: y(base[i]))) }
        p.close()
        g.color.setFill()
        p.fill()
        base = top
    }
}

final class ChartView: NSView {
    var groups: [[GroupID: Double]] = []
    var mem: [Double] = []

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 40, y: 18, width: bounds.width - 54, height: bounds.height - 26)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: plot).fill()
        drawStack(groups, slots: historyLen, in: plot)

        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (v, c) in [(55.0, NSColor.systemOrange), (80.0, NSColor.systemRed), (100.0, NSColor.tertiaryLabelColor)] {
            let y = plot.minY + plot.height * v / 100
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.setLineDash([3, 3], count: 2, phase: 0)
            c.setStroke()
            p.lineWidth = 0.7
            p.stroke()
            ("\(Int(v))%" as NSString).draw(at: NSPoint(x: 8, y: y - 6), withAttributes: small)
        }
        if mem.count > 1 {
            let step = plot.width / CGFloat(historyLen - 1)
            let x0 = plot.maxX - CGFloat(mem.count - 1) * step
            let p = NSBezierPath()
            for (i, v) in mem.enumerated() {
                let pt = NSPoint(x: x0 + CGFloat(i) * step, y: plot.minY + plot.height * CGFloat(min(100, v)) / 100)
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            p.lineWidth = 1.5
            p.stroke()
        }
        ("10분 전" as NSString).draw(at: NSPoint(x: plot.minX, y: 2), withAttributes: small)
        ("5분" as NSString).draw(at: NSPoint(x: plot.midX - 8, y: 2), withAttributes: small)
        ("지금" as NSString).draw(at: NSPoint(x: plot.maxX - 20, y: 2), withAttributes: small)
    }
}

// 그룹 한 줄: 색 · 이름 · 10분 추이 · 지금 CPU · 메모리
final class GroupRowView: NSView {
    var group: GroupID = .other
    var series: [Double] = []
    var cpu = 0.0
    var memoryGB = 0.0
    var active = false
    var header = false

    override func draw(_ dirtyRect: NSRect) {
        let font = header ? NSFont.boldSystemFont(ofSize: 12) : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        func right(_ s: String, _ x: CGFloat) {
            let str = s as NSString
            let w = str.size(withAttributes: attrs).width
            str.draw(at: NSPoint(x: x - w, y: 3), withAttributes: attrs)
        }
        let spark = NSRect(x: 190, y: 3, width: 120, height: bounds.height - 6)
        if header {
            ("원인" as NSString).draw(at: NSPoint(x: 14, y: 3), withAttributes: attrs)
            ("최근 10분" as NSString).draw(at: NSPoint(x: spark.minX, y: 3), withAttributes: attrs)
            right("CPU", 360)
            right("메모리", bounds.width - 14)
            return
        }
        group.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: (bounds.height - 8) / 2, width: 8, height: 8)).fill()
        let name = NSMutableAttributedString(string: group.label, attributes: attrs)
        if active {
            name.append(NSAttributedString(string: "  진행 중", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        name.draw(at: NSPoint(x: 32, y: 3))

        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: spark).fill()
        if series.count > 1 {
            let peak = max(10, series.max() ?? 0)  // 작은 값도 모양이 보이게 그룹마다 눈금을 맞춘다(최소 10%)
            let step = spark.width / CGFloat(historyLen - 1)
            let x0 = spark.maxX - CGFloat(series.count - 1) * step
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: spark.minY))
            for (i, v) in series.enumerated() {
                p.line(to: NSPoint(x: x0 + CGFloat(i) * step, y: spark.minY + spark.height * CGFloat(v / peak)))
            }
            p.line(to: NSPoint(x: spark.maxX, y: spark.minY))
            p.close()
            group.color.withAlphaComponent(0.8).setFill()
            p.fill()
            let peakAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            ("\(Int(peak.rounded()))" as NSString).draw(at: NSPoint(x: spark.maxX + 2, y: spark.maxY - 9), withAttributes: peakAttrs)
        }
        right("\(Int(cpu.rounded()))%", 360)
        if group != .unattributed && memoryGB >= 0.05 { right(String(format: "%.1fGB", memoryGB), bounds.width - 14) }
    }
}

// 드롭다운에 보일 그룹: 지금 쓰는 것 + 10분 안에 한 번이라도 1% 넘었던 것(끝난 빌드도 추이로 남게)
func shownGroups(_ v: MonitorView) -> [GroupID] {
    let memOf = Dictionary(uniqueKeysWithValues: v.snapshot.groups.map { ($0.id, $0.memoryGB) })
    return GroupID.allCases.filter { g in
        (v.groupNow[g] ?? 0) >= 0.5 || (memOf[g] ?? 0) >= 0.5 || v.groupHistory.contains { ($0[g] ?? 0) >= 1 }
    }.sorted { (v.groupNow[$0] ?? 0) > (v.groupNow[$1] ?? 0) }
}

func configure(_ row: GroupRowView, _ g: GroupID, _ v: MonitorView) {
    row.group = g
    row.series = v.groupHistory.map { $0[g] ?? 0 }
    row.cpu = v.groupNow[g] ?? 0
    row.memoryGB = v.snapshot.groups.first { $0.id == g }?.memoryGB ?? 0
    row.active = v.snapshot.activeGroups.contains(g)
    row.needsDisplay = true
}

func newRow() -> GroupRowView { GroupRowView(frame: NSRect(x: 0, y: 0, width: 420, height: 22)) }

// MARK: - 작업 슬롯(slot CLI 가 남긴 파일을 읽기만 한다)

let slotDir = supportDir.appendingPathComponent("slots")
let slotCLI = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/slot").path

struct SlotJob: Equatable {
    let cls: String
    let label: String
    let place: String
    let since: Double
}

struct SlotView: Equatable {
    var running: [SlotJob] = []
    var waiting: [SlotJob] = []
    var paused = false
    var isEmpty: Bool { running.isEmpty && waiting.isEmpty && !paused }

    static let caps = ["build": 2, "qa": 1, "check": 3]
    static let names = ["build": "빌드", "qa": "QA", "check": "검사"]

    // 쥔 프로세스가 죽은 기록도 남아 있을 수 있어 pid 가 살아 있는 것만 센다(정리는 slot CLI 몫).
    static func read() -> SlotView {
        var v = SlotView()
        let fm = FileManager.default
        v.paused = fm.fileExists(atPath: slotDir.appendingPathComponent("paused").path)
        func jobs(_ sub: String, pidKey: String) -> [SlotJob] {
            let dir = slotDir.appendingPathComponent(sub)
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            return names.compactMap { name in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = o[pidKey] as? Int, kill(pid_t(pid), 0) == 0 || errno == EPERM else { return nil }
                let cwd = (o["cwd"] as? String ?? "") as NSString
                return SlotJob(cls: o["cls"] as? String ?? "?", label: o["label"] as? String ?? "?",
                               place: cwd.lastPathComponent, since: o["since"] as? Double ?? 0)
            }
        }
        v.running = jobs("holders", pidKey: "holder")
        v.waiting = jobs("queue", pidKey: "pid")
        return v
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let monitor = Monitor()
    // 측정은 낮은 우선순위 큐에서(효율 코어 쪽), 메인 스레드는 메뉴바 그리기와 클릭만.
    let sampleQueue = DispatchQueue(label: "loadwatch.sample", qos: .utility)
    var sampleTimer: DispatchSourceTimer?
    var view = MonitorView()
    var slots = SlotView()
    var builtSlots = SlotView()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
    var menuOpen = false
    let defaults = UserDefaults.standard

    var notifyLevel: Bool {
        get { defaults.object(forKey: "notifyLevel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyLevel") }
    }
    var notifyGroups: Bool {
        get { defaults.object(forKey: "notifyGroups") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyGroups") }
    }
    var showBadges: Bool {
        get { defaults.object(forKey: "showBadges") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showBadges"); render() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // onEvent 는 측정 큐에서 불리므로 monitor 를 바로 읽어도 된다.
        monitor.onEvent = { [weak self] e, notify in
            guard let self, notify else { return }
            if e.kind == .level, self.notifyLevel {
                self.post(self.monitor.snapshot.level.headline, self.monitor.snapshot.reason)
            } else if e.kind == .work, self.notifyGroups {
                self.post(e.text, "")
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: sampleInterval, leeway: .seconds(1))  // 다른 깨움과 묶이게 여유
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.monitor.tick()
            let v = self.monitor.view
            let sl = SlotView.read()
            DispatchQueue.main.async {
                self.view = v
                self.slots = sl
                self.render()
            }
        }
        timer.resume()
        sampleTimer = timer
    }

    func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // 메뉴바는 시스템 아이콘처럼 흑백으로 두고, 색은 등급 하나에만 쓴다.
    // 여유일 땐 조용하다가 빠듯·과부하가 되면 그래프와 숫자에만 주황·빨강이 들어온다.
    func render() {
        let s = view.snapshot
        let alert = s.level != .green
        let ink = NSColor.labelColor
        let accent = alert ? s.level.color : ink
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        var cpuText = "\(Int(s.cpuNow.rounded()))%"
        if s.trend == "올라가는 중" { cpuText += "↑" } else if s.trend == "내려가는 중" { cpuText += "↓" }

        // (SF Symbol, 글자, 강조 여부)
        var badges: [(String, String, Bool)] = []
        if showBadges {
            let now = view.groupNow
            func pct(_ g: GroupID) -> Int { Int((now[g] ?? 0).rounded()) }
            func on(_ g: GroupID) -> Bool { s.activeGroups.contains(g) || (now[g] ?? 0) >= 5 }
            let work: [(GroupID, String, String)] = [
                (.xcode, "hammer.fill", "iOS"), (.runner, "gearshape.2", "CI"), (.go, "chevron.left.forwardslash.chevron.right", "Go"),
                (.node, "curlybraces", "Node"), (.docker, "shippingbox", "Docker"), (.spotlight, "magnifyingglass", "색인"),
            ]
            for (g, symbol, label) in work where on(g) { badges.append((symbol, "\(label) \(pct(g))%", false)) }
            if s.androidEmulators > 0 {
                badges.append(("smartphone", "\(s.androidEmulators)대" + (pct(.android) >= 3 ? " \(pct(.android))%" : ""), false))
            } else if on(.android) {
                badges.append(("hammer", "Gradle \(pct(.android))%", false))
            }
            if s.bootedSimulators > 0 {
                badges.append(("iphone", "\(s.bootedSimulators)대" + (pct(.sim) >= 3 ? " \(pct(.sim))%" : ""), false))
            }
            if s.memoryPressure != "정상" {
                badges.append(("memorychip", String(format: "%.0fGB", s.memUsedGB), true))
            }
            // 슬롯: 기다리는 작업이 있을 때만 강조한다(대기 = 부하 때문에 밀리는 중)
            if slots.paused {
                badges.append(("pause.circle.fill", "멈춤", true))
            } else if !slots.waiting.isEmpty {
                badges.append(("hourglass", "대기 \(slots.waiting.count)", true))
            }
            badges.append(("terminal", "\(s.claudeSessions)", false))
        }

        let graphW: CGFloat = 30, iconW: CGFloat = 14, height: CGFloat = 18
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func textW(_ t: String) -> CGFloat { ceil((t as NSString).size(withAttributes: attrs).width) }
        var width = graphW + 5 + textW(cpuText)
        for b in badges { width += 11 + iconW + 3 + textW(b.1) }

        let hist = Array(view.cpuHistory.suffix(36))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let plot = NSRect(x: 0, y: 2, width: graphW, height: height - 4)
            ink.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: plot, xRadius: 2.5, yRadius: 2.5).fill()
            if hist.count > 1 {
                let step = plot.width / 35
                let x0 = plot.maxX - CGFloat(hist.count - 1) * step
                let line = NSBezierPath()
                for (i, v) in hist.enumerated() {
                    let pt = NSPoint(x: x0 + CGFloat(i) * step, y: plot.minY + plot.height * CGFloat(min(100, v)) / 100)
                    i == 0 ? line.move(to: pt) : line.line(to: pt)
                }
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
                area.line(to: NSPoint(x: x0, y: plot.minY))
                area.close()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: plot, xRadius: 2.5, yRadius: 2.5).addClip()
                accent.withAlphaComponent(alert ? 0.5 : 0.35).setFill()
                area.fill()
                accent.withAlphaComponent(alert ? 1 : 0.85).setStroke()
                line.lineWidth = 1.2
                line.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            var x = graphW + 5
            func text(_ t: String, _ color: NSColor) {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (t as NSString).size(withAttributes: a)
                (t as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: a)
                x += ceil(size.width)
            }
            text(cpuText, accent)
            for (symbol, label, strong) in badges {
                x += 11
                let color = strong ? accent : ink.withAlphaComponent(0.85)
                if let img = self.symbolBitmap(symbol, color: color) {
                    let sz = img.size
                    let scale = min(1, iconW / max(sz.width, 1))
                    let w = sz.width * scale, h = sz.height * scale
                    img.draw(in: NSRect(x: x + (iconW - w) / 2, y: (height - h) / 2, width: w, height: h))
                }
                x += iconW + 3
                text(label, color)
            }
            return true
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "\(s.level.headline)\n\(s.reason)"
        statusItem.button?.setAccessibilityLabel("LoadWatch \(s.level.headline), CPU \(cpuText)")
        if menuOpen { refreshOpenMenu() }
    }

    // SF Symbol 은 그릴 때마다 벡터를 다시 풀어 CPU 를 먹는다(프로파일 대부분). 색·모양별로 한 번만 비트맵으로 굽는다.
    private var symbolCache: [String: NSImage] = [:]
    func symbolBitmap(_ name: String, color: NSColor) -> NSImage? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }  // 지금 화면 모드로 색을 확정
        let key = "\(name)|\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)"
        if let hit = symbolCache[key] { return hit }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [rgb]))
        guard let vector = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))?.withSymbolConfiguration(cfg),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(vector.size.width * 2)),
                                         pixelsHigh: Int(ceil(vector.size.height * 2)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = vector.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        vector.draw(in: NSRect(origin: .zero, size: vector.size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: vector.size)
        out.addRepresentation(rep)
        if symbolCache.count > 64 { symbolCache.removeAll() }
        symbolCache[key] = out
        return out
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; buildMenu() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func styled(_ text: String, bold: Bool = false, color: NSColor = .labelColor, size: CGFloat = 13) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func info(_ text: String, bold: Bool = false, color: NSColor = .labelColor, size: CGFloat = 13) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = styled(text, bold: bold, color: color, size: size)
        return item
    }

    // 메뉴가 열린 동안 바뀌는 줄들. 열려 있을 땐 이 줄들만 제자리에서 고친다.
    private var liveItems: [NSMenuItem] = []
    private var liveRows: [GroupRowView] = []
    private var builtGroups: [GroupID] = []
    private var builtEventTop: Date?

    private func liveTexts(_ s: Snapshot) -> [NSAttributedString] {
        let head = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: s.level.color,
        ])
        head.append(styled(s.level.headline, bold: true, size: 14))
        let trend = s.trend.isEmpty ? "" : " · \(s.trend)"
        return [
            head,
            styled(s.reason, color: .secondaryLabelColor, size: 12),
            styled("CPU \(Int(s.cpuNow.rounded()))% (30초 평균 \(Int(s.cpu30s.rounded()))%) · \(s.cores)코어\(trend)"),
            styled(String(format: "메모리 %.1f/%.0fGB · 압박 %@ · 스왑 %.1fGB · 발열 %@",
                          s.memUsedGB, s.memTotalGB, s.memoryPressure, s.swapUsedGB, s.thermal)),
            styled(String(format: "Claude 세션 %d개(평균 %.2fGB) · 시뮬레이터 %d대 · 에뮬레이터 %d대",
                          s.claudeSessions, s.sessionAvgMemoryGB, s.bootedSimulators, s.androidEmulators)),
            styled(String(format: "LoadWatch 자체 CPU %.2f%%(코어 1개 기준)", view.selfCPU),
                   color: .secondaryLabelColor, size: 11),
        ]
    }

    // 열린 메뉴 갱신: 보이는 그룹이나 최근 변화가 달라졌을 때만 다시 짓고, 나머지는 값만 바꾼다.
    func refreshOpenMenu() {
        let s = view.snapshot
        let groups = shownGroups(view)
        guard groups == builtGroups, s.events.first?.at == builtEventTop, liveItems.count == 6, slots == builtSlots else {
            buildMenu()
            return
        }
        for (item, text) in zip(liveItems, liveTexts(s)) { item.attributedTitle = text }
        chart.groups = view.groupHistory
        chart.mem = view.memHistory
        chart.needsDisplay = true
        for (row, g) in zip(liveRows, groups) { configure(row, g, view) }
    }

    func buildMenu() {
        let s = view.snapshot
        menu.removeAllItems()
        let texts = liveTexts(s)
        liveItems = texts.map { t in
            let item = NSMenuItem()
            item.attributedTitle = t
            return item
        }
        menu.addItem(liveItems[0])
        menu.addItem(liveItems[1])
        menu.addItem(.separator())

        chart.groups = view.groupHistory
        chart.mem = view.memHistory
        chart.needsDisplay = true
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(info("최근 10분 CPU를 원인별로 쌓은 그래프 · 실선은 메모리 · 점선은 55%·80% 경계", color: .secondaryLabelColor, size: 11))
        for item in liveItems[2...] { menu.addItem(item) }
        menu.addItem(.separator())

        let header = newRow()
        header.header = true
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        builtGroups = shownGroups(view)
        liveRows = builtGroups.map { g in
            let row = newRow()
            configure(row, g, view)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
            return row
        }
        menu.addItem(info("추이 오른쪽 숫자는 그 줄 눈금의 최댓값(%)", color: .secondaryLabelColor, size: 11))
        menu.addItem(.separator())

        addSlotSection()
        menu.addItem(.separator())

        menu.addItem(info("최근 변화", bold: true))
        builtEventTop = s.events.first?.at
        if s.events.isEmpty {
            menu.addItem(info("아직 없음", color: .secondaryLabelColor))
        } else {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            for e in s.events.prefix(12) { menu.addItem(info("\(f.string(from: e.at))  \(e.text)", size: 12)) }
        }
        menu.addItem(.separator())

        let lv = NSMenuItem(title: "등급 바뀌면 알림", action: #selector(toggleLevel), keyEquivalent: "")
        lv.target = self
        lv.state = notifyLevel ? .on : .off
        menu.addItem(lv)
        let gr = NSMenuItem(title: "빌드·시뮬 시작/끝 알림", action: #selector(toggleGroups), keyEquivalent: "")
        gr.target = self
        gr.state = notifyGroups ? .on : .off
        menu.addItem(gr)
        let bd = NSMenuItem(title: "메뉴바에 빌드·시뮬·세션 표시", action: #selector(toggleBadges), keyEquivalent: "")
        bd.target = self
        bd.state = showBadges ? .on : .off
        menu.addItem(bd)
        let am = NSMenuItem(title: "활성 상태 보기 열기", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        let log = NSMenuItem(title: "변화 기록 열기", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "LoadWatch 종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // 빌드·QA·검사는 슬롯을 받아야 시작한다(slot CLI + Claude Code 훅). 여기선 보여 주고 멈춤·취소만 한다.
    private func addSlotSection() {
        builtSlots = slots
        menu.addItem(info("작업 슬롯" + (slots.paused ? " · 새 작업 멈춤" : ""), bold: true))
        let now = Date().timeIntervalSince1970
        func line(_ j: SlotJob, _ mark: String) -> String {
            "\(mark) \(SlotView.names[j.cls] ?? j.cls) · \(j.label.prefix(46)) · \(j.place) · \(Int((now - j.since) / 60))분"
        }
        let counts = ["build", "qa", "check"].map { c in
            "\(SlotView.names[c]!) \(slots.running.filter { $0.cls == c }.count)/\(SlotView.caps[c]!)"
        }.joined(separator: " · ")
        menu.addItem(info(counts + (slots.waiting.isEmpty ? "" : " · 대기 \(slots.waiting.count)"), size: 12))
        for j in slots.running { menu.addItem(info(line(j, "▶"), size: 12)) }
        for j in slots.waiting { menu.addItem(info(line(j, "⏳"), color: .secondaryLabelColor, size: 12)) }

        let pause = NSMenuItem(title: "새 빌드·QA·시뮬 허가 멈춤", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = slots.paused ? .on : .off
        menu.addItem(pause)
        let killSlots = NSMenuItem(title: "슬롯 작업 모두 취소(대기 포함)", action: #selector(killSlotJobs), keyEquivalent: "")
        killSlots.target = self
        killSlots.isEnabled = !slots.running.isEmpty || !slots.waiting.isEmpty
        menu.addItem(killSlots)
        let killAll = NSMenuItem(title: "Claude 세션 빌드 전부 취소(CI 러너 제외)", action: #selector(killAllBuilds), keyEquivalent: "")
        killAll.target = self
        menu.addItem(killAll)
    }

    private func runSlot(_ args: [String], notify title: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [slotCLI] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.slots = SlotView.read()
                self.render()
                self.post(title, out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    @objc func togglePause() {
        runSlot([slots.paused ? "resume" : "pause"], notify: slots.paused ? "작업 슬롯 다시 허가" : "새 작업 허가 멈춤")
    }
    @objc func killSlotJobs() { runSlot(["kill"], notify: "슬롯 작업 취소") }
    @objc func killAllBuilds() { runSlot(["kill", "--all-builds"], notify: "Claude 세션 빌드 전부 취소") }

    @objc func toggleLevel() { notifyLevel.toggle() }
    @objc func toggleGroups() { notifyGroups.toggle() }
    @objc func toggleBadges() { showBadges.toggle() }
    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @objc func openLog() { NSWorkspace.shared.open(eventsLogURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - CLI

func runCLI(_ cmd: String) -> Never {
    guard let data = try? Data(contentsOf: stateURL) else {
        print("LoadWatch 상태 파일이 없습니다(앱이 안 떠 있음): \(stateURL.path)")
        exit(3)
    }
    if cmd == "json" {
        FileHandle.standardOutput.write(data)
        print()
        exit(0)
    }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    guard let s = try? dec.decode(Snapshot.self, from: data) else { print("상태 파일을 읽지 못했습니다"); exit(3) }
    let age = Date().timeIntervalSince(s.updatedAt)
    if age > 30 {
        print("LoadWatch 가 \(Int(age))초째 갱신이 없습니다(앱이 멈췄거나 꺼짐)")
        exit(3)
    }
    print("\(s.level.emoji) \(s.level.headline)")
    print("  \(s.reason)")
    print(String(format: "  CPU %d%%(30초 %d%%) · 메모리 %.1f/%.0fGB 압박 %@ · 세션 %d · 시뮬 %d · 에뮬 %d",
                 Int(s.cpuNow), Int(s.cpu30s), s.memUsedGB, s.memTotalGB, s.memoryPressure,
                 s.claudeSessions, s.bootedSimulators, s.androidEmulators))
    for g in s.groups.prefix(6) where g.cpu >= 1 {
        print(String(format: "  %@ %d%%", g.label, Int(g.cpu.rounded())))
    }
    exit(Int32(s.level.rawValue))
}

// 분류 규칙 점검용: 5초 동안 프로세스별 CPU 를 재서 그룹·측정 방식과 함께 상위만 보여 준다.
func runDebug() -> Never {
    let table = ProcTable()
    let ticks = CPUTicks()
    _ = ticks.sample()
    func measure() -> [Int32: (Double, ProcRow, Bool)] {
        let others = otherUsersCPU()
        var out: [Int32: (Double, ProcRow, Bool)] = [:]
        for r in table.list() {
            if r.mine, let u = inclusiveUsage(r.pid) { out[r.pid] = (u.seconds, r, true) }
            else if let t = others[r.pid] { out[r.pid] = (t, r, false) }
        }
        return out
    }
    let a = measure()
    Thread.sleep(forTimeInterval: 5)
    let b = measure()
    let total = ticks.sample() ?? 0
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    var rows: [(Double, ProcRow, Bool)] = []
    for (pid, (t, r, own)) in b {
        let before = a[pid].map { $0.1.path == r.path ? $0.0 : 0 } ?? 0
        rows.append((max(0, t - before) / 5 / cores * 100, r, own))
    }
    rows.sort { $0.0 > $1.0 }
    let sum = rows.reduce(0) { $0 + $1.0 }
    print(String(format: "전체 %.1f%% · 프로세스 합 %.1f%% · 차이 %.1f%%", total, sum, total - sum))
    for (pct, r, own) in rows.prefix(20) where pct >= 0.2 {
        print(String(format: "%5.1f%% %-6@ %@ %@", pct, (r.rule?.short ?? "-") as NSString,
                     own ? "자식포함" : "ps", (r.path as NSString).lastPathComponent))
    }
    exit(0)
}

// 그리기 점검용: 1초 간격으로 표본을 모은 뒤 드롭다운의 그래프·원인별 줄을 PNG 로 저장한다.
func runPreview(_ out: String, seconds: Int) -> Never {
    _ = NSApplication.shared
    let monitor = Monitor()
    for _ in 0...seconds {
        monitor.tick()
        Thread.sleep(forTimeInterval: 1)
    }
    let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
    chart.groups = monitor.groupHistory
    chart.mem = monitor.memHistory
    let v = monitor.view
    let header = newRow()
    header.header = true
    let views: [NSView] = [chart, header] + shownGroups(v).map { g in
        let row = newRow()
        configure(row, g, v)
        return row
    }
    let height = views.reduce(0) { $0 + $1.frame.height }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    var y = height
    for v in views {
        y -= v.frame.height
        v.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(v)
    }
    let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
    container.cacheDisplay(in: container.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print(out)
    exit(0)
}

let args = CommandLine.arguments
if args.count > 2, args[1] == "preview" { runPreview(args[2], seconds: args.count > 3 ? Int(args[3]) ?? 20 : 20) }
if args.count > 1, ["status", "json"].contains(args[1]) { runCLI(args[1]) }
if args.count > 1, args[1] == "debug" { runDebug() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
