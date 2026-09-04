namespace FoundersOffice.Core.Sync;

public interface IV1SyncTransport
{
    Task<BootstrapResponseDto> BootstrapAsync(
        BootstrapRequestDto request,
        CancellationToken cancellationToken = default);

    Task<PushResponseDto> PushAsync(
        PushRequestDto request,
        CancellationToken cancellationToken = default);

    Task<PullResponseDto> PullAsync(
        PullRequestDto request,
        CancellationToken cancellationToken = default);
}

public sealed record ProductIdentity(Guid AccountId, string IdentityProvider)
{
    public ProductIdentity Validate()
    {
        if (AccountId == Guid.Empty)
        {
            throw new ArgumentException("The product account ID must not be empty.", nameof(AccountId));
        }

        if (IdentityProvider is not ("google" or "apple"))
        {
            throw new ArgumentException("The product identity provider is unsupported.", nameof(IdentityProvider));
        }

        return this;
    }
}
