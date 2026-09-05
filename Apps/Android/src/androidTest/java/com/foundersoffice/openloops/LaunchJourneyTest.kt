package com.foundersoffice.openloops

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LaunchJourneyTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun closeActivity() {
        scenario?.close()
    }

    @Test
    fun firstRunCanManageASyntheticMoveAndRelaunch() {
        setOnboardingComplete(false)
        scenario = ActivityScenario.launch(MainActivity::class.java)

        composeRule.onNodeWithTag("onboarding-start").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("nav-moves").performClick()
        composeRule.onNodeWithTag("add-move").performClick()
        composeRule.onNodeWithTag("move-title").performTextInput("Synthetic Move")
        composeRule.onNodeWithTag("save-move").performClick()
        composeRule.onNodeWithText("Synthetic Move").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("move-title").performTextReplacement("Updated Synthetic Move")
        composeRule.onNodeWithTag("save-move").performClick()
        composeRule.onNodeWithTag("nav-home").performClick()
        composeRule.onNodeWithText("NEXT MOVE").assertIsDisplayed()
        composeRule.onNodeWithTag("next-move-card").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("move-title").assertIsDisplayed()
        composeRule.onNodeWithText("Cancel").performClick()
        composeRule.onNodeWithTag("nav-moves").performClick()
        composeRule.onNodeWithContentDescription("Complete Updated Synthetic Move").performClick()
        composeRule.onNodeWithContentDescription("Reopen Updated Synthetic Move").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("Updated Synthetic Move").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("Delete").performClick()
        composeRule.onNodeWithText("Delete").performClick()
        composeRule.onNodeWithText("Recently deleted (1)").performClick()
        composeRule.onNodeWithText("Updated Synthetic Move").assertIsDisplayed()
        composeRule.onNodeWithText("Restore").performClick()
        composeRule.onNodeWithText("Current").performClick()
        composeRule.onNodeWithText("Updated Synthetic Move").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("Delete").performClick()
        composeRule.onNodeWithText("Delete").performClick()
        composeRule.onNodeWithText("Undo").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("Updated Synthetic Move").assertIsDisplayed()

        scenario?.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        composeRule.onNodeWithTag("nav-moves").performClick()
        composeRule.onNodeWithText("Updated Synthetic Move").assertIsDisplayed()
    }

    @Test
    fun calendarDeepLinkOpensCalendar() {
        setOnboardingComplete(true)
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("openloops://calendar/home"), context, MainActivity::class.java)
        scenario = ActivityScenario.launch(intent)

        composeRule.onNodeWithText("Upcoming commitments from calendars already connected to this device.")
            .assertIsDisplayed()
    }

    private fun setOnboardingComplete(complete: Boolean) {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        context.getSharedPreferences("founders-office-device-preferences", android.content.Context.MODE_PRIVATE)
            .edit()
            .putBoolean("onboarding-complete-v1", complete)
            .commit()
    }
}
