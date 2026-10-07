// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.pairing

import android.util.Size
import androidx.camera.core.*
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@Composable
fun PairingCamera(onCode: (String) -> Unit, onUnavailable: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val latest by rememberUpdatedState(onCode)
    val unavailable by rememberUpdatedState(onUnavailable)
    val preview = remember { PreviewView(context) }
    AndroidView(factory = { preview }, modifier = Modifier.fillMaxWidth().height(280.dp))
    DisposableEffect(owner) {
        val worker = Executors.newSingleThreadExecutor()
        val disposed = AtomicBoolean(false)
        val accepted = AtomicBoolean(false)
        var luminance = byteArrayOf()
        var lastFrame = 0L
        val reader =
            MultiFormatReader().apply {
                setHints(
                    mapOf(
                        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                        DecodeHintType.TRY_HARDER to true,
                    )
                )
            }
        val future = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        var useCases: List<UseCase> = emptyList()
        future.addListener(
            {
                if (disposed.get()) return@addListener
                try {
                    val camera = future.get()
                    provider = camera
                    val p =
                        Preview.Builder().build().also {
                            it.surfaceProvider = preview.surfaceProvider
                        }
                    val a =
                        ImageAnalysis.Builder()
                            .setResolutionSelector(
                                ResolutionSelector.Builder()
                                    .setResolutionStrategy(
                                        ResolutionStrategy(
                                            Size(640, 480),
                                            ResolutionStrategy
                                                .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                        )
                                    )
                                    .build()
                            )
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                    a.setAnalyzer(worker) { image ->
                        try {
                            val now = System.nanoTime()
                            if (
                                !accepted.get() && !disposed.get() && now - lastFrame >= 200_000_000
                            ) {
                                lastFrame = now
                                val plane = image.planes[0]
                                val buffer = plane.buffer.duplicate()
                                val w = image.width
                                val h = image.height
                                if (luminance.size != w * h) luminance = ByteArray(w * h)
                                for (y in 0 until h) {
                                    if (plane.pixelStride == 1) {
                                        buffer.position(y * plane.rowStride)
                                        buffer.get(luminance, y * w, w)
                                    } else {
                                        for (x in 0 until w) luminance[y * w + x] =
                                            buffer.get(y * plane.rowStride + x * plane.pixelStride)
                                    }
                                }
                                // QR finder patterns support rotated symbols; no extra full-frame
                                // copies.
                                val source =
                                    PlanarYUVLuminanceSource(luminance, w, h, 0, 0, w, h, false)
                                val result =
                                    reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))
                                if (
                                    result.text.startsWith("anice:") &&
                                        accepted.compareAndSet(false, true)
                                )
                                    ContextCompat.getMainExecutor(context).execute {
                                        if (!disposed.get()) latest(result.text)
                                    }
                            }
                        } catch (_: Exception) {
                            /* Continue scanning; no frame or decoder detail is retained. */
                        } finally {
                            luminance.fill(0)
                            reader.reset()
                            image.close()
                        }
                    }
                    useCases = listOf(p, a)
                    camera.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, p, a)
                } catch (_: Exception) {
                    if (!disposed.get()) unavailable()
                }
            },
            ContextCompat.getMainExecutor(context),
        )
        onDispose {
            disposed.set(true)
            provider?.unbind(*useCases.toTypedArray())
            worker.shutdown()
        }
    }
}
