package com.foundersoffice.openloops.sync

/**
 * Product auth does not provision. The UI uses this policy to keep an
 * unbound local workspace safe until the person deliberately claims it or,
 * for a proven fresh device, attaches the account's existing workspace.
 */
enum class ProvisioningAction { ClaimLocalWorkspace, AttachExistingWorkspace }

data class LocalProvisioningState(
    val hasCustomerAuthoredData: Boolean,
    val hasExistingBinding: Boolean,
    val hasReviewedRemoteConfiguration: Boolean,
    val hasStoredProductSession: Boolean,
    val isProvenFreshDevice: Boolean
)

object ProvisioningPolicy {
    fun mayPerform(action: ProvisioningAction, state: LocalProvisioningState): Boolean = when (action) {
        ProvisioningAction.ClaimLocalWorkspace ->
            state.hasCustomerAuthoredData &&
                !state.hasExistingBinding &&
                state.hasReviewedRemoteConfiguration &&
                state.hasStoredProductSession

        ProvisioningAction.AttachExistingWorkspace ->
            !state.hasExistingBinding &&
                state.hasReviewedRemoteConfiguration &&
                state.hasStoredProductSession &&
                state.isProvenFreshDevice &&
                !state.hasCustomerAuthoredData
    }

    fun requiresExportAndReplace(state: LocalProvisioningState): Boolean =
        state.hasCustomerAuthoredData && !state.hasExistingBinding
}
