package com.foundersoffice.openloops

import android.annotation.SuppressLint
import android.content.Context

/** Stores content-free device preferences only; Move data remains in Room. */
@SuppressLint("ApplySharedPref", "UseKtx")
class LocalAppPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    val hasCompletedOnboarding: Boolean
        get() = preferences.getBoolean(ONBOARDING_COMPLETE, false)

    fun completeOnboarding(): Boolean = preferences.edit().putBoolean(ONBOARDING_COMPLETE, true).commit()

    private companion object {
        const val PREFERENCES_NAME = "founders-office-device-preferences"
        const val ONBOARDING_COMPLETE = "onboarding-complete-v1"
    }
}
