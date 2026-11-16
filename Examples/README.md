# Examples

Sample files for everything Peep previews. Open this folder in Finder, select a file and
press **Space** (or use column view, which shows the same preview in its last column).

| Folder | What's inside | Try |
|---|---|---|
| [Code](Code) | One file per language (45), self-contained | Swift, Go, Rust, Python, TypeScript, C and Java samples are long enough for the **symbol sidebar** |
| [Config](Config) | JSON/JSONC/JSONL, YAML, TOML, INI, `.env`, XML, plist, CSS/SCSS/Less, shell, diff, Makefile, Dockerfile, CMake, lock files, TSV | Special names: `Makefile`, `Dockerfile`, `Gemfile`, `Cargo.lock`, `go.mod` |
| [Markdown](Markdown) | `Showcase.md` (every feature), `README-style.md` (centered HTML header, badges, details), `Handbook.md` (long, for the table of contents) | Click headings in the sidebar; ⌘F for "Limits" in the handbook |
| [Wrappers](Wrappers) | `config.yml.dist`, `app.env.example`, `nginx.conf.j2`, `Makefile.in`, `package.json.bak`, ... | Highlighted as the file they wrap |
| [Archives](Archives) | zip, jar, tar, tar.gz, tar.xz; single `.log.gz` and `.json.xz` | Listings as a tree with sizes and dates; compressed files show their content |
| [Data](Data) | Jupyter notebook, SQLite database, minified JSON, log, binary plist, binary file | Notebook outputs (text, table, chart, traceback); one section per table; JSON re-indented; log opens at the end; plist as XML; hex dump |

## Things to try in any preview

- **⌘F** to search, **Return** / **⌘G** for the next match, **⇧⌘G** for the previous, **Esc** to close.
- Drag to select text, **⌘A** to select all, **⌘C** to copy.
- Click a sidebar entry (Markdown headings, code symbols) to jump to it.
- Links in Markdown open in your browser.

## Files macOS keeps for itself

Quick Look prefers Apple's own previewers for `.txt`, `.csv`, `.pdf`, `.html` and `.svg`,
whatever Peep registers, so there are no samples of those here.

## Regenerating

The archives, notebook, database and other binary samples are built from the text samples:

```sh
Scripts/make-examples.sh           # rewrites Archives/, Data/ and Markdown/images/
Scripts/make-examples.sh --large   # also Large/ (not committed): 100 MB log, 60 MB minified
                                   # JSON, 150k-entry zip, 3M-row SQLite, big source files
```

The output is deterministic, so rerunning it leaves `git status` clean.
