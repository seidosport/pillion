package app.pillion.ios

import app.pillion.core.DashExtras
import platform.Foundation.NSUserDefaults

/**
 * iOS side of [DashExtras].
 *
 * The values live in the app's own defaults under the same keys the Swift shell reads, so a mirror
 * that starts later picks them up when it asks for them. Actually putting the text on the dash is
 * Swift's job — the Darwin channel to the broadcast extension lives there — and arrives here as
 * [onSendBanner], the same injection pattern as [BroadcastMirrorController.onToggle].
 */
class IosDashExtras : DashExtras {
    /** Set by the Swift shell: spells the text down the Darwin channel to the broadcast extension. */
    var onSendBanner: ((String) -> Unit)? = null

    private val defaults = NSUserDefaults.standardUserDefaults

    override fun bannerText(): String = defaults.stringForKey(BANNER_KEY) ?: ""

    override fun setBannerText(text: String) {
        defaults.setObject(text, forKey = BANNER_KEY)
    }

    override fun sendBanner() {
        onSendBanner?.invoke(bannerText())
    }

    override fun launchNavApp(): Boolean = defaults.boolForKey(LAUNCH_KEY)

    override fun setLaunchNavApp(enabled: Boolean) {
        defaults.setBool(enabled, forKey = LAUNCH_KEY)
    }

    private companion object {
        const val BANNER_KEY = "dash.banner"
        const val LAUNCH_KEY = "launch.nav.app"
    }
}
