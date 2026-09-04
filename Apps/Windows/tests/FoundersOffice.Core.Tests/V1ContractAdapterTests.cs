using System.Globalization;
using FoundersOffice.Core.Domain;
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

    [Fact]
    public void PushFixturePreservesOperationRevisionBeyondJavaScriptSafeIntegerRange()
    {
        var response = V1ContractAdapter.ParsePushResponse(ReadFixture("push.response.json"));

        var result = Assert.Single(response.Results);
        Assert.Equal("accepted", result.Status);
        Assert.Equal(9_007_199_254_740_993, result.Revision);
        Assert.Equal(9_007_199_254_740_993, result.Cursor);
    }

    [Fact]
    public void PendingOperationMapsWithoutDoubleEncodingPayload()
    {
        var timestamp = DateTimeOffset.Parse("2026-09-04T10:00:00Z", CultureInfo.InvariantCulture);
        var operation = new PendingSyncOperation(
            Guid.Parse("33333333-3333-4333-8333-333333333333"),
            Guid.Parse("44444444-4444-4444-8444-444444444444"),
            "move",
            "upsert",
            0,
            "[\"title\"]",
            "{\"title\":\"2026-09-04T10:00:00.000000Z\"}",
            "{\"title\":\"One Move\"}",
            timestamp);

        var request = new PushRequestDto
        {
            WorkspaceId = Guid.Parse("11111111-1111-4111-8111-111111111111"),
            DeviceId = Guid.Parse("22222222-2222-4222-8222-222222222222"),
            Operations = [V1ContractAdapter.MapPendingOperation(operation)],
        };
        var json = V1ContractAdapter.SerializePushRequest(request);

        Assert.Contains("\"payload\":{\"title\":\"One Move\"}", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\\\"One Move\\\"", json, StringComparison.Ordinal);
        Assert.Contains("2026-09-04T10:00:00.000000Z", json, StringComparison.Ordinal);
    }

    private static string ReadFixture(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ContractFixtures", name));
}
