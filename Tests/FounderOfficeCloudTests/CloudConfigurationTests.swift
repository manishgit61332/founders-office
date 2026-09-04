import Testing
@testable import FounderOfficeCloud

struct CloudConfigurationTests {
    private let finalContainer = "iCloud.com.example.foundersoffice"

    @Test
    func acceptsOneExplicitMatchingContainer() throws {
        let configuration = try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
            cloudEnabled: true,
            configuredContainer: finalContainer,
            entitledContainers: [finalContainer]
        )

        #expect(configuration.containerIdentifier == finalContainer)
    }

    @Test
    func acceptsOneExplicitDeclaredContainerForPlatformsWithoutEntitlementInspection() throws {
        let configuration = try FounderOfficeCloudConfiguration.validatedDeclaredConfiguration(
            cloudEnabled: true,
            configuredContainer: finalContainer
        )

        #expect(configuration.containerIdentifier == finalContainer)
    }

    @Test
    func rejectsDisabledOrMissingConfiguration() {
        #expect(throws: FounderOfficeCloudConfigurationError.cloudDisabled) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: false,
                configuredContainer: finalContainer,
                entitledContainers: [finalContainer]
            )
        }
        #expect(throws: FounderOfficeCloudConfigurationError.missingContainerIdentifier) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: true,
                configuredContainer: nil,
                entitledContainers: [finalContainer]
            )
        }
    }

    @Test
    func rejectsMalformedOrUnentitledContainers() {
        #expect(throws: FounderOfficeCloudConfigurationError.malformedContainerIdentifier) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: true,
                configuredContainer: "container with spaces",
                entitledContainers: ["container with spaces"]
            )
        }
        #expect(throws: FounderOfficeCloudConfigurationError.missingContainerEntitlement) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: true,
                configuredContainer: finalContainer,
                entitledContainers: []
            )
        }
    }

    @Test
    func rejectsMismatchedOrAmbiguousEntitlements() {
        #expect(throws: FounderOfficeCloudConfigurationError.containerEntitlementMismatch) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: true,
                configuredContainer: finalContainer,
                entitledContainers: ["iCloud.com.example.other"]
            )
        }
        #expect(throws: FounderOfficeCloudConfigurationError.containerEntitlementMismatch) {
            try FounderOfficeCloudConfiguration.validatedBundledConfiguration(
                cloudEnabled: true,
                configuredContainer: finalContainer,
                entitledContainers: [finalContainer, "iCloud.com.example.other"]
            )
        }
    }
}
