package app.pillion.core

/**
 * Settings that only exist where Pillion drives a NaviLite dash from the phone itself — today, iOS.
 *
 * Both are things the dash allows and Android's path doesn't reach: writing the dash's own bottom
 * banner (it is the road-name field, which the stock handshake sends empty — that empty string is
 * why the dash falls back to its own label), and handing the rider straight to their navigation app
 * once the mirror is live. `null` on platforms without them, so the shared settings screen carries
 * no platform branch.
 */
interface DashExtras {
    /** Line of text the dash shows in its bottom banner instead of its own road label. */
    fun bannerText(): String

    /** Remembers the text. Does not touch a running mirror — [sendBanner] does that. */
    fun setBannerText(text: String)

    /** Puts the remembered text on the dash, if something is mirroring right now. */
    fun sendBanner()

    /** Whether starting the mirror should open the rider's navigation app. */
    fun launchNavApp(): Boolean

    fun setLaunchNavApp(enabled: Boolean)
}
