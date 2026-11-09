using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SofaTap;

internal readonly record struct MacDisplayInfo(string Id, MacRect Bounds, double Scale, bool IsMain);

internal readonly record struct DisplayReadResult(bool IsMac, bool Succeeded, IReadOnlyList<MacDisplayInfo> Displays);

/// Logical display geometry for the additive hello.display catalog and for
/// warping the pointer to a display center. No Quartz call is required to test it.
internal static class MacDisplayGeometry
{
    internal static bool ValidId(string? id) =>
        id is { Length: >= 1 and <= 10 } && id.All(character => character is >= '0' and <= '9')
        && (id.Length == 1 || id[0] != '0') && uint.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out _);

    internal static bool Contains(IReadOnlyList<MacDisplayInfo> displays, string? id) =>
        ValidId(id) && displays.Any(display => display.Id == id);

    internal static MacPoint CenterOf(MacRect bounds)
    {
        var x = bounds.X + bounds.Width / 2;
        var y = bounds.Y + bounds.Height / 2;
        var maxX = bounds.X + Math.Max(bounds.Width - 1, 0);
        var maxY = bounds.Y + Math.Max(bounds.Height - 1, 0);
        return new(Math.Clamp(x, bounds.X, maxX), Math.Clamp(y, bounds.Y, maxY));
    }

    internal static bool TryCenter(IReadOnlyList<MacDisplayInfo> displays, string? id, out MacPoint center)
    {
        center = default;
        if (!ValidId(id)) return false;
        var matches = displays.Where(display => display.Id == id).ToArray();
        if (matches.Length != 1) return false;
        var bounds = matches[0].Bounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) return false;
        center = CenterOf(bounds);
        return true;
    }

    /// Null when the list must not be advertised. Callers omit a null hello field.
    internal static object? Capability(IReadOnlyList<MacDisplayInfo> displays)
    {
        if (displays.Count is 0 or > 16) return null;
        var wire = new List<object>(displays.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var mains = 0;
        foreach (var display in displays)
        {
            if (!ValidId(display.Id) || !seen.Add(display.Id)) return null;
            var width = Logical(display.Bounds.Width);
            var height = Logical(display.Bounds.Height);
            if (width is null || height is null) return null;
            if (!double.IsFinite(display.Scale) || display.Scale < 1 || display.Scale > 8) return null;
            if (display.IsMain) mains++;
            wire.Add(new { id = display.Id, width = width.Value, height = height.Value, scale = display.Scale, isMain = display.IsMain });
        }
        if (mains > 1) return null;
        return new { version = 1, displays = wire };
    }

    /// Include is false when the ping must omit display. A null node is JSON null,
    /// which withdraws a catalog the phone already accepted.
    internal readonly record struct PingDisplay(bool Include, JsonNode? Node);

    internal static PingDisplay Ping(bool isMac, bool succeeded, IReadOnlyList<MacDisplayInfo> displays)
    {
        if (!isMac || !succeeded) return new(false, null);
        var capability = Capability(displays);
        return capability is null
            ? new(true, null)
            : new(true, JsonSerializer.SerializeToNode(capability, LiveTextWire.Options));
    }

    private static int? Logical(double points)
    {
        if (!double.IsFinite(points) || points < 1 || points > 16_384) return null;
        var rounded = (int)Math.Round(points, MidpointRounding.AwayFromZero);
        return rounded is >= 1 and <= 16_384 ? rounded : null;
    }
}

internal static class MacDisplayProbe
{
    internal static DisplayReadResult Read()
    {
        if (!OperatingSystem.IsMacOS()) return new(false, false, []);
        try { return new(true, true, ReadQuartz()); }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or InvalidOperationException)
        { return new(true, false, []); }
    }

    private static IReadOnlyList<MacDisplayInfo> ReadQuartz()
    {
        var ids = new uint[32];
        if (QuartzNative.CGGetActiveDisplayList((uint)ids.Length, ids, out var count) != 0 || count == 0 || count > ids.Length)
            throw new InvalidOperationException("Could not read active displays.");
        var main = QuartzNative.CGMainDisplayID();
        var list = new List<MacDisplayInfo>((int)count);
        for (var index = 0; index < count; index++)
        {
            var id = ids[index];
            var rect = QuartzNative.CGDisplayBounds(id);
            if (rect.Size.Width <= 0 || rect.Size.Height <= 0) continue;
            list.Add(new(id.ToString(CultureInfo.InvariantCulture),
                new(rect.Origin.X, rect.Origin.Y, rect.Size.Width, rect.Size.Height),
                ReadScale(id, rect.Size.Width), id == main));
        }
        return list;
    }

    private static double ReadScale(uint id, double width)
    {
        var mode = QuartzNative.CGDisplayCopyDisplayMode(id);
        if (mode == IntPtr.Zero || width <= 0) return 1;
        try
        {
            var pixels = (double)QuartzNative.CGDisplayModeGetPixelWidth(mode);
            var scale = pixels / width;
            if (!double.IsFinite(scale) || scale < 1 || scale > 8) return 1;
            return Math.Round(scale, 2, MidpointRounding.AwayFromZero);
        }
        finally { QuartzNative.CFRelease(mode); }
    }
}
