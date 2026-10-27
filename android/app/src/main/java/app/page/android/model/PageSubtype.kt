package app.page.android.model

/**
 * Known page subtypes (PROTOCOL.md §3). Free-form on the wire: anything else
 * is ignored and the page renders by its kind alone.
 */
object PageSubtype {
    const val PLAN = "plan"
    const val LOW_BATTERY = "low_battery"

    // v4 stuck watch (kind idle): a busy session repeats a failing call, has
    // written nothing for a while, or one of its workflows stopped making progress.
    const val LOOPING = "looping"
    const val STUCK = "stuck"
    const val WORKFLOW_STALLED = "workflow_stalled"

    // v4 Mac-wide forecasts (kind rate_limit): information only.
    const val BATTERY_FORECAST = "battery_forecast"
    const val USAGE_FORECAST = "usage_forecast"

    // Kind-less forms, as iOS `PageSubtype` has them (callers already know the kind).
    fun isStuck(subtype: String?): Boolean = subtype == LOOPING || subtype == STUCK || subtype == WORKFLOW_STALLED

    /** Stop (Deny -> Esc) applies to a busy session, not a stalled workflow. */
    fun canStop(subtype: String?): Boolean = subtype == LOOPING || subtype == STUCK

    fun isForecast(subtype: String?): Boolean = subtype == BATTERY_FORECAST || subtype == USAGE_FORECAST

    /** A "looks stuck" page: needs a nudge, never a Carry on. */
    fun isStuck(kind: InterventionKind, subtype: String?): Boolean =
        kind == InterventionKind.IDLE && (subtype == LOOPING || subtype == STUCK || subtype == WORKFLOW_STALLED)

    /** Stop it (deny → Esc) applies to a stuck session, not to a stalled workflow. */
    fun canStop(kind: InterventionKind, subtype: String?): Boolean =
        kind == InterventionKind.IDLE && (subtype == LOOPING || subtype == STUCK)

    /** A battery or usage forecast: nothing to answer. */
    fun isForecast(kind: InterventionKind, subtype: String?): Boolean =
        kind == InterventionKind.RATE_LIMIT && (subtype == BATTERY_FORECAST || subtype == USAGE_FORECAST)
}

/** The page's chip text: its kind, refined by a known subtype. */
fun Intervention.chipLabel(): String = chipLabel(kind, subtype)

fun chipLabel(kind: InterventionKind, subtype: String?): String = when {
    kind == InterventionKind.APPROVAL && subtype == PageSubtype.PLAN -> "PLAN APPROVAL"
    kind == InterventionKind.IDLE && subtype == PageSubtype.WORKFLOW_STALLED -> "WORKFLOW STALLED"
    PageSubtype.isStuck(kind, subtype) -> "LOOKS STUCK"
    kind == InterventionKind.RATE_LIMIT && subtype == PageSubtype.BATTERY_FORECAST -> "BATTERY"
    kind == InterventionKind.RATE_LIMIT && subtype == PageSubtype.USAGE_FORECAST -> "USAGE"
    else -> kind.label
}
