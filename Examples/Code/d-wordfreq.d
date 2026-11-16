import std.stdio, std.algorithm, std.array, std.string;

void main()
{
    auto text = "the quick brown fox jumps over the lazy dog the end";
    int[string] freq;
    foreach (word; text.split)
        freq[word]++;
    foreach (pair; freq.byKeyValue.array.sort!((a, b) => a.value > b.value).take(3))
        writefln("%-6s %d", pair.key, pair.value);
}
