package app.pillion.ios

import app.pillion.core.DashResolution
import app.pillion.core.SettingsStore
import app.pillion.core.ThemeMode
import platform.Foundation.NSUserDefaults

/**
 * [SettingsStore] backed by NSUserDefaults.
 *
 * [appGroup] is passed in from Swift (`BroadcastConfig.appGroup`) rather than hardcoded: a re-signer
 * like SideStore rewrites the granted group id (it also suffixes the bundle id — a tester's crash log
 * showed `app.pillion.dev.UNR2V73PN2`), and the extension reads whatever it was actually granted. Both
 * sides must name the same suite or the flags below silently never arrive.
 */
class IosSettingsStore(private val appGroup: String = DEFAULT_APP_GROUP) : SettingsStore {
    private val defaults = NSUserDefaults.standardUserDefaults

    init {
        // The flag can predate this build (or a re-sign can change the group id), and the setter below
        // only fires when the user *changes* bikes — so publish the current selection on every launch.
        syncBroadcastFlags(selectedBikeId())
    }

    override fun themeMode(): ThemeMode =
        runCatching { ThemeMode.valueOf(defaults.stringForKey(THEME_KEY) ?: ThemeMode.SYSTEM.name) }
            .getOrDefault(ThemeMode.SYSTEM)

    override fun setThemeMode(mode: ThemeMode) {
        defaults.setObject(mode.name, forKey = THEME_KEY)
    }

    // Dedicated dash mode is Android-only (ADB / virtual display); iOS streams via the broadcast
    // extension, so the UI never surfaces these. They're persisted only for interface completeness.
    override fun dashEnabled(): Boolean = defaults.boolForKey(DASH_ENABLED_KEY)

    override fun setDashEnabled(enabled: Boolean) {
        defaults.setBool(enabled, forKey = DASH_ENABLED_KEY)
    }

    override fun dashResolution(): DashResolution =
        DashResolution.fromName(defaults.stringForKey(DASH_RES_KEY))

    override fun setDashResolution(resolution: DashResolution) {
        defaults.setObject(resolution.name, forKey = DASH_RES_KEY)
    }

    override fun selectedBikeId(): String? = defaults.stringForKey(BIKE_KEY)

    override fun setSelectedBikeId(id: String) {
        defaults.setObject(id, forKey = BIKE_KEY)
        syncBroadcastFlags(id)
    }

    /**
     * Tell the out-of-process broadcast extension which path to run when the user hits "Start
     * mirroring": the SDL/Motorize bike → SDL video stream over iAP2/USB, anything else → NaviLite.
     * Written into the shared App Group the extension reads, well before broadcastStarted. iAP2 by
     * default so the on-bike tester never touches host/port.
     */
    private fun syncBroadcastFlags(bikeId: String?) {
        NSUserDefaults(suiteName = appGroup)?.apply {
            setBool(bikeId == SDL_BIKE_ID, forKey = "stream.sdl")
            setBool(false, forKey = "sdl.tcp")
        }
    }

    private companion object {
        const val THEME_KEY = "theme_mode"
        const val DASH_ENABLED_KEY = "dash_enabled"
        const val DASH_RES_KEY = "dash_resolution"
        const val BIKE_KEY = "selected_bike_id"
        const val DEFAULT_APP_GROUP = "group.app.pillion"
        const val SDL_BIKE_ID = "yamaha-sdl"   // SdlProfile.id
    }
}
