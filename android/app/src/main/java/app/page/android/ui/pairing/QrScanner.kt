package app.page.android.ui.pairing

import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

/**
 * The camera preview with a QR decoder on every frame: CameraX for the
 * camera, ZXing core for decoding, entirely on the device (no Google Play
 * services). [onCode] is called on the main thread, at most once per two
 * seconds for the same code (the camera reports it many times a second).
 */
@Composable
fun QrScanner(onCode: (String) -> Unit, onFailure: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnCode = rememberUpdatedState(onCode)
    val currentOnFailure = rememberUpdatedState(onFailure)
    val executor = remember { Executors.newSingleThreadExecutor() }
    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            // A TextureView draws inside the Compose hierarchy; a SurfaceView's
            // hole would be covered by the dialog's own background.
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }

    DisposableEffect(lifecycleOwner) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        var lastCode: String? = null
        var lastCodeAt = 0L
        providerFuture.addListener({
            try {
                val p = providerFuture.get()
                provider = p
                val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                val reader = MultiFormatReader().apply {
                    setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
                }
                analysis.setAnalyzer(executor) { image ->
                    val text = decode(reader, image)
                    if (text != null) {
                        ContextCompat.getMainExecutor(context).execute {
                            val now = System.currentTimeMillis()
                            if (text == lastCode && now - lastCodeAt < 2000) return@execute
                            lastCode = text
                            lastCodeAt = now
                            currentOnCode.value(text)
                        }
                    }
                }
                p.unbindAll()
                p.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.w("QrScanner", "camera failed: ${e.javaClass.simpleName}")
                currentOnFailure.value("The camera couldn't be started. Check camera access for Page in Settings, or enter the code manually.")
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            provider?.unbindAll()
        }
    }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }

    AndroidView(factory = { previewView }, modifier = modifier)
}

/** Decodes the frame's luminance (Y) plane; null when no QR code is found. */
private fun decode(reader: MultiFormatReader, image: ImageProxy): String? {
    try {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val width = image.width
        val height = image.height
        val data = ByteArray(rowStride * height)
        buffer.rewind()
        buffer.get(data, 0, minOf(data.size, buffer.remaining()))
        val source = PlanarYUVLuminanceSource(data, rowStride, height, 0, 0, width, height, false)
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (_: NotFoundException) {
            // Codes printed light-on-dark (dark-mode QR) need the inverted image.
            try {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source.invert()))).text
            } catch (_: Exception) {
                null
            }
        } finally {
            reader.reset()
        }
    } catch (_: Exception) {
        return null
    } finally {
        image.close()
    }
}
