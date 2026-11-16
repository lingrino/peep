let notebookTests: [Test] = [
    Test("json tree: ranges, escapes, surrogates, invalid input") {
        let t = JSONTree.parse(TextBuffer(#"{"a": [1, "x\ny", "é😀"], "b": {"c": null}, "d": true}"#))!
        let arr = t.elements(t.member(t.root, "a"))
        expectEqual(arr.count, 3)
        expectEqual(t.string(arr[1]), "x\ny")
        expectEqual(t.string(arr[2]), "é😀")
        expectEqual(t.kindOf(t.member(t.member(t.root, "b"), "c")!), .null)
        expectEqual(t.member(t.root, "zz"), nil)
        expect(JSONTree.parse(TextBuffer(#"{"a": [1, 2}"#)) == nil)
        expect(JSONTree.parse(TextBuffer(#"{"a": "unterminated}"#)) == nil)
        expect(JSONTree.parse(TextBuffer(String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000))) == nil)
    },
    Test("notebook: cells become Markdown, outputs fenced, images inline") {
        let nb = #"""
        {"cells": [
          {"cell_type": "markdown", "source": ["# Title\n", "Text"]},
          {"cell_type": "code", "source": "print(1)", "outputs": [
            {"output_type": "stream", "text": ["has ``` ticks\n"]},
            {"output_type": "display_data", "data": {"image/png": "iVBO\nRw0K\n", "text/plain": "<Figure>"}},
            {"output_type": "error", "ename": "E", "evalue": "v", "traceback": ["\u001b[0;31mE\u001b[0m: v"]}
          ]}
        ], "metadata": {"language_info": {"name": "julia"}}, "nbformat": 4}
        """#
        let md = Notebook.markdown(TextBuffer(nb))!
        expectEqual(md.string(0, md.count),
                    "# Title\nText\n\n```julia\nprint(1)\n```\n\n````output\nhas ``` ticks\n````\n\n![](data:image/png;base64,iVBORw0K)\n\n```output\nE: v\n```\n\n")
        expect(Notebook.markdown(TextBuffer(#"{"not": "a notebook"}"#)) == nil)
        let doc = MarkdownParser.parse(md)
        expectEqual(doc.blocks.filter { $0.output }.count, 2)
        expectEqual(doc.images.count, 1)
    },
]
