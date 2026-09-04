namespace FoundersOffice.Core.Presentation;

public readonly record struct PixelRect(int X, int Y, int Width, int Height);

public readonly record struct PixelSize(int Width, int Height);

public static class TopEdgePlacement
{
    public static PixelRect Calculate(PixelRect workArea, PixelSize requestedSize, int topInset = 12)
    {
        if (workArea.Width <= 0 || workArea.Height <= 0 || requestedSize.Width <= 0 || requestedSize.Height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(workArea));
        }

        var horizontalMargin = Math.Min(
            Math.Min(24, Math.Max(8, workArea.Width / 40)),
            Math.Max(0, (workArea.Width - 1) / 2));
        var inset = Math.Clamp(topInset, 0, Math.Max(0, workArea.Height - 1));
        var width = Math.Min(requestedSize.Width, Math.Max(1, workArea.Width - (horizontalMargin * 2)));
        var height = Math.Min(requestedSize.Height, Math.Max(1, workArea.Height - inset));
        var x = workArea.X + ((workArea.Width - width) / 2);
        var y = workArea.Y + inset;
        return new PixelRect(x, y, width, height);
    }
}
