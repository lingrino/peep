---
title: Markdown showcase
tags: [examples, peep]
---

# Markdown showcase

Everything Peep renders in Markdown, in one place. The **table of contents** on the left lists
every heading; click one to jump. Press **⌘F** to search, then **⌘G** / **⇧⌘G** to move between
matches. Text is selectable; **⌘C** copies it.

## Text

Plain paragraphs wrap to the window. *Emphasis*, **strong**, ***both***, ~~strikethrough~~,
`inline code`, and <kbd>⌘</kbd> + <kbd>Space</kbd> keys. Superscript and subscript come from
HTML: x<sup>2</sup>, H<sub>2</sub>O. A backslash at the end of a line is a hard break,\
so this sentence starts on a new line. Characters like &copy; &mdash; &#x1F600; are entities.

Autolinks: https://example.com and <https://example.org/docs>. Inline links:
[CommonMark](https://commonmark.org "The spec"). Reference links: [GFM][gfm] and [the spec].

[gfm]: https://github.github.com/gfm/
[the spec]: https://spec.commonmark.org/

Emoji and other scripts: 🎉 ✅ — Ünïcödé, 日本語, العربية, Ελληνικά. GitHub shortcodes work too:
:tada: :rocket: :white_check_mark: :warning: :+1: :sparkles: (and `:tada:` in code stays as typed).

## Headings

### Third level

#### Fourth level

##### Fifth level

###### Sixth level

Setext heading
--------------

## Lists

- Bullets
  - nested
    - deeper
- with **inline** formatting
  and a lazy continuation line

1. Ordered
2. Lists
   1. nested ordered
   2. items
3. Continue

An ordered list can start at any number:

7. seven
8. eight

### Task list

- [x] Parse CommonMark and GFM
- [x] Highlight fenced code
- [ ] Something still to do
  - [x] nested task

## Quotes

> A block quote.
>
> > Nested quote with `code` and a [link](https://example.com).
>
> - lists inside quotes
> - work too

## Alerts

> [!NOTE]
> Useful information that users should know, even when skimming.

> [!TIP]
> Helpful advice for doing things better or more easily.

> [!IMPORTANT]
> Key information users need to know to achieve their goal.
>
> Alerts can have several paragraphs, `code`, and [links](https://example.com).

> [!WARNING]
> Urgent info that needs immediate user attention to avoid problems.

> [!CAUTION]
> Advises about risks or negative outcomes of certain actions.

## Code

Fenced code is highlighted in its language:

```swift
struct Point: Hashable {
    var x, y: Double
    func distance(to p: Point) -> Double { ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot() }
}
```

```python
def fib(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

```json
{ "name": "peep", "fast": true, "count": 3, "tags": ["ql", "md"] }
```

```diff
- old line
+ new line
```

```sh
for f in *.md; do echo "$f"; done
```

    Indented code blocks
    have no language.

~~~
Tilde fences work too. Long lines in code blocks wrap at the window edge instead of scrolling sideways: 0123456789 abcdefghijklmnopqrstuvwxyz
~~~

## Tables

| Language   | Extension | Lexer      |   Speed |
|:-----------|:---------:|:-----------|--------:|
| Swift      | `.swift`  | C-like     | fast    |
| Python     | `.py`     | C-like     | fast    |
| YAML       | `.yml`    | dedicated  | fast    |
| **Bold**   | *italic*  | [link](https://example.com) | `code` |

A table with many columns:

| a | b | c | d | e | f | g | h | i | j | k | l |
|---|---|---|---|---|---|---|---|---|---|---|---|
| one | two | three | four | five | six | seven | eight | nine | ten | eleven | twelve |

## Images

A local image (relative path):

![Peep icon](images/icon.png)

A remote image (fetched by the Peep agent) and badges:

![badge](https://img.shields.io/badge/quick%20look-peep-blue) ![badge](https://img.shields.io/badge/speed-fast-brightgreen)

## HTML

<div align="center">
  <img src="images/icon.png" width="64" alt="small icon">
  <p><strong>Centered</strong> with <code>&lt;div align="center"&gt;</code></p>
</div>

<details>
<summary>Details / summary</summary>

The content of a details block is shown expanded.

</details>

<p align="right">Right-aligned paragraph.</p>

<!-- HTML comments are hidden -->

## Footnotes

Footnote references look like this[^1] and can use names[^note]. Click one to jump to it; the ↩
after a footnote jumps back. A footnote can be referenced again[^1], and can hold several
paragraphs[^long]. They're numbered in the order they're first referenced and collected at the
end of the document, wherever they're defined.

[^1]: The first footnote.
[^note]: A named footnote, with **formatting**.
[^long]: The first paragraph of a longer footnote.

    Indented paragraphs continue it, and so does code:

        let answer = 42

## Rules

Above the rule.

---

Below the rule.

## Escapes and edge cases

\*not emphasis\*, \# not a heading, 2 \* 3 = 6, a_b_c stays plain, `` `backticks` `` inside code.
