package app.pillion

import androidx.compose.ui.window.ComposeUIViewController
import app.pillion.core.MirrorController
import app.pillion.core.PreviewController
import app.pillion.core.headunit.registerBuiltInHeadUnits
import app.pillion.ios.IosSettingsStore
import app.pillion.ui.App
import platform.UIKit.UIViewController

/**
 * iOS entry point. The Swift shell builds the platform controllers — NaviLite over the ReplayKit
 * broadcast extension, and SDL over a native `SDLManager` CarWindow — and hands both in. Here we register
 * the head units and expose a per-bike factory ([app.pillion.ui.App] picks by [requiresUsb][app.pillion
 * .core.headunit.HeadUnitProfile.requiresUsb]); the shared Compose UI is identical to Android.
 */
fun MainViewController(
    naviliteController: MirrorController,
    sdlController: MirrorController?,
    onShareDiagnostics: () -> Unit,
    appGroup: String,
): UIViewController {
    registerBuiltInHeadUnits()
    return ComposeUIViewController {
        App(
            // Spike (spike/ios-sdl-extension): SDL now streams from the SAME broadcast extension as
            // NaviLite (so it can mirror the foreground app, e.g. Waze, while Pillion is backgrounded —
            // the in-app CarWindow `sdlController` can't). Both profiles route to the broadcast
            // controller; the extension picks SDL vs NaviLite from the App Group flag written at bike
            // selection. `sdlController` (in-app CarWindow SdlSession) is left wired but unused here.
            controllerFor = { _ -> naviliteController },
            updateChecker = null,
            settingsStore = IosSettingsStore(appGroup),
            onShareDiagnostics = onShareDiagnostics,
        )
    }
}

/** UI-only preview entry (no controller wiring) — boots the shared UI to validate it on iOS. */
fun MainViewControllerPreview(): UIViewController {
    registerBuiltInHeadUnits()
    return ComposeUIViewController {
        App(
            controllerFor = { PreviewController() },
            updateChecker = null,
            settingsStore = IosSettingsStore(),
        )
    }
}
