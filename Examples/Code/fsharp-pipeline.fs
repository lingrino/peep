module Pipeline

type Reading = { Sensor: string; Value: float }

let readings =
    [ { Sensor = "a"; Value = 21.5 }
      { Sensor = "b"; Value = 19.0 }
      { Sensor = "a"; Value = 22.1 } ]

let averages =
    readings
    |> List.groupBy (fun r -> r.Sensor)
    |> List.map (fun (s, rs) -> s, rs |> List.averageBy (fun r -> r.Value))

for (sensor, avg) in averages do
    printfn "%s: %.2f" sensor avg
