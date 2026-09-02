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

        var horizontalMargin = Math.Min(24, Math.Max(8, workArea.Width / 40));
        var width = Math.Min(requestedSize.Width, workArea.Width - (horizontalMargin * 2));
        var height = Math.Min(requestedSize.Height, workArea.Height - Math.Max(topInset, 0) - 16);
        var x = workArea.X + ((workArea.Width - width) / 2);
        var y = workArea.Y + Math.Max(topInset, 0);
        return new PixelRect(x, y, width, height);
    }
}
