import std/[strformat, sequtils]

type Celsius = distinct float

proc toFahrenheit(c: Celsius): float = float(c) * 9 / 5 + 32

let readings = @[Celsius(21.5), Celsius(-4.0), Celsius(37.0)]
for c in readings:
  echo &"{float(c):>6.1f} C = {c.toFahrenheit:>6.1f} F"
echo readings.mapIt(it.toFahrenheit).foldl(a + b) / readings.len.float
