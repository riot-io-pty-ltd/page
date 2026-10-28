package app.page.android.ui.nw.room

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddPhotoAlternate
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import app.page.android.model.PhotoDraft
import app.page.android.model.PhotoLimits
import app.page.android.model.PhotoOffer
import app.page.android.model.PhotoStatus
import app.page.android.ui.nw.theme.NW

// Photos in the room's composer (docs/SESSIONS-PROTOCOL.md "Images (images-v1)"): the button beside the field, and the
// tray of thumbnails above it. Plain views over values; the container owns the picker and the encoding.

/** What the tray draws: the draft's photos and a thumbnail for each (the picture itself never leaves the container). */
class RoomPhotoTray(val draft: PhotoDraft = PhotoDraft(), val thumbs: Map<String, ImageBitmap> = emptyMap())

/**
 * The button that opens the system photo picker. Always 48 dp. Where it can't work right now it stays in place, dim,
 * and tapping it says why (the reason is also what TalkBack reads), instead of vanishing and leaving the person to guess.
 */
@Composable
fun NWPhotoButton(offer: PhotoOffer, onAdd: () -> Unit, onUnavailable: (String) -> Unit, modifier: Modifier = Modifier) {
    val reason = offer.disabledReason
    Box(
        modifier.size(48.dp).clip(CircleShape)
            .clickable(role = Role.Button, onClickLabel = if (reason == null) "Opens your photos" else "Says why photos aren't available now") {
                if (reason == null) onAdd() else onUnavailable(reason)
            }
            .semantics {
                contentDescription = PhotoOffer.ACCESSIBILITY_LABEL
                if (reason != null) stateDescription = reason
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Outlined.AddPhotoAlternate, null, modifier = Modifier.size(24.dp),
            tint = (if (reason == null) NW.Palette.textSecondary else NW.Palette.textQuiet).color,
        )
    }
}

/** The thumbnails above the field: each 64 dp with a 48 dp remove target, and one line about the tray under them. */
@Composable
fun NWPhotoTray(tray: RoomPhotoTray, onRemove: (String) -> Unit, modifier: Modifier = Modifier) {
    val draft = tray.draft
    if (draft.isEmpty) return
    Column(modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            for (item in draft.items) {
                // The × is a 48 dp target centred on the thumbnail's corner; the thumbnail is 64 dp square.
                Box(Modifier.size(width = 72.dp, height = 72.dp)) {
                    val shape = RoundedCornerShape(14.dp)
                    Box(
                        Modifier.align(Alignment.BottomStart).size(64.dp).clip(shape).background(Color.White.copy(alpha = 0.07f)).border(1.dp, Color.White.copy(alpha = 0.12f), shape),
                        contentAlignment = Alignment.Center,
                    ) {
                        val thumb = tray.thumbs[item.id]
                        if (thumb != null) Image(thumb, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                        when (val s = item.status) {
                            PhotoStatus.Encoding -> {
                                Box(Modifier.fillMaxSize().background(NW.Palette.backgroundDeep.opacity(0.45).color))
                                CircularProgressIndicator(Modifier.size(22.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                            }
                            is PhotoStatus.Failed -> {
                                Box(Modifier.fillMaxSize().background(NW.Palette.backgroundDeep.opacity(0.7).color))
                                Icon(Icons.Outlined.ErrorOutline, null, tint = NW.Palette.amber.color, modifier = Modifier.size(24.dp))
                            }
                            is PhotoStatus.Ready -> Unit
                        }
                    }
                    Box(
                        Modifier.align(Alignment.TopEnd).size(48.dp).clip(CircleShape)
                            .clickable(role = Role.Button, onClickLabel = "Removes this photo from the message") { onRemove(item.id) }
                            .semantics { contentDescription = draft.removeLabel(item.id) },
                        contentAlignment = Alignment.TopEnd,
                    ) {
                        Box(Modifier.padding(top = 0.dp, end = 0.dp).size(24.dp).clip(CircleShape).background(NW.Palette.backgroundDeep.opacity(0.92).color).border(1.dp, Color.White.copy(alpha = 0.25f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(Icons.Outlined.Close, null, tint = NW.Palette.textPrimary.color, modifier = Modifier.size(14.dp))
                        }
                    }
                }
            }
        }
        val failed = draft.failed.firstOrNull()
        val line = (failed?.status as? PhotoStatus.Failed)?.why ?: draft.summary()
        if (line != null) {
            Text(
                line, style = NW.Typo.monoMicro, color = (if (failed != null) NW.Palette.amber else NW.Palette.textQuiet).color,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
}

/** The one quiet line under the tray about how photos reach this terminal (`attach: "path"`), or why this session takes none. */
@Composable
fun NWPhotoNote(text: String, modifier: Modifier = Modifier) {
    Text(
        text, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color,
        modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp).semantics(mergeDescendants = true) {},
    )
}

/** "Up to 4 photos in a message." is said when a fifth is asked for; [PhotoLimits] holds the number. */
val photoLimitNote: String get() = "Up to ${PhotoLimits.MAX_PHOTOS} photos in a message."
