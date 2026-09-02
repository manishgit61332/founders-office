namespace FoundersOffice.Core.Repository;

public sealed class WorkspaceRepositoryException : Exception
{
    public WorkspaceRepositoryException(string code, Exception? innerException = null)
        : base(code, innerException)
    {
        Code = code;
    }

    /// <summary>
    /// Stable redacted diagnostic code. Exception messages never include a
    /// Move title, database path, provider response, or credential.
    /// </summary>
    public string Code { get; }
}
