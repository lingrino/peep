#!/usr/bin/env python3 -I
"""Summarize an Instruments Time Profiler trace: top functions by self and total samples.

    Scripts/profile.sh <command...>          # records + summarizes
    python3 Scripts/profile.py <trace> [N]   # summarize an existing trace
"""
import subprocess, sys, os, collections
import xml.etree.ElementTree as ET

def main():
    trace = sys.argv[1]
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("XCODE_DIR", "/Applications/Xcode.app/Contents/Developer"))
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                         capture_output=True, env=env, check=True).stdout
    root = ET.fromstring(xml)
    ids = {}
    for el in root.iter():
        if "id" in el.attrib:
            ids[el.attrib["id"]] = el
    def resolve(el):
        return ids.get(el.attrib["ref"], el) if "ref" in el.attrib else el
    focus = os.environ.get("FOCUS")   # function-name substring: report hot instruction offsets
    addrs = collections.Counter(); loads = {}
    selfc = collections.Counter(); total = collections.Counter(); n = 0
    for row in root.iter("row"):
        bt = row.find("tagged-backtrace")
        if bt is None:
            bt = row.find("backtrace")
        if bt is None:
            continue
        bt = resolve(bt)
        frames = []
        for k, fr in enumerate(bt.findall("frame")):
            fr = resolve(fr)
            frames.append(fr.attrib.get("name", "?"))
            if k == 0 and focus and focus in fr.attrib.get("name", ""):
                b = fr.find("binary")
                if b is not None:
                    b = resolve(b)
                    load = int(b.attrib.get("load-addr", "0"), 16)
                    addrs[int(fr.attrib["addr"], 16) - load] += 1
        if not frames:
            continue
        n += 1
        selfc[frames[0]] += 1
        for f in set(frames):
            total[f] += 1
    def short(s):
        return s if len(s) < 110 else s[:107] + "..."
    print(f"{n} samples\n-- self --")
    for f, c in selfc.most_common(top):
        print(f"{100*c/n:6.1f}%  {short(f)}")
    if focus:
        print(f"-- hot offsets in {focus} (binary-relative; add 0x100000000 for otool) --")
        for a, c in addrs.most_common(40):
            print(f"{100*c/n:6.2f}%  0x{a + 0x100000000:x}")
    print("-- total --")
    for f, c in total.most_common(top):
        print(f"{100*c/n:6.1f}%  {short(f)}")

main()
