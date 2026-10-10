namespace BatteryPill.Core;

/// <summary>A screen rectangle in physical pixels.</summary>
public readonly record struct PxRect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool Contains(int x, int y) => x >= Left && x < Right && y >= Top && y < Bottom;
    public static PxRect FromSize(int x, int y, int w, int h) => new(x, y, x + w, y + h);
}

public readonly record struct PxPoint(int X, int Y);

/// <summary>Pill size in effective pixels (DIPs), before DPI scaling.</summary>
public readonly record struct PillSize(double Width, double Height, double FontSize, double FontSize2)
{
    public bool TwoLines => FontSize2 > 0;
}

public enum DisplayChangeAction { None, Restore, Park }

/// <summary>
/// Where the pill may sit and how big it is. Ports of Get-PillDimensions,
/// Get-SnappedLocation, Get-ClampedPosition, Test-PositionOnScreen and
/// Get-DisplayChangeAction. All positions are physical pixels.
/// </summary>
public static class PillGeometry
{
    public const int EdgeMargin = 8;

    /// <summary>
    /// The shipped sizes. Font sizes are in effective pixels for WinUI: the
    /// PowerShell app's 10.2 pt Segoe UI Semibold is 13.6 epx.
    /// </summary>
    public static PillSize Dimensions(string pillSize, string displayMode) => pillSize switch
    {
        "compact" => new(80, 28, 12, 0),
        "expanded" => new(140, 42, 13.6, 10),
        _ => displayMode == "both" ? new(108, 42, 13.3, 10) : new(108, 34, 13.6, 0),
    };

    /// <summary>
    /// Snap to the edges of the work area the pill's centre is on, when within
    /// <paramref name="threshold"/> px, leaving an <see cref="EdgeMargin"/> gap.
    /// </summary>
    public static PxPoint Snapped(PxPoint p, int width, int height, int threshold, PxRect workArea)
    {
        int x = p.X, y = p.Y;
        if (Math.Abs(x - workArea.Left) < threshold) x = workArea.Left + EdgeMargin;
        if (Math.Abs(x + width - workArea.Right) < threshold) x = workArea.Right - width - EdgeMargin;
        if (Math.Abs(y - workArea.Top) < threshold) y = workArea.Top + EdgeMargin;
        if (Math.Abs(y + height - workArea.Bottom) < threshold) y = workArea.Bottom - height - EdgeMargin;
        return new(x, y);
    }

    /// <summary>
    /// Pull the pill back inside the area. A pill larger than the area along an
    /// axis is left alone on that axis rather than mangled.
    /// </summary>
    public static PxPoint Clamped(PxPoint p, int width, int height, PxRect area)
    {
        int x = p.X, y = p.Y;
        if (width <= area.Width)
        {
            if (x + width > area.Right) x = area.Right - width;
            if (x < area.Left) x = area.Left;
        }
        if (height <= area.Height)
        {
            if (y + height > area.Bottom) y = area.Bottom - height;
            if (y < area.Top) y = area.Top;
        }
        return new(x, y);
    }

    /// <summary>Visible if its centre is inside any monitor's work area.</summary>
    public static bool IsOnScreen(PxPoint p, int width, int height, IEnumerable<PxRect> workAreas)
    {
        int cx = p.X + width / 2, cy = p.Y + height / 2;
        return workAreas.Any(a => a.Contains(cx, cy));
    }

    /// <summary>
    /// After a display change. The saved spot always wins when it is valid; a
    /// pill stranded off every screen is parked; a visible one is left alone.
    /// Nothing here ever overwrites the saved position.
    /// </summary>
    public static DisplayChangeAction OnDisplayChange(bool savedValid, bool currentValid, bool atSaved) =>
        savedValid ? (atSaved ? DisplayChangeAction.None : DisplayChangeAction.Restore)
        : currentValid ? DisplayChangeAction.None
        : DisplayChangeAction.Park;

    /// <summary>Does a window rectangle cover the whole monitor (fullscreen game, video)?</summary>
    public static bool CoversScreen(PxRect window, PxRect monitor) =>
        window.Left <= monitor.Left && window.Top <= monitor.Top && window.Right >= monitor.Right && window.Bottom >= monitor.Bottom;

    /// <summary>The default home: bottom-right of the work area, inset by the edge margin.</summary>
    public static PxPoint DefaultPosition(int width, int height, PxRect workArea) =>
        new(workArea.Right - width - EdgeMargin * 3, workArea.Bottom - height - EdgeMargin * 3);
}
