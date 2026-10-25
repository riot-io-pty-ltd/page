package app.page.android.demo

/**
 * Release builds carry no sample data: the demo is debug-only (see the debug
 * source set's Demo.kt).
 */
object Demo {
    const val available = false

    fun start() = Unit

    fun handleLaunchExtras(@Suppress("UNUSED_PARAMETER") extras: android.os.Bundle?) = Unit
}
