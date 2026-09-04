import Foundation

/// Supabase is the sole iOS sync authority. This seam deliberately does not
/// import or start CloudKit: existing local legacy files stay available to the
/// SQLite migration, while any remote-only legacy workspace requires a
/// separately reviewed, one-time migration utility with source/destination
/// verification. It must never run alongside live Supabase sync.
enum IOSLegacyCloudMigration {
    static let customerMessage = "Older iCloud-only workspaces need a separate migration before device sync. Local data is not deleted or uploaded automatically."
}
