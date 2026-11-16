"""Command-line word counter with a few reports."""
from __future__ import annotations

import argparse
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

WORD = re.compile(r"[A-Za-z']+")


@dataclass
class Report:
    path: Path
    words: Counter[str] = field(default_factory=Counter)
    lines: int = 0

    @property
    def total(self) -> int:
        return sum(self.words.values())

    def top(self, n: int = 10) -> list[tuple[str, int]]:
        return self.words.most_common(n)


class Analyzer:
    """Reads files and builds reports."""

    def __init__(self, ignore: set[str] | None = None) -> None:
        self.ignore = {w.lower() for w in (ignore or set())}

    def analyze(self, path: Path) -> Report:
        report = Report(path)
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                report.lines += 1
                for word in WORD.findall(line):
                    word = word.lower()
                    if word not in self.ignore:
                        report.words[word] += 1
        return report

    def merge(self, reports: list[Report]) -> Counter[str]:
        merged: Counter[str] = Counter()
        for r in reports:
            merged.update(r.words)
        return merged


def format_report(report: Report, top: int) -> str:
    rows = [f"{word:<20} {count:>6}" for word, count in report.top(top)]
    header = f"{report.path} — {report.total} words, {report.lines} lines"
    return "\n".join([header, "-" * len(header), *rows])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args(argv)
    analyzer = Analyzer(ignore={"the", "a", "an", "and", "of"})
    for path in args.files:
        print(format_report(analyzer.analyze(path), args.top))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
