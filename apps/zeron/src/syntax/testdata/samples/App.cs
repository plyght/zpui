using System;
using System.Collections.Generic;
namespace Demo;
/// <summary>Doc</summary>
[Serializable]
public sealed class App<T> : IDisposable where T : class {
    private readonly List<T> _items = new();
    public int Count { get; private set; } = 0;
    public async Task<string> RunAsync(int value, string name = "x") {
        var text = $"Hello {name} {value:N2}";
        await Task.Delay(10);
        return value > 0 ? text : null;
    }
    public void Dispose() => GC.SuppressFinalize(this);
}
record Point(int X, int Y);
