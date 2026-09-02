using FoundersOffice.Core.Presentation;

namespace FoundersOffice.Core.Tests;

public sealed class TopEdgePlacementTests
{
    [Fact]
    public void CentersPreferredSurfaceInsideWorkArea()
    {
        var placement = TopEdgePlacement.Calculate(
            new PixelRect(0, 0, 1920, 1040),
            new PixelSize(760, 620));

        Assert.Equal(new PixelRect(580, 12, 760, 620), placement);
    }

    [Fact]
    public void ConstrainsSurfaceOnSmallDisplaysWithoutLeavingWorkArea()
    {
        var placement = TopEdgePlacement.Calculate(
            new PixelRect(120, 40, 640, 480),
            new PixelSize(760, 620));

        Assert.True(placement.X >= 120);
        Assert.True(placement.Y >= 40);
        Assert.True(placement.X + placement.Width <= 760);
        Assert.True(placement.Y + placement.Height <= 520);
    }
}
