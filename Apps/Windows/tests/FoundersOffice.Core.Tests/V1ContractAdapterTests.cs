using FoundersOffice.Core.Sync;

namespace FoundersOffice.Core.Tests;

public sealed class V1ContractAdapterTests
{
    [Fact]
    public void BootstrapFixturePreservesReviewedIdentityAndWorkspaceIDs()
    {
        var response = V1ContractAdapter.ParseBootstrapResponse(ReadFixture("bootstrap.response.json"));

        Assert.Equal(1, response.ContractVersion);
        Assert.Equal("google", response.Session.IdentityProvider);
        Assert.Equal(response.Session.AccountId, response.Profile.AccountId);
        Assert.Equal(response.Session.WorkspaceId, response.Workspace.Id);
        Assert.Equal("Reviewed Founder Name", response.Profile.DisplayName);
    }

    [Fact]
    public void PullFixturePreservesCursorBeyondJavaScriptSafeIntegerRange()
    {
        var response = V1ContractAdapter.ParsePullResponse(ReadFixture("pull.response.json"));

        Assert.Equal(9_007_199_254_740_992, response.FromCursor);
        Assert.Equal(9_007_199_254_740_993, response.NextCursor);
        Assert.Single(response.Changes);
    }

    [Fact]
    public void UnknownContractFieldFailsClosed()
    {
        var json = ReadFixture("bootstrap.response.json").Replace(
            "\"contractVersion\": 1,",
            "\"contractVersion\": 1, \"unreviewedField\": true,",
            StringComparison.Ordinal);

        var error = Assert.Throws<ContractMappingException>(() => V1ContractAdapter.ParseBootstrapResponse(json));
        Assert.Equal("contract_payload_invalid", error.Code);
    }

    private static string ReadFixture(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ContractFixtures", name));
}
