using FoundersOffice.Core.Auth;

namespace FoundersOffice.App.Platform;

internal static class WindowsProductAuthApproval
{
    // Main integration must approve the exact beta project, public key, and
    // callback before a reviewed fingerprint replaces this closed gate.
    // A runtime configuration file cannot supply or override this approval.
    internal static ReviewedProductAuthRegistration? Current => null;
}
