#!/usr/bin/env python3
"""Sample RSS and CPU time for explicit process trees without changing app state."""
import argparse
import json
import statistics
import subprocess
import time


def processes():
    result = {}
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,rss=,time="], text=True
    )
    for line in output.splitlines():
        pid, parent, rss, cpu = line.split()
        seconds = 0.0
        for part in cpu.split(":"):
            seconds = seconds * 60 + float(part)
        result[int(pid)] = (int(parent), int(rss), seconds)
    return result


def tree(snapshot, root):
    members = {root} if root in snapshot else set()
    while True:
        children = {pid for pid, row in snapshot.items() if row[0] in members}
        if children <= members:
            return members
        members |= children


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, action="append", required=True)
    parser.add_argument("--exclude-pid", type=int, action="append", default=[])
    parser.add_argument("--seconds", type=int, default=15)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error("--seconds must be between 1 and 60")
    first = processes()
    if any(pid not in first for pid in args.pid):
        parser.error("Every root PID must be running")
    samples = {pid: [] for pid in args.pid}
    previous = first
    cpu = dict.fromkeys(args.pid, 0.0)
    stable = dict.fromkeys(args.pid, True)
    started = time.monotonic()
    for _ in range(args.seconds):
        time.sleep(1)
        current = processes()
        if any(pid not in current for pid in args.pid):
            parser.error("A root process exited during measurement")
        excluded = set().union(*(tree(current, pid) for pid in args.exclude_pid))
        for root in args.pid:
            members = tree(current, root) - excluded
            if tree(current, root) != tree(first, root):
                stable[root] = False
            samples[root].append(sum(current[pid][1] for pid in members) / 1024)
            # Exited children cannot contribute their final CPU tick: keep workloads idle.
            cpu[root] += sum(max(0, current[pid][2] - previous.get(pid, (0, 0, 0))[2]) for pid in members)
        previous = current
    elapsed = time.monotonic() - started
    print(json.dumps({
        "seconds": round(elapsed, 2),
        "metric": "sum of resident sets; includes shared pages, not physical footprint",
        "processes": [{
            "pid": pid,
            "rss_mib_mean": round(statistics.mean(samples[pid]), 1),
            "cpu_percent_one_core": round(cpu[pid] / elapsed * 100, 2),
            "process_count": len(tree(previous, pid) - excluded),
            "stable_process_tree": stable[pid],
        } for pid in args.pid],
    }, indent=2))


if __name__ == "__main__":
    main()
