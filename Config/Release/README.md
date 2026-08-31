# Release-only Apple configuration

The direct-distribution build accepts production entitlements only from the tracked file:

`Config/Release/FoundersOfficeMac.entitlements`

Create that file only after the organization Team ID, bundle identifier, iCloud container, and provisioning profile are final. Do not commit a placeholder entitlement file: the release script verifies its exact production CloudKit container, Calendar access, user-selected read-only file access, sandbox, and push environment, and rejects debug or temporary-exception entitlements.

The file must also enable `com.apple.security.network.client`; the signed update feed and production sync transport cannot work in the sandbox without that explicit outbound-network capability.

The update signing private key is separate from Apple code signing. Keep it in the offline release Keychain described in `docs/product/MAC_SIGNED_UPDATE_CHANNEL.md`; never add it to this directory.

`PrivacyManifestPolicy.json` is the committed review record for the macOS privacy manifest. Release CI, packaging, and downloaded-artifact verification require the shipped `PrivacyInfo.xcprivacy` to match this policy semantically; syntax-only plist validation is not sufficient.
