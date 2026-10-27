package app.page.android.demo

/**
 * Release builds carry no sample data and no render harness: the demo is debug-only (see the debug source set's
 * Demo.kt). Every entry point the main sources call exists here as a no-op.
 */
object Demo {
    const val available = false

    fun start() = Unit

    fun handleLaunchExtras(@Suppress("UNUSED_PARAMETER") extras: android.os.Bundle?) = Unit
}
