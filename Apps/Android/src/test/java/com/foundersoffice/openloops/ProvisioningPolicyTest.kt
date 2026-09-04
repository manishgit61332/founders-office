package com.foundersoffice.openloops

import com.foundersoffice.openloops.sync.LocalProvisioningState
import com.foundersoffice.openloops.sync.ProvisioningAction
import com.foundersoffice.openloops.sync.ProvisioningPolicy
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ProvisioningPolicyTest {
    @Test
    fun signInAloneCannotUploadOrAttachAWorkspace() {
        val signedInOnly = LocalProvisioningState(
            hasCustomerAuthoredData = true,
            hasExistingBinding = false,
            hasReviewedRemoteConfiguration = false,
            hasStoredProductSession = true,
            isProvenFreshDevice = false
        )

        assertFalse(ProvisioningPolicy.mayPerform(ProvisioningAction.ClaimLocalWorkspace, signedInOnly))
        assertFalse(ProvisioningPolicy.mayPerform(ProvisioningAction.AttachExistingWorkspace, signedInOnly))
        assertTrue(ProvisioningPolicy.requiresExportAndReplace(signedInOnly))
    }

    @Test
    fun onlyAnEmptyProvenFreshDeviceMayAttach() {
        val freshDevice = LocalProvisioningState(
            hasCustomerAuthoredData = false,
            hasExistingBinding = false,
            hasReviewedRemoteConfiguration = true,
            hasStoredProductSession = true,
            isProvenFreshDevice = true
        )

        assertTrue(ProvisioningPolicy.mayPerform(ProvisioningAction.AttachExistingWorkspace, freshDevice))
        assertFalse(ProvisioningPolicy.mayPerform(ProvisioningAction.ClaimLocalWorkspace, freshDevice))
    }
}
