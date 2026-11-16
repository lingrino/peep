using System;
using System.Collections.Generic;
using System.Linq;

namespace Geometry;

public abstract record Shape(string Name)
{
    public abstract double Area { get; }
}

public sealed record Circle(double Radius) : Shape("circle")
{
    public override double Area => Math.PI * Radius * Radius;
}

public sealed record Rect(double W, double H) : Shape("rect")
{
    public override double Area => W * H;
}

public static class Program
{
    public static void Main()
    {
        var shapes = new List<Shape> { new Circle(1.5), new Rect(2, 3) };
        foreach (var s in shapes.OrderBy(s => s.Area))
            Console.WriteLine($"{s.Name,-8} {s.Area:F2}");
    }
}
