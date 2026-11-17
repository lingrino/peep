#!/usr/bin/env python3
"""Hostile inputs for the view stack: each file once crashed, hung or ran away with memory in
a preview (they come from a review of the parsers, lexers, archive readers and renderer).
Deterministic and small; `Scripts/check.sh` writes them to .build/adversarial and runs
`peep-dev smoke --budget` over them, so a crash, a trap or super-linear work fails the check.

    python3 -I Scripts/make-adversarial.py <outdir>
"""
import gzip
import os
import sqlite3
import struct
import sys
import zlib

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


# --- archives ---------------------------------------------------------------------------

def zip_with_names(names, extra=b"", zip64=False):
    local, central = b"", b""
    for n in names:
        off = len(local)
        local += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0x5821, 0, 0, 0, len(n), 0) + n
        csize, usize, o = (0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF) if zip64 else (0, 5, off)
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 45, 45, 0, 0, 0, 0x5821, 0, csize, usize,
                               len(n), len(extra), 0, 0, 0, 0, o) + n + extra
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(names), len(names), len(central), len(local), 0)
    return local + central + end


# Invalid UTF-8 names: a surrogate, an F8 lead, an overlong, past U+10FFFF.
write("invalid-names.zip", zip_with_names([b"a\xed\xa0\x80.txt", b"b\xf8\x80\x80.txt", b"c\xe0\x80\x80.txt",
                                           b"d\xf4\x90\x80\x80.txt", b"e\xff\xfe.txt"]))
# ZIP64 extra field with sizes and offset near 2^64.
z64 = struct.pack("<HHQQQ", 0x0001, 24, 0xFFFFFFFFFFFFFFF0, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF)
write("zip64-huge.zip", zip_with_names([b"big.bin"], z64, zip64=True))


def tar_header(name, size_field, typeflag=b"0", mtime=b"00000000000\0"):
    h = bytearray(512)
    h[0:len(name)] = name
    h[100:108] = b"0000644\0"
    h[108:116] = b"0000000\0"
    h[116:124] = b"0000000\0"
    h[124:136] = size_field
    h[136:148] = mtime
    h[156:157] = typeflag
    h[257:263] = b"ustar\0"
    h[263:265] = b"00"
    h[148:156] = b"        "
    h[148:156] = b"%06o\0 " % (sum(h) & 0o777777)
    return bytes(h)


# GNU long name declaring 64 GiB; base-256 size >= 2^63; huge base-256 mtime.
write("tar-longname-64g.tar", tar_header(b"././@LongLink", b"777777777777", b"L") + b"\0" * 1536)
write("tar-size-2p63.tar", tar_header(b"x.txt", b"\x80" + b"\0" * 3 + b"\x80" + b"\0" * 7) + b"\0" * 1536)
write("tar-mtime-huge.tar", tar_header(b"y.txt", b"00000000000\0", mtime=b"\xff" * 12) + b"\0" * 1536)


def pax(records):
    body = b"".join(records)
    size = b"%011o\0" % len(body)
    padded = body + b"\0" * (-len(body) % 512)
    return tar_header(b"PaxHeader", size, b"x") + padded


write("tar-pax-bad.tar", pax([b"1 ", b"99999999999999999999 path=x\n", b"30 mtime=99999999999999999999\n"])
      + tar_header(b"z.txt", b"00000000000\0") + b"\0" * 1024)
# A tar.gz whose listing is long (many entries) stays within the budget.
many = b"".join(tar_header(b"d%04d/f%04d.txt" % (i // 50, i), b"00000000000\0") for i in range(4000)) + b"\0" * 1024
write("many-entries.tar.gz", gzip.compress(many, mtime=0))

# Long nested names imply a folder per path segment: lines, not entries, are the cost.
deep = [("/".join("d%d" % k for k in range(i * 40, i * 40 + 2000)) + "/f.txt").encode() for i in range(20)]
write("implied-folders.zip", zip_with_names(deep))
# Many empty gzip members.
write("empty-members.txt.gz", gzip.compress(b"", mtime=0) * 20000)
# gzip: FEXTRA + FNAME with XLEN pointing past the header.
write("gzip-bad-xlen.txt.gz", bytes([0x1F, 0x8B, 8, 0x0C, 0, 0, 0, 0, 0, 3]) + struct.pack("<H", 0xFFF0) + b"ab")
# Multi-member gzip (valid: the members' concatenation).
write("multi-member.txt.gz", gzip.compress(b"first member\n", mtime=0) + gzip.compress(b"second member\n", mtime=0))
# Truncated mid-character at the end of a compressed text.
write("cut-multibyte.js.gz", gzip.compress(("let s = '中文';\n" * 2000).encode()[:-2], mtime=0))

# --- markdown ---------------------------------------------------------------------------

write("deep-quotes.md", ">" * 300 + " x\n")
write("deep-lists.md", "".join("  " * i + "- x\n" for i in range(300)))
write("link-dest-parens.md", "[a](" * 50000)
write("image-openers.md", "![" * 40000 + "](b)" * 40000)
write("link-openers.md", "[" * 40000 + "[a](b)" * 40000)
write("wide-table.md", "|" + "a|" * 2000 + "\n|" + "-|" * 2000 + "\n" + "|x|\n" * 5000)
write("template-nesting.md", "# t\n\n" + "para\n\n" * 60 + "```js\n" + "`${" * 1000 + "\n```\n")
write("long-paragraph.md", "# p\n\n" + " ".join("word%d" % (i % 997) for i in range(40000)) + "\n")
write("huge-fence.md", "```\n" + "".join("line %d\n" % i for i in range(70000)) + "```\n\nafter\n")
write("svg-30000.md", "![x](data:image/svg+xml;utf8,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20"
      "width=%2230000%22%20height=%2230000%22%3E%3Crect%20width=%2210%22%20height=%2210%22/%3E%3C/svg%3E)\n")
write("link-titles.md", "[a](x (" * 30000)
write("label-brackets.md", "[r]: /u\n\n" + "[" * 40000 + "]" * 40000)
write("autolink-parens.md", "www.a" + ")" * 100000)
write("backtick-runs.md", "".join("`" * k + "x" for k in range(1, 1400)))
write("nested-images.md", "![a" * 20000)
write("unbreakable.md", "# w\n\n" + "a" * 400000 + "\n")
write("invalid-utf8.md", b"**a\xed\xa0\x80b** [x\xf8\x80\x80](y) `c\xe0\x80\x80d`\n\n```c\nint \xc0\xaf = 1; // \xff\n```\n")

# --- code -------------------------------------------------------------------------------

write("template-nesting.js", "`${" * 20000)
write("regex-candidates.js", ";/[" * 100000)
write("subshells.sh", "$(" * 30000)
write("call-candidates.c", "a f(" * 250000)
write("raw-hashes.swift", "#" * 128000)
write("dollar-runs.cs", "$" * 128000)
write("invalid-utf8.js", ("let s = '中文';\n" * 50).encode() + b"let t = '\xe4\xb8")

# --- data -------------------------------------------------------------------------------

write("amplifying.json", "[" + ",".join(["[[[]]]"] * 40000) + "]")   # re-indent expands it ~20x
write("deep.json", "[" * 100000 + "]" * 100000)
db = os.path.join(out, "virtual-table.sqlite")
if os.path.exists(db):
    os.remove(db)
c = sqlite3.connect(db)
c.execute("create table notes(id integer primary key, body text)")
c.execute("insert into notes(body) values ('hello')")
try:
    c.execute("create virtual table search using fts5(body)")
    c.execute("insert into search values ('alpha')")
except sqlite3.OperationalError:
    pass   # no FTS5 in this Python's SQLite: the plain table still exercises the path
c.commit()
c.close()
