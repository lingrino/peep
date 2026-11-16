#!/bin/zsh
# Regenerates the binary and generated samples in Examples/ (archives, notebook, SQLite,
# binary files, minified JSON, logs) from the text samples there. Output is deterministic
# (fixed mtimes, no user/group names, seeded data), so rerunning leaves git clean.
#
#   Scripts/make-examples.sh           # Examples/Archives, Examples/Data, Markdown images
#   Scripts/make-examples.sh --large   # also Examples/Large (gitignored): huge files for
#                                      # tail loads, progressive formatting and budgets
set -euo pipefail
ROOT=${0:A:h:h}
EX="$ROOT/Examples"
LARGE=0
[[ "${1:-}" == --large ]] && LARGE=1
export COPYFILE_DISABLE=1   # no AppleDouble ._ entries in archives
STAMP=202603011200          # fixed mtime for archived files
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$EX/Archives" "$EX/Data" "$EX/Markdown/images"

# Markdown image: the app icon.
sips -s format png -Z 256 "$ROOT/Bundle/AppIcon.icns" --out "$EX/Markdown/images/icon.png" >/dev/null

# A small project tree to archive: the code and config samples.
mkdir -p "$TMP/project/src" "$TMP/project/config" "$TMP/project/docs"
cp "$EX"/Code/* "$TMP/project/src/"
cp "$EX"/Config/* "$TMP/project/config/"
cp "$EX"/Markdown/*.md "$TMP/project/docs/"
mkdir -p "$TMP/project/empty-folder"
find "$TMP/project" -exec touch -h -t $STAMP {} +

cd "$TMP"
rm -f "$EX"/Archives/*(N)
zip -q -X -r "$EX/Archives/project.zip" project
# A .jar is a zip: Peep lists it the same way.
mkdir -p jar/META-INF jar/com/example/app
printf 'Manifest-Version: 1.0\nMain-Class: com.example.app.Main\n' > jar/META-INF/MANIFEST.MF
for c in Main Config Server Router; do printf '\xca\xfe\xba\xbe%s' "$c" > "jar/com/example/app/$c.class"; done
find jar -exec touch -h -t $STAMP {} +
(cd jar && zip -q -X -r -D "$EX/Archives/library.jar" META-INF com)
TAROPTS=(--uid 0 --gid 0 --uname "" --gname "" --no-xattrs --no-mac-metadata --no-acls --no-fflags --format ustar)
tar -cf "$EX/Archives/project.tar" "${TAROPTS[@]}" project
tar -cf - "${TAROPTS[@]}" project | gzip -n -9 > "$EX/Archives/project.tar.gz"
tar -cJf "$EX/Archives/project.tar.xz" "${TAROPTS[@]}" project
cd "$ROOT"

# Generated data: log, minified JSON, notebook, binary, plist; single compressed files.
python3 -I - "$EX" <<'PY'
import base64, gzip, io, json, lzma, os, random, struct, sys, zlib
ex = sys.argv[1]
rng = random.Random(27)

# A server log: opens scrolled to the end.
levels = ["INFO"] * 12 + ["DEBUG"] * 6 + ["WARN"] * 2 + ["ERROR"]
paths = ["/api/items", "/api/items/{id}", "/api/search", "/login", "/health", "/api/orders"]
def log_lines(n, seed):
    r = random.Random(seed)
    t = 1772359200  # 2026-03-01T10:00:00Z
    out = []
    for i in range(n):
        t += r.randint(0, 3)
        hh, mm, ss = (t // 3600) % 24, (t // 60) % 60, t % 60
        lvl = r.choice(levels)
        p = r.choice(paths).replace("{id}", str(r.randint(1, 9999)))
        code = r.choice([200] * 20 + [201, 204, 304, 400, 401, 404, 500])
        ms = int(r.expovariate(1 / 40)) + 1
        if lvl == "ERROR":
            msg = f"upstream timeout after {ms * 10}ms path={p} attempt={r.randint(1, 3)}"
        elif lvl == "WARN":
            msg = f"slow request {r.choice(['GET', 'POST'])} {p} {ms * 8}ms"
        else:
            msg = f"{r.choice(['GET', 'GET', 'POST', 'PUT', 'DELETE'])} {p} {code} {ms}ms request_id={r.getrandbits(48):012x}"
        out.append(f"2026-03-01T{hh:02}:{mm:02}:{ss:02}.{r.randint(0, 999):03}Z {lvl:<5} [{r.choice(['http', 'db', 'cache', 'auth'])}] {msg}")
    out.append("2026-03-01T23:59:59.999Z INFO  [http] shutting down: last line of the log")
    return "\n".join(out) + "\n"
open(f"{ex}/Data/server.log", "w").write(log_lines(3000, 1))

# Minified JSON (average line far over 200 bytes): shown re-indented.
items = [{"id": i, "sku": f"SKU-{i:05}", "name": f"Item {i}", "price": round(rng.uniform(1, 500), 2),
          "tags": rng.sample(["red", "blue", "sale", "new", "eco", "bulk", "gift"], 3),
          "stock": {"warehouse": rng.randint(0, 500), "store": rng.randint(0, 40)},
          "active": rng.random() > 0.2, "discontinued": None} for i in range(600)]
minified = json.dumps({"version": 3, "generated": "2026-03-01T10:00:00Z", "items": items}, separators=(",", ":"))
open(f"{ex}/Data/catalog.min.json", "w").write(minified)

# Single compressed files: previewed as what they contain.
with open(f"{ex}/Archives/older.log.gz", "wb") as f:
    with gzip.GzipFile(filename="older.log", mode="wb", fileobj=f, mtime=0) as g:
        g.write(log_lines(800, 2).encode())
open(f"{ex}/Archives/catalog.json.xz", "wb").write(lzma.compress(json.dumps(items[:50], indent=2).encode()))

# A PNG bar chart, drawn by hand (no dependencies): used as a notebook output.
def png(w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
W, H = 480, 240
px = bytearray([255] * (W * H * 3))
def rect(x0, y0, x1, y1, c):
    for y in range(max(0, y0), min(H, y1)):
        for x in range(max(0, x0), min(W, x1)):
            px[(y * W + x) * 3:(y * W + x) * 3 + 3] = bytes(c)
values = [12, 19, 7, 25, 16, 22, 9, 28]
rect(40, 20, 41, 210, (80, 80, 80)); rect(40, 209, 460, 210, (80, 80, 80))
for k, v in enumerate(values):
    x = 55 + k * 50
    rect(x, 210 - v * 6, x + 34, 209, (59, 130, 246) if k % 2 == 0 else (16, 185, 129))
chart = png(W, H, px)

def src(s): return [l + "\n" for l in s.split("\n")][:-1] + [s.split("\n")[-1]]
cells = [
    {"cell_type": "markdown", "metadata": {}, "source": src("# Sales analysis\n\nA notebook rendered as a document: Markdown cells, highlighted code, and outputs (text, tables, errors, images).")},
    {"cell_type": "code", "execution_count": 1, "metadata": {}, "outputs": [],
     "source": src("import statistics\nsales = [12, 19, 7, 25, 16, 22, 9, 28]\nmonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug']")},
    {"cell_type": "markdown", "metadata": {}, "source": src("## Summary statistics")},
    {"cell_type": "code", "execution_count": 2, "metadata": {},
     "outputs": [{"output_type": "stream", "name": "stdout", "text": src("mean   17.25\nmedian 17.5\nstdev  7.44")}],
     "source": src("for name, fn in [('mean', statistics.mean), ('median', statistics.median), ('stdev', statistics.stdev)]:\n    print(f'{name:<6} {fn(sales):.2f}'.rstrip('0'))")},
    {"cell_type": "code", "execution_count": 3, "metadata": {},
     "outputs": [{"output_type": "execute_result", "execution_count": 3, "metadata": {},
                  "data": {"text/plain": src("{'best': 'Aug', 'worst': 'Mar'}")}}],
     "source": src("{'best': months[sales.index(max(sales))], 'worst': months[sales.index(min(sales))]}")},
    {"cell_type": "markdown", "metadata": {}, "source": src("## Chart\n\nImage outputs are embedded in the notebook and drawn inline.")},
    {"cell_type": "code", "execution_count": 4, "metadata": {},
     "outputs": [{"output_type": "display_data", "metadata": {},
                  "data": {"image/png": base64.encodebytes(chart).decode(), "text/plain": ["<Figure size 480x240>"]}}],
     "source": src("import matplotlib.pyplot as plt\nplt.bar(months, sales)\nplt.show()")},
    {"cell_type": "markdown", "metadata": {}, "source": src("## Rich output")},
    {"cell_type": "code", "execution_count": 5, "metadata": {},
     "outputs": [{"output_type": "display_data", "metadata": {},
                  "data": {"text/markdown": src("| Month | Sales |\n|---|---:|\n| Jul | 9 |\n| Aug | **28** |"),
                           "text/plain": ["<IPython.core.display.Markdown object>"]}}],
     "source": src("from IPython.display import Markdown\nMarkdown('| Month | Sales |\\n|---|---:|\\n| Jul | 9 |\\n| Aug | **28** |')")},
    {"cell_type": "markdown", "metadata": {}, "source": src("## Errors\n\nTracebacks keep their text; terminal colors are removed.")},
    {"cell_type": "code", "execution_count": 6, "metadata": {},
     "outputs": [{"output_type": "error", "ename": "ZeroDivisionError", "evalue": "division by zero",
                  "traceback": ["\u001b[0;31m---------------------------------------------------------------------------\u001b[0m",
                                "\u001b[0;31mZeroDivisionError\u001b[0m                         Traceback (most recent call last)",
                                "Cell \u001b[0;32mIn[6], line 1\u001b[0m\n\u001b[0;32m----> 1\u001b[0m \u001b[43msum\u001b[49m(sales) \u001b[38;5;241m/\u001b[39m \u001b[38;5;241m0\u001b[39m",
                                "\u001b[0;31mZeroDivisionError\u001b[0m: division by zero"]}],
     "source": src("sum(sales) / 0")},
]
nb = {"cells": cells, "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
      "language_info": {"name": "python", "version": "3.13.0"}}, "nbformat": 4, "nbformat_minor": 5}
open(f"{ex}/Data/analysis.ipynb", "w").write(json.dumps(nb, indent=1) + "\n")

# Binary: shown as a hex dump.
open(f"{ex}/Data/firmware.bin", "wb").write(bytes(rng.getrandbits(8) for _ in range(4096)))

# The PNG on its own (Peep doesn't claim images; Finder shows it with Apple's viewer).
open(f"{ex}/Markdown/images/chart.png", "wb").write(chart)
PY

# Binary property list: shown as XML.
plutil -convert binary1 -o "$EX/Data/Preferences.plist" "$EX/Config/Info.plist"

# SQLite: tables, an index, a trigger, a view, NULLs, blobs, long text.
rm -f "$EX/Data/shop.sqlite"
sqlite3 "$EX/Data/shop.sqlite" >/dev/null <<'SQL'
PRAGMA journal_mode = DELETE;
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, city TEXT, joined DATE);
CREATE TABLE products (id INTEGER PRIMARY KEY, sku TEXT NOT NULL, title TEXT, price REAL CHECK (price >= 0), thumbnail BLOB);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), product_id INTEGER REFERENCES products(id),
                     quantity INTEGER DEFAULT 1, status TEXT CHECK (status IN ('new', 'paid', 'shipped', 'refunded')), notes TEXT, created_at TEXT);
CREATE INDEX orders_by_customer ON orders(customer_id, created_at);
CREATE TABLE audit (id INTEGER PRIMARY KEY, order_id INTEGER, change TEXT, at TEXT);
CREATE TRIGGER order_status AFTER UPDATE OF status ON orders BEGIN
  INSERT INTO audit (order_id, change, at) VALUES (new.id, old.status || ' -> ' || new.status, '2026-03-01T00:00:00Z');
END;
CREATE VIEW revenue_by_city AS
  SELECT c.city, round(sum(p.price * o.quantity), 2) AS revenue
  FROM orders o JOIN customers c ON c.id = o.customer_id JOIN products p ON p.id = o.product_id
  WHERE o.status IN ('paid', 'shipped') GROUP BY c.city ORDER BY revenue DESC;

WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 250)
INSERT INTO customers SELECT i,
  json_extract('["Ada","Grace","Linus","Margaret","Alan","Barbara"]', '$[' || (i % 6) || ']') || ' ' || i,
  'user' || i || '@example.test',
  CASE WHEN i % 7 = 0 THEN NULL ELSE json_extract('["Lisbon","Osaka","Austin","Nairobi","Oslo"]', '$[' || (i % 5) || ']') END,
  date('2020-01-01', '+' || (i * 5) || ' days')
FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 60)
INSERT INTO products SELECT i, printf('SKU-%05d', i * 37), 'Product ' || i || CASE WHEN i % 10 = 0 THEN ' with a long title that runs well past the cell width limit' ELSE '' END,
  round((i * 7.31) % 200 + 0.99, 2), CASE WHEN i % 3 = 0 THEN zeroblob(1024 + i) ELSE NULL END
FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
INSERT INTO orders SELECT i, (i * 13) % 250 + 1, (i * 7) % 60 + 1, i % 4 + 1,
  json_extract('["new","paid","shipped","refunded"]', '$[' || (i % 4) || ']'),
  CASE WHEN i % 11 = 0 THEN 'Gift wrap | leave at door' ELSE NULL END,
  datetime('2026-01-01', '+' || (i * 37) || ' minutes')
FROM n;
UPDATE orders SET status = 'shipped' WHERE id <= 5;
VACUUM;
SQL

if (( LARGE )); then
  L="$EX/Large"
  mkdir -p "$L"
  echo "writing $L (several hundred MB)..."
  python3 -I - "$EX" "$L" <<'PY'
import json, os, random, sys, zipfile
ex, L = sys.argv[1], sys.argv[2]
r = random.Random(5)
# 100 MB log: Peep loads its last 64 MB.
line = open(f"{ex}/Data/server.log").read()
with open(f"{L}/huge.log", "w") as f:
    while f.tell() < 100 << 20: f.write(line)
# 60 MB minified JSON: re-indented progressively.
item = json.loads(open(f"{ex}/Data/catalog.min.json").read())["items"]
with open(f"{L}/huge.min.json", "w") as f:
    f.write('{"items":[')
    for k in range(60 * 1024 * 1024 // len(json.dumps(item, separators=(",", ":")))):
        f.write(("," if k else "") + json.dumps(item, separators=(",", ":"))[1:-1])
    f.write("]}")
# 150k-entry zip: listed past the 25k-entry render deferral.
with zipfile.ZipFile(f"{L}/many-files.zip", "w", zipfile.ZIP_STORED) as z:
    for i in range(150_000):
        z.writestr(f"tree/{i % 40:02}/{i % 977:03}/file-{i:06}.txt", b"x")
# Big source and Markdown files.
code = "".join(open(f"{ex}/Code/{n}").read() for n in sorted(os.listdir(f"{ex}/Code")) if n.endswith(".swift"))
open(f"{L}/huge.swift", "w").write(code * ((20 << 20) // len(code)))
md = open(f"{ex}/Markdown/Handbook.md").read()
open(f"{L}/huge.md", "w").write(md * ((10 << 20) // len(md)))
PY
  rm -f "$L/huge.sqlite"
  sqlite3 "$L/huge.sqlite" <<'SQL'
CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT, payload TEXT, at TEXT);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000000)
INSERT INTO events SELECT i, 'kind-' || (i % 17), hex(randomblob(32)), datetime('2026-01-01', '+' || i || ' seconds') FROM n;
SQL
  tar -cf - --uid 0 --gid 0 --uname "" --gname "" -C "$L" many-files.zip huge.log | gzip -n -1 > "$L/big.tar.gz"
  ls -lh "$L"
fi
echo "examples written to $EX"
