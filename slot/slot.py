#!/usr/bin/env python3
"""slot: 이 맥의 무거운 작업(빌드·QA·시뮬 부팅)을 슬롯과 대기열로 나눠 돌린다.

세션마다 마음대로 빌드를 띄우면 CPU 100%·스왑 가득으로 맥 전체가 멈춘다(11-11).
그래서 무거운 명령은 슬롯을 받아야 시작하고, 슬롯이 없거나 부하가 높으면 먼저 온 순서대로 기다린다.

  slot acquire build --pid $$ --label "go test ./..."   # 셸($$)이 끝날 때까지 슬롯을 쥔다
  slot admit sim --label "simctl boot"                   # 시뮬 부팅 허가만 받는다(쥐지 않음)
  slot status | json                                     # 지금 쥔 것·기다리는 것
  slot pause | resume                                    # 새 작업 허가를 멈춘다/푼다
  slot kill [--all-builds]                               # 슬롯 쥔 작업(또는 Claude 세션 빌드 전부)을 끊는다
  slot hook                                              # Claude Code PreToolUse 훅(Bash 명령을 슬롯에 태운다)
  slot mcp-hook                                          # iOS 시뮬레이터 MCP build 도구용 훅

슬롯은 flock 으로 잡는다. 쥔 프로세스가 죽으면 커널이 풀어 주므로 엉킨 잠금이 남지 않는다.
허가 판단은 LoadWatch 상태 파일(5초 갱신)을 읽는다. 앱이 꺼져 있으면 load average 로 대신한다.
"""
import calendar
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
SUPPORT = os.path.join(HOME, "Library/Application Support/LoadWatch")
DIR = os.path.join(SUPPORT, "slots")
HOLD = os.path.join(DIR, "holders")
QUEUE = os.path.join(DIR, "queue")
PAUSE = os.path.join(DIR, "paused")
ADMITS = os.path.join(DIR, "sim-admits.json")
STATE = os.path.join(SUPPORT, "state.json")
LOG = os.path.join(HOME, "Library/Logs/LoadWatch/slots.log")
SELF = os.path.realpath(__file__)

# 클래스별 동시 실행 수. 10코어·24GB 기준, 빌드 하나가 코어를 거의 다 쓴다.
CAPS = {"build": 2, "qa": 1, "check": 3, "sim": 2}
LABELS = {"build": "빌드", "qa": "QA", "check": "검사", "sim": "시뮬"}
HEAVY = ("build", "qa")
MAX_WAIT = int(os.environ.get("SLOT_MAX_WAIT", "2700"))  # 45분 기다려도 못 받으면 실패로 돌려준다


def ensure_dirs():
    for d in (HOLD, QUEUE, os.path.dirname(LOG)):
        os.makedirs(d, exist_ok=True)


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def holders():
    """지금 슬롯을 쥔 작업. 잠금이 풀린(쥔 프로세스가 죽은) 기록은 지운다."""
    out = []
    for name in sorted(os.listdir(HOLD)) if os.path.isdir(HOLD) else []:
        if not name.endswith(".json"):
            continue
        path = os.path.join(HOLD, name)
        h = read_json(path)
        if not h or not alive(h.get("holder")):
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        out.append(h)
    return out


def tickets():
    """대기열. 기다리던 프로세스가 죽은 표는 지운다."""
    out = []
    for name in sorted(os.listdir(QUEUE)) if os.path.isdir(QUEUE) else []:
        if not name.endswith(".json"):
            continue
        path = os.path.join(QUEUE, name)
        t = read_json(path)
        if not t or not alive(t.get("pid")):
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        t["_file"] = name
        out.append(t)
    return out


def load_state():
    s = read_json(STATE)
    if s:
        try:
            # updatedAt 은 UTC 라 calendar.timegm 으로 읽는다
            age = time.time() - calendar.timegm(time.strptime(s["updatedAt"], "%Y-%m-%dT%H:%M:%SZ"))
        except (KeyError, ValueError):
            age = 999
        if age < 30:
            return s
    # LoadWatch 가 꺼져 있으면 load average 로 대신한다(정확도는 떨어진다)
    cores = os.cpu_count() or 8
    load1 = os.getloadavg()[0]
    return {"cpu30s": min(100.0, load1 / cores * 100), "memoryPressure": "정상",
            "bootedSimulators": 0, "androidEmulators": 0, "fallback": True}


def recent_sim_admits():
    now = time.time()
    xs = [t for t in (read_json(ADMITS) or []) if now - t < 90]
    return xs


def admit(cls):
    """(허가 여부, 이유). 대기열 맨 앞일 때만 부른다."""
    if os.path.exists(PAUSE):
        return False, "사용자가 새 작업을 일시 정지함(slot resume 로 풀림)"
    s = load_state()
    cpu = float(s.get("cpu30s", 0))
    pressure = s.get("memoryPressure", "정상")
    hs = holders()
    mine = [h for h in hs if h["cls"] == cls]
    heavy = [h for h in hs if h["cls"] in HEAVY]
    if cls == "sim":
        booted = int(s.get("bootedSimulators", 0)) + int(s.get("androidEmulators", 0)) + len(recent_sim_admits())
        if booted >= CAPS["sim"]:
            return False, "시뮬·에뮬 %d대 켜져 있음(최대 %d). 쓰던 기기를 재사용하거나 끝난 기기를 끄세요" % (booted, CAPS["sim"])
        if cpu >= 80 or pressure == "위험":
            return False, "과부하(CPU 30초 %d%%, 메모리 압박 %s)" % (cpu, pressure)
        return True, ""
    if len(mine) >= CAPS[cls]:
        return False, "%s 슬롯 %d개 모두 사용 중" % (LABELS[cls], CAPS[cls])
    if cls == "check":
        if cpu >= 85 or pressure == "위험":
            return False, "과부하(CPU 30초 %d%%, 메모리 압박 %s)" % (cpu, pressure)
        return True, ""
    if cpu >= 80 or pressure == "위험":
        return False, "과부하(CPU 30초 %d%%, 메모리 압박 %s)" % (cpu, pressure)
    if (cpu >= 55 or pressure in ("경고", "위험")) and heavy:
        return False, "빠듯함(CPU 30초 %d%%, 메모리 압박 %s)이라 무거운 작업은 한 번에 하나" % (cpu, pressure)
    return True, ""


def describe(h):
    mins = int((time.time() - h.get("since", time.time())) // 60)
    where = os.path.basename(h.get("cwd", "").rstrip("/")) or "?"
    return "%s(%s, %d분)" % (h.get("label", "?")[:40], where, mins)


# ---------------------------------------------------------------- 슬롯 쥐기

def spawn_holder(cls, info, until_idle=None):
    """슬롯을 쥐고 있을 손자 프로세스를 띄운다. 쥔 슬롯 번호(실패 시 -1)를 돌려준다.

    부모(acquire)는 곧 끝나야 셸이 다음 명령으로 넘어가므로, 잠금은 셸과 따로 사는 프로세스가 쥔다.
    그 프로세스는 셸($$)이 끝나면(또는 lease 모드면 대상 프로세스가 없어지면) 잠금을 풀고 끝난다.
    """
    r, w = os.pipe()
    pid = os.fork()
    if pid:
        os.close(w)
        os.waitpid(pid, 0)
        data = b""
        while True:
            chunk = os.read(r, 32)
            if not chunk:
                break
            data += chunk
        os.close(r)
        try:
            return int(data.decode() or "-1")
        except ValueError:
            return -1
    # 자식: 세션을 떼고 한 번 더 fork 해서 셸·Bash 도구와 완전히 분리한다
    try:
        os.close(r)
        os.setsid()
        if os.fork():
            os._exit(0)
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        os.closerange(3, w)
        os.closerange(w + 1, 4096)
        slot = -1
        lockfd = None
        for i in range(CAPS[cls]):
            fd = os.open(os.path.join(HOLD, "%s.%d.lock" % (cls, i)), os.O_CREAT | os.O_RDWR, 0o644)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                slot, lockfd = i, fd
                break
            except OSError:
                os.close(fd)
        if slot < 0:
            os.write(w, b"-1")
            os.close(w)
            os._exit(0)
        info.update(slot=slot, holder=os.getpid())
        path = os.path.join(HOLD, "%s.%d.json" % (cls, slot))
        write_json(path, info)
        os.write(w, str(slot).encode())
        os.close(w)
        hold_loop(info, until_idle)
        try:
            os.remove(path)
        except OSError:
            pass
        log("release %s.%d %s" % (cls, slot, info.get("label", "")))
        os._exit(0)
    except Exception as e:  # 손자에서 난 예외가 셸로 새지 않게
        log("holder error %r" % e)
        os._exit(1)


MAX_HOLD = 90 * 60  # 셸이 안 끝나도 90분이면 푼다(슬롯이 영영 묶이는 것 방지)


def hold_loop(info, until_idle):
    """셸이 끝나면 푼다. until_idle 이 있으면 그 프로세스가 사라진 뒤 20초 지나도 푼다.

    until_idle 은 빌드 뒤에도 셸이 살아 있는 명령(expo run:ios 는 빌드 후 Metro 를 계속 띄움)과
    셸이 없는 MCP build 도구에 쓴다. 대상이 2분 안에 안 뜨면 빌드가 없던 것으로 보고 푼다.
    """
    start = time.time()
    seen_at = None
    last_check = 0.0
    while time.time() - start < MAX_HOLD:
        if info.get("shell") and not alive(info["shell"]):
            return
        now = time.time()
        if until_idle and now - last_check >= 3:
            last_check = now
            if subprocess.run(["pgrep", "-f", until_idle], capture_output=True).returncode == 0:
                seen_at = now
            elif (seen_at and now - seen_at > 20) or (not seen_at and now - start > 120):
                return
        time.sleep(1)
    log("hold cap reached %s" % info.get("label", ""))


def wait_turn(cls, label, shell, until_idle=None, quiet=False):
    ensure_dirs()
    t0 = time.time()
    me = {"cls": cls, "pid": os.getpid(), "shell": shell, "label": label, "cwd": os.getcwd(), "since": t0}
    tfile = os.path.join(QUEUE, "%019d-%d.json" % (time.time_ns(), os.getpid()))
    write_json(tfile, me)
    last_print = 0.0
    try:
        while True:
            q = [t for t in tickets() if t["cls"] == cls]
            pos = next((i for i, t in enumerate(q) if t["pid"] == os.getpid()), 0)
            why = "앞에 %d개 대기" % pos
            if pos == 0:
                ok, why = admit(cls)
                if ok:
                    if cls == "sim":
                        write_json(ADMITS, recent_sim_admits() + [time.time()])
                        slot = 0
                    else:
                        info = dict(me, since=time.time())
                        slot = spawn_holder(cls, info, until_idle)
                    if slot >= 0:
                        waited = time.time() - t0
                        log("admit %s %s waited=%ds" % (cls, label, waited))
                        if not quiet and (waited > 3 or cls != "check"):
                            extra = " (대기 %d초)" % waited if waited > 3 else ""
                            sys.stderr.write("▶ [slot] %s 슬롯 받음%s: %s\n" % (LABELS[cls], extra, label[:60]))
                        return 0
                    why = "%s 슬롯 %d개 모두 사용 중" % (LABELS[cls], CAPS[cls])
            now = time.time()
            if now - t0 > MAX_WAIT:
                sys.stderr.write("✖ [slot] %s 슬롯을 %d분 기다렸지만 못 받았습니다(%s). "
                                 "지금은 이 맥에서 돌리지 말고 원격 맥·CI 로 돌리거나 사용자에게 알리세요.\n"
                                 % (LABELS[cls], MAX_WAIT // 60, why))
                log("timeout %s %s" % (cls, label))
                return 75
            if not quiet and now - last_print > 30:
                using = ", ".join(describe(h) for h in holders() if h["cls"] in (HEAVY if cls in HEAVY else (cls,)))
                sys.stderr.write("⏳ [slot] %s 대기 %d번째 · %s%s · %d초째\n"
                                 % (LABELS[cls], pos + 1, why, (" · 사용 중: " + using) if using else "", now - t0))
                sys.stderr.flush()
                last_print = now
            time.sleep(2)
    finally:
        try:
            os.remove(tfile)
        except OSError:
            pass


# ---------------------------------------------------------------- 명령 분류

WRAPPERS = {"time", "nice", "env", "command", "exec", "sudo", "nohup", "caffeinate", "timeout", "gtimeout",
            "xcrun", "npx", "bunx", "arch", "stdbuf", "unbuffer"}
PM = {"npm", "pnpm", "yarn", "bun"}
PM_VALUE_FLAGS = {"-C", "--dir", "--filter", "-F", "--workspace", "-w", "--prefix", "--cwd", "--cache-dir"}
PM_BUILTIN = {"install", "i", "ci", "add", "remove", "rm", "uninstall", "exec", "dlx", "x", "why", "list", "ls",
              "outdated", "view", "info", "publish", "version", "init", "link", "store", "config", "audit",
              "update", "up", "upgrade", "rebuild", "start", "dev", "serve", "help", "login", "whoami", "pack",
              "prune", "dedupe", "env", "root", "bin", "setup", "patch", "create"}
SEGMENT_SPLIT = re.compile(r"&&|\|\||;|\||\n|\$\(|`|\(|\)|&")


def strip_wrappers(t):
    while t:
        head = os.path.basename(t[0])
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0]):
            t = t[1:]
        elif head in ("timeout", "gtimeout"):
            t = t[2:]
        elif head in ("nice",):
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[2:] if t[0] == "-n" else t[1:]
        elif head == "arch":
            t = t[1:]
            while t and t[0].startswith("-"):
                t = t[1:]
        elif head in ("caffeinate", "env", "stdbuf"):
            t = t[1:]
            while t and (t[0].startswith("-") or re.match(r"^[A-Za-z_]\w*=", t[0])):
                t = t[1:]
        elif head in ("pnpm", "yarn") and len(t) > 1 and t[1] in ("exec", "dlx"):
            t = t[2:]
        elif head in WRAPPERS:
            t = t[1:]
        else:
            break
    return t


def script_class(name):
    n = name.lower()
    if re.search(r"(^|:)e2e|maestro|detox", n):
        return "qa"
    if re.search(r"(^|:)(build|ios|android|bundle|prebuild|compile|archive)(\b|:|$)", n):
        return "build"
    if re.search(r"(^|:)(test|typecheck|tsc|lint|check|vitest|jest)(\b|:|$)", n):
        return "check"
    return None


def classify_tokens(t):
    t = strip_wrappers(t)
    if not t:
        return None
    head = os.path.basename(t[0])
    args = t[1:]
    a1 = args[0] if args else ""
    if head == "go":
        return "build" if a1 in ("build", "test", "vet", "install") else None
    if head in ("golangci-lint", "staticcheck"):
        return "build"
    if head == "xcodebuild":
        info_flags = {"-runFirstLaunch", "-version", "-list", "-showsdks", "-showBuildSettings",
                      "-showdestinations", "-checkFirstLaunchStatus", "-exportArchive", "-help", "-usage",
                      "-showTestPlans", "-downloadPlatform", "-importPlatform", "-downloadAllPlatforms"}
        if any(a in info_flags for a in args):
            return None
        if any(a in ("test", "test-without-building") for a in args):
            return "qa"
        return "build"
    if head in ("gradlew", "gradle") or head.endswith("gradlew"):
        if not args or any(a in ("--stop", "--status", "tasks", "dependencies", "--version", "help") for a in args):
            return None
        if any("connected" in a or "AndroidTest" in a for a in args):
            return "qa"
        return "build"
    if head == "eas":
        return "build" if a1 == "build" and "--local" in args else None
    if head == "expo":
        return "build" if a1 in ("run:ios", "run:android", "prebuild", "export") else None
    if head == "react-native":
        return "build" if a1 in ("run-ios", "run-android", "bundle", "build-android", "build-ios") else None
    if head == "pod":
        return "build" if a1 in ("install", "update") else None
    if head in ("fastlane", "bazel", "bazelisk"):
        return "build" if head == "fastlane" or a1 in ("build", "test") else None
    if head in ("swift", "cargo"):
        return "build" if a1 in ("build", "test", "clippy") else None
    if head == "docker":
        return "build" if a1 in ("build", "buildx", "compose") and "build" in args else None
    if head == "flutter":
        return {"build": "build", "test": "check", "run": "build"}.get(a1)
    if head in ("tsc", "vue-tsc", "jest", "vitest", "eslint"):
        if "--watch" in args or "-w" in args:
            return None
        return "check"
    if head in ("maestro", "detox"):
        return "qa" if a1 == "test" else None
    if head == "simctl":
        return "sim" if a1 == "boot" else None
    if head == "open" and "-a" in args and any("Simulator" in a for a in args):
        return "sim"
    if head == "emulator" and any(a == "-avd" or a.startswith("@") for a in args):
        return "sim"
    if head in PM:
        i = 0
        while i < len(args):
            a = args[i]
            if a in PM_VALUE_FLAGS:
                i += 2
                continue
            if a.startswith("-"):
                i += 1
                continue
            break
        rest = args[i:]
        if not rest:
            return None
        if rest[0] in ("run", "run-script"):
            rest = [x for x in rest[1:] if not x.startswith("-")]
            return script_class(rest[0]) if rest else None
        if rest[0] in PM_BUILTIN:
            return None
        return script_class(rest[0])
    return None


ORDER = ["build", "qa", "check", "sim"]


def classify(command):
    """명령에서 슬롯이 필요한 클래스들과 대표 라벨을 뽑는다."""
    found = {}
    for seg in SEGMENT_SPLIT.split(command):
        seg = seg.strip()
        if not seg:
            continue
        try:
            t = shlex.split(seg, comments=True)
        except ValueError:
            t = seg.split()
        cls = classify_tokens(t)
        if cls and cls not in found:
            label = " ".join(strip_wrappers(t))
            found[cls] = re.sub(r"\s+\d*[<>].*$", "", label)[:80]  # 2>&1 같은 리다이렉트 꼬리는 라벨에서 뺀다
    # QA 는 빌드도 같이 하므로 QA 슬롯만 받는다. check 는 빌드와 겹치면 빌드 슬롯으로 충분하다.
    if "qa" in found:
        found.pop("build", None)
    if "build" in found or "qa" in found:
        found.pop("check", None)
    return [(c, found[c]) for c in ORDER if c in found]


# 빌드를 마친 뒤에도 셸이 안 끝나는 명령(개발 서버를 이어서 띄움). 이런 건 네이티브 빌드가 끝나면 슬롯을 푼다.
STAYS_UP = re.compile(r"^(expo run:|react-native run-|(npm|pnpm|yarn|bun)\b.*\b(ios|android)\b)")
NATIVE_BUILD = "xcodebuild|GradleWrapperMain|gradlew|GradleDaemon"


def rewrite(command):
    if "SLOT_BYPASS=1" in command or "slot acquire" in command or "slot admit" in command:
        return None
    classes = classify(command)
    if not classes:
        return None
    pre = []
    for cls, label in classes:
        if cls == "sim":
            pre.append("%s admit sim --label %s || exit $?" % (shlex.quote(SELF), shlex.quote(label)))
            continue
        lease = ""
        if STAYS_UP.search(label):
            lease = " --until-idle %s" % shlex.quote(NATIVE_BUILD)
        pre.append("%s acquire %s --pid $$ --label %s%s || exit $?"
                   % (shlex.quote(SELF), cls, shlex.quote(label), lease))
    if any(c in HEAVY for c, _ in classes):
        # 빌드는 UI 보다 뒤로 미루고, Go 는 패키지 동시 컴파일을 4개로 묶는다(슬롯 2개면 최대 8코어)
        pre.append("renice -n 10 -p $$ >/dev/null 2>&1")
        if any(l.startswith("go ") for _, l in classes):
            pre.append('case " $GOFLAGS " in *" -p="*) ;; *) export GOFLAGS="${GOFLAGS:+$GOFLAGS }-p=4";; esac')
    return "; ".join(pre) + "\n" + command


# ---------------------------------------------------------------- 하위 명령

def cmd_hook():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    ti = data.get("tool_input") or {}
    new = rewrite(ti.get("command", ""))
    if not new:
        return 0
    out = dict(ti, command=new)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": out}}))
    return 0


def cmd_mcp_hook():
    """iOS 시뮬레이터 MCP 의 build 는 셸이 없으니, 슬롯을 받은 뒤 xcodebuild 가 끝날 때까지 쥔다."""
    try:
        json.load(sys.stdin)
    except ValueError:
        pass
    global MAX_WAIT
    MAX_WAIT = min(MAX_WAIT, 540)  # 훅 timeout(600초) 안에 결론을 낸다
    rc = wait_turn("build", "iOS Simulator MCP build", 0, until_idle="xcodebuild", quiet=True)
    if rc == 0:
        return 0
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": "[slot] 이 맥이 바빠 빌드 슬롯을 9분 안에 받지 못했습니다. "
                                    "`slot status` 로 확인한 뒤 나중에 다시 시도하거나 사용자에게 알리세요."}}))
    return 0


def cmd_status(as_json=False):
    ensure_dirs()
    hs, ts = holders(), tickets()
    s = load_state()
    if as_json:
        print(json.dumps({"paused": os.path.exists(PAUSE), "caps": CAPS, "holders": hs,
                          "queue": [{k: v for k, v in t.items() if k != "_file"} for t in ts],
                          "cpu30s": s.get("cpu30s"), "memoryPressure": s.get("memoryPressure")},
                         ensure_ascii=False))
        return 0
    print("%s CPU 30초 %d%% · 메모리 압박 %s" % ("⏸ 일시 정지 ·" if os.path.exists(PAUSE) else "",
                                            s.get("cpu30s", 0), s.get("memoryPressure", "?")))
    for cls in ORDER:
        if cls == "sim":
            continue
        mine = [h for h in hs if h["cls"] == cls]
        q = [t for t in ts if t["cls"] == cls]
        print("  %s %d/%d%s" % (LABELS[cls], len(mine), CAPS[cls], ("  대기 %d" % len(q)) if q else ""))
        for h in mine:
            print("    ▶ %s" % describe(h))
        for t in q:
            print("    ⏳ %s" % describe(t))
    return 0


def descendants(root, table):
    kids = {}
    for pid, (ppid, _) in table.items():
        kids.setdefault(ppid, []).append(pid)
    out, stack = [], [root]
    while stack:
        p = stack.pop()
        for c in kids.get(p, []):
            out.append(c)
            stack.append(c)
    return out


def proc_table():
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            table[int(parts[0])] = (int(parts[1]), parts[2])
    return table


BUILD_PROC = re.compile(r"/darwin_arm64/(compile|link|asm|cgo|vet)\b|/usr/bin/clang|swift-frontend|SWBBuildService|"
                        r"\bxcodebuild\b(?!.*-runFirstLaunch)|\bgo (build|test|vet|install)\b|GradleDaemon|gradlew|"
                        r"\btsc\b.*--noEmit|jest-worker|golangci-lint")


def cmd_kill(all_builds=False):
    """슬롯 쥔 작업을 끊는다. --all-builds 면 슬롯 밖에서 돈 Claude 세션 빌드·고아 컴파일러도 끊는다(CI 러너 제외)."""
    table = proc_table()
    victims = set()
    # 기다리던 작업도 같이 지운다. 안 그러면 취소하자마자 대기열 다음 차례가 시작된다.
    for t in tickets():
        if t.get("shell"):
            victims.add(t["shell"])
        victims.add(t["pid"])
    for h in holders():
        if h.get("shell"):
            victims.add(h["shell"])
            victims.update(descendants(h["shell"], table))
        elif h.get("cls") == "build":  # lease(MCP build): xcodebuild 를 직접 찾는다
            victims.update(p for p, (_, c) in table.items() if "xcodebuild" in c and "-runFirstLaunch" not in c)
    if all_builds:
        for pid, (ppid, cmd) in table.items():
            if not BUILD_PROC.search(cmd):
                continue
            chain, p = [], pid
            for _ in range(40):
                if p not in table or p <= 1:
                    break
                chain.append(table[p][1])
                p = table[p][0]
            if any("Runner.Worker" in c or "actions-runner" in c or "Runner.Listener" in c for c in chain):
                continue
            if ppid == 1 or any("claude.app/Contents/MacOS/claude" in c for c in chain):
                victims.add(pid)
                victims.update(descendants(pid, table))
    victims.discard(os.getpid())
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for p in victims:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        if sig == signal.SIGTERM and victims:
            time.sleep(2)
    log("kill all_builds=%s n=%d" % (all_builds, len(victims)))
    print("끊은 프로세스 %d개" % len(victims))
    return 0


def main(argv):
    ensure_dirs()
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]

    def opt(name, default=None):
        return rest[rest.index(name) + 1] if name in rest and rest.index(name) + 1 < len(rest) else default

    if cmd in ("acquire", "admit"):
        if not rest or rest[0] not in CAPS:
            sys.stderr.write("클래스는 %s 중 하나\n" % ", ".join(CAPS))
            return 2
        cls = rest[0]
        shell = int(opt("--pid", os.getppid()))
        return wait_turn(cls, opt("--label", cls), shell, until_idle=opt("--until-idle"))
    if cmd == "status":
        return cmd_status()
    if cmd == "json":
        return cmd_status(as_json=True)
    if cmd == "pause":
        open(PAUSE, "w").close()
        log("pause")
        print("새 빌드·QA·시뮬 허가를 멈췄습니다. 돌고 있는 작업은 그대로입니다(끊으려면 slot kill).")
        return 0
    if cmd == "resume":
        try:
            os.remove(PAUSE)
        except OSError:
            pass
        log("resume")
        print("허가를 다시 시작합니다.")
        return 0
    if cmd == "kill":
        return cmd_kill(all_builds="--all-builds" in rest)
    if cmd == "hook":
        return cmd_hook()
    if cmd == "mcp-hook":
        return cmd_mcp_hook()
    if cmd == "classify":  # 점검용
        print(classify(" ".join(rest)))
        print(rewrite(" ".join(rest)))
        return 0
    sys.stderr.write("모르는 명령: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
