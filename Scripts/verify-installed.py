#!/usr/bin/env python3
"""Opt-in real hardware checks. Run as the desktop user, never with sudo."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

CLI = "/Applications/清凉风扇.app/Contents/Helpers/coolmacctl"
APP = "/Applications/清凉风扇.app/Contents/MacOS/CoolMac"
HELPER = "/Library/PrivilegedHelperTools/local.hx10.coolmac.helper"


def command(*args, timeout=8):
    return subprocess.check_output([CLI, *args], text=True, timeout=timeout)


def status():
    return json.loads(command("status"))["status"]


def hardware():
    return json.loads(command("diagnose"))


def wait_automatic(timeout=12):
    end = time.monotonic() + timeout
    stable = 0
    while time.monotonic() < end:
        snapshot = hardware()
        print(json.dumps({"check": "automatic", "fans": snapshot["fans"]}, ensure_ascii=False), flush=True)
        if snapshot["fans"] and all(not fan["manual"] for fan in snapshot["fans"]):
            stable += 1
            if stable >= 3:
                return
        else:
            stable = 0
        time.sleep(0.6)
    raise RuntimeError("持续自动模式未确认；禁止继续接管")


def commission():
    command("restore")
    wait_automatic()
    result = subprocess.run([CLI, "commission"], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError("自检失败：" + result.stdout[-1000:] + result.stderr)
    current = status()
    if not current["commissioned"]:
        raise RuntimeError("硬件自检尚未确认")
    wait_automatic()


def root_signal(pid, name, pause=False):
    if not isinstance(pid, int) or pid <= 1 or name not in ("KILL", "STOP"):
        raise ValueError("非法测试目标")
    actual = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    if actual != HELPER:
        raise RuntimeError("拒绝对非本项目 helper 发送信号")
    # No user-provided command/path is accepted. Revalidate PID identity at the
    # root boundary; all privileged operations target this installed helper.
    quoted = "'" + HELPER + "'"
    script = f'test "$(/bin/ps -p {pid} -o comm=)" = {quoted} || exit 1; /bin/kill -{name} {pid}'
    if pause:
        # A bounded fault-injection hold; resume in this same authorized action,
        # even when the non-root observer times out or exits.
        script += f'; /bin/sleep 6; if test "$(/bin/ps -p {pid} -o comm=)" = {quoted}; then /bin/kill -CONT {pid}; fi'
    source = "do shell script " + json.dumps(script) + " with administrator privileges"
    return subprocess.Popen(["/usr/bin/osascript", "-e", source], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def wait_manual(timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        current = status()
        snapshot = current.get("snapshot") or {}
        temperatures = [item["celsius"] for item in snapshot.get("temperatures", [])]
        if not temperatures or max(temperatures) >= 85 or snapshot.get("thermalPressure", 0) >= 2:
            raise RuntimeError("温度/热压力不满足短时验收条件")
        if any(fan["manual"] for fan in snapshot.get("fans", [])):
            return current
        if current["phase"] == "fault":
            raise RuntimeError(current["message"])
        time.sleep(0.4)
    raise RuntimeError("未进入实际手动散热阶段；不将空闲退出当作恢复验证")


def fault_case(kind):
    print("CASE", kind, flush=True)
    commission()
    process = subprocess.Popen([CLI, "cool", "--seconds", "20"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    injector = None
    try:
        current = wait_manual()
        print("before:", json.dumps(current["snapshot"]["fans"], ensure_ascii=False), flush=True)
        if kind == "client-kill":
            process.kill()
        else:
            role, fault = kind.split("-")
            pid = current[role + "PID"]
            injector = root_signal(pid, "STOP" if fault == "pause" else "KILL", pause=fault == "pause")
            if fault == "kill":
                output, _ = injector.communicate(timeout=120)
                if injector.returncode:
                    raise RuntimeError("系统信号授权/执行失败：" + output)
        wait_automatic(timeout=15)
        if injector is not None and injector.poll() is None:
            output, _ = injector.communicate(timeout=120)
            if injector.returncode:
                raise RuntimeError("系统信号授权/执行失败：" + output)
        print("PASS", kind, flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if injector is not None and injector.poll() is None:
            # Never kill the injector before its guaranteed CONT step.
            output, _ = injector.communicate(timeout=130)
            if injector.returncode:
                print("授权操作失败：", output, flush=True)
        try:
            command("restore")
        except (subprocess.SubprocessError, ValueError) as error:
            print("恢复请求暂未返回：", error, flush=True)
        wait_automatic(timeout=15)


def enhancement_case(step):
    """Bounded check that the enhancement adds speed on top of the system's own.

    The comfort curve only participates at or above 50°C, so this only proves the
    enhancement when the machine is cool enough that the curve is out of the
    picture; otherwise the run is reported as inconclusive rather than passed.
    """
    print("CASE enhancement", step, flush=True)
    command("restore")
    wait_automatic()
    baseline = hardware()["fans"][0]
    ceiling = baseline["maximumRPM"] * 0.8
    curve_floor = baseline["minimumRPM"] + (baseline["maximumRPM"] - baseline["minimumRPM"]) * 0.4
    base = max(baseline["minimumRPM"], baseline["targetRPM"], baseline["actualRPM"])
    expected = min(ceiling, base * (1 + step / 100))
    print("system baseline:", json.dumps(baseline, ensure_ascii=False), flush=True)
    print("expected enhanced target:", expected, "curve floor:", curve_floor, flush=True)

    process = subprocess.Popen([CLI, "cool", "--seconds", "12", "--enhancement", str(step)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        peak = 0.0
        hottest_at_takeover = None
        commanded = None
        end = time.monotonic() + 14
        while time.monotonic() < end:
            snapshot = hardware()
            fan = snapshot["fans"][0]
            temperatures = [item["celsius"] for item in snapshot["temperatures"]]
            hottest = max(temperatures) if temperatures else None
            if hottest is not None and (hottest >= 85 or snapshot["thermalPressure"] >= 2):
                raise RuntimeError("温度/热压力超出短时验收条件")
            peak = max(peak, fan["actualRPM"])
            print(json.dumps({"fan": fan, "hottest": hottest}, ensure_ascii=False), flush=True)
            if fan["targetRPM"] > ceiling + 1:
                raise RuntimeError(f"下发目标 {fan['targetRPM']} 超过 80% 上限 {ceiling}")
            if fan["manual"] and fan["actualRPM"] < baseline["actualRPM"] - 100:
                raise RuntimeError("增强期间实测转速低于系统基准")
            if fan["manual"] and commanded is None:
                # Entering manual has a brief window where the mode is already
                # ours but the final target write has not landed yet, so the
                # reported target is still the system's. Take the settled value.
                pass
            if fan["manual"]:
                commanded = fan["targetRPM"] if commanded is None else max(commanded, fan["targetRPM"])
                if hottest_at_takeover is None:
                    hottest_at_takeover = hottest
            if process.poll() is not None:
                break
            time.sleep(0.8)

        if commanded is None:
            raise RuntimeError("未观察到实际接管，无法判断档位效果")
        if hottest_at_takeover is not None and hottest_at_takeover >= 50:
            raise RuntimeError(
                f"接管时最高温 {hottest_at_takeover:.1f}°C 已达舒适曲线阈值，"
                f"本次无法把档位与曲线区分开；请在机器冷却后重跑（不判定为通过）")
        if abs(commanded - expected) > max(60, expected * 0.05):
            raise RuntimeError(f"接管目标 {commanded} 与预期 {expected} 不符")
        if commanded >= curve_floor - 1:
            raise RuntimeError(f"接管目标 {commanded} 达到了曲线下限 {curve_floor}，档位未生效")
        print("PASS enhancement", step, "commanded", commanded, "expected", expected,
              "hottest", hottest_at_takeover, flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        command("restore")
        wait_automatic(timeout=15)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-fault-tests", action="store_true")
    parser.add_argument("--case", choices=["client-kill", "worker-kill", "worker-pause", "guardian-kill", "guardian-pause", "enhancement"])
    parser.add_argument("--enhancement-step", type=int, default=30)
    args = parser.parse_args()
    if os.geteuid() == 0 or os.getuid() != 501 or not args.allow_fault_tests:
        raise SystemExit("必须以本机桌面用户运行，并显式传 --allow-fault-tests；不要 sudo。")
    if not Path(CLI).is_file():
        raise SystemExit("先通过系统安装器安装应用。")
    if args.case == "enhancement":
        if args.enhancement_step not in (10, 20, 30, 40, 50, 60, 70, 80):
            raise SystemExit("--enhancement-step 必须是 10…80 的 10 的倍数。")
        enhancement_case(args.enhancement_step)
        print("增强档位检查通过；已交还系统自动。", flush=True)
        return
    for kind in [args.case] if args.case else ["client-kill", "worker-kill", "worker-pause", "guardian-kill", "guardian-pause"]:
        fault_case(kind)
    commission()
    print("全部指定检查通过；最终保持系统自动，未启用长期强力模式。", flush=True)


if __name__ == "__main__":
    main()
