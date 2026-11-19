// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas as AndroidCanvas
import android.graphics.Paint
import android.graphics.RectF
import android.opengl.Matrix
import android.view.Choreographer
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import com.google.android.filament.Box as FilamentBox
import com.google.android.filament.Camera
import com.google.android.filament.Engine
import com.google.android.filament.EntityManager
import com.google.android.filament.Filament
import com.google.android.filament.IndirectLight
import com.google.android.filament.LightManager
import com.google.android.filament.Renderer
import com.google.android.filament.Scene
import com.google.android.filament.SwapChain
import com.google.android.filament.Texture
import com.google.android.filament.View
import com.google.android.filament.Viewport
import com.google.android.filament.android.UiHelper
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.Gltfio
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** What the live RayNeo iO model acts out; the Mac GlassesModelView uses the same poses and constants. */
internal enum class GlassesPose { Resting, Connecting, Connected }

internal fun LinkPhase.glassesPose() =
    when (this) {
        LinkPhase.FULL -> GlassesPose.Connected
        LinkPhase.SCANNING, LinkPhase.CONNECTING, LinkPhase.BLE_ONLY, LinkPhase.RETRY_WAIT -> GlassesPose.Connecting
        LinkPhase.DISCONNECTED, LinkPhase.CLOSING -> GlassesPose.Resting
    }

/**
 * assets/models/rayneo-io.glb rendered live with Filament over a soft contact shadow. Resting folds the temples,
 * connecting unfolds them with a blinking status light, connected powers on the waveguide display. It never moves
 * on its own; drag to turn it, and a flick spins it before it settles back.
 */
@Composable
internal fun GlassesArtwork(modifier: Modifier = Modifier, pose: GlassesPose = GlassesPose.Connected) {
    val shadow = tokens.illustrationShadow
    Box(modifier.semantics { contentDescription = "RayNeo iO 智能眼镜" }) {
        Canvas(Modifier.matchParentSize()) {
            val center = Offset(size.width / 2, size.height * 0.86f)
            scale(1f, 0.09f, center) {
                drawCircle(
                    Brush.radialGradient(listOf(shadow, Color.Transparent), center, size.width * 0.32f),
                    size.width * 0.32f,
                    center,
                )
            }
        }
        // Devices whose GLES driver rejects Filament (engine or swap chain) keep a static mark instead of failing the screen.
        var failed by remember { mutableStateOf(false) }
        if (failed) Image(painterResource(R.drawable.ic_brand_mark), null, Modifier.align(Alignment.Center).fillMaxSize(0.45f))
        else AndroidView(
            factory = { context -> runCatching<android.view.View> { GlassesStageView(context) { failed = true } }.getOrElse { failed = true; android.view.View(context) } },
            modifier = Modifier.matchParentSize(),
            update = { (it as? GlassesStageView)?.pose = pose },
            onRelease = { (it as? GlassesStageView)?.release() },
        )
    }
}

/** Damped spring stepped once per frame. */
private class Spring(var value: Float) {
    var velocity = 0f

    fun step(target: Float, stiffness: Float, damping: Float, dt: Float) {
        velocity += (stiffness * (target - value) - 2 * damping * sqrt(stiffness) * velocity) * dt
        value += velocity * dt
    }
}

private object GlassesMotion {
    const val REST_YAW = -0.55f
    const val FOLD_ANGLE = 1.48f
    val phosphor = floatArrayOf(0x7C / 255f, 0xF5 / 255f, 0xC0 / 255f)

    /**
     * The model never moves on its own: it holds the resting angle and only state changes animate. Connecting is
     * the one ongoing signal (blinking status light, flickering display) while the link is being set up.
     */
    class Target(val fold: Float, val glow: Float, val indicator: Float)

    fun target(pose: GlassesPose, t: Float) =
        when (pose) {
            GlassesPose.Resting -> Target(1f, 0f, 0f)
            GlassesPose.Connecting -> Target(0f, 0.4f + 0.3f * sin(t * 3.2f), if (sin(t * 7f) > 0) 1f else 0.15f)
            GlassesPose.Connected -> Target(0f, 1f, 1f)
        }

    /** Soft studio: dark floor, bright overhead softbox, a key strip on the left and a rim strip behind right. */
    fun radiance(x: Float, y: Float, z: Float): Float {
        fun lobe(cx: Float, cy: Float, cz: Float, width: Float, strength: Float): Float {
            val n = sqrt(cx * cx + cy * cy + cz * cz)
            return strength * exp(-(1 - (x * cx + y * cy + z * cz) / n) / (width * width))
        }
        val horizon = min(1f, max(0f, (y + 0.25f) / 0.9f))
        return 0.05f + 0.3f * horizon * horizon + lobe(0f, 0.9f, 0.45f, 0.42f, 3.2f) +
            lobe(-0.85f, 0.25f, 0.45f, 0.28f, 2.2f) + lobe(0.8f, 0.35f, -0.5f, 0.3f, 1.6f)
    }

    /** The waveguide image: phosphor "text" lines and a status dot on a dark lens panel, transparent elsewhere. */
    fun displayPng(): ByteArray {
        val bitmap = Bitmap.createBitmap(240, 120, Bitmap.Config.ARGB_8888)
        val canvas = AndroidCanvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val green = android.graphics.Color.rgb(0x7C, 0xF5, 0xC0)
        paint.color = android.graphics.Color.argb(184, 0x0B, 0x0F, 0x0D)
        canvas.drawRoundRect(RectF(6f, 6f, 234f, 114f), 18f, 18f, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 2f
        paint.color = green
        paint.alpha = 90
        canvas.drawRoundRect(RectF(7f, 7f, 233f, 113f), 17f, 17f, paint)
        paint.style = Paint.Style.FILL
        paint.alpha = 255
        canvas.drawRoundRect(RectF(30f, 34f, 150f, 48f), 7f, 7f, paint)
        canvas.drawOval(RectF(186f, 32f, 204f, 50f), paint)
        paint.alpha = 153
        canvas.drawRoundRect(RectF(30f, 66f, 206f, 78f), 6f, 6f, paint)
        canvas.drawRoundRect(RectF(30f, 88f, 122f, 100f), 6f, 6f, paint)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }
}

@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
private class GlassesStageView(context: Context, private val onFailed: () -> Unit) : TextureView(context), Choreographer.FrameCallback {
    /** The first pose is shown directly, so recreating the view does not replay the unfold; later changes animate. */
    var pose = GlassesPose.Resting
        set(value) {
            if (!posed) {
                posed = true
                GlassesMotion.target(value, 0f).let {
                    fold.value = it.fold
                    glow.value = it.glow
                }
            } else if (value == GlassesPose.Connected && field != GlassesPose.Connected) flash = 1f
            val changed = value != field
            field = value
            if (changed) wake()
        }
    private var posed = false

    private val engine: Engine
    private val renderer: Renderer
    private val scene: Scene
    private val view: View
    private val cameraEntity = EntityManager.get().create()
    private val camera: Camera
    private val light = EntityManager.get().create()
    private val environment: Texture
    private val indirectLight: IndirectLight
    private val materials: UbershaderProvider
    private val loader: AssetLoader
    private val resourceLoader: ResourceLoader
    private val glasses: FilamentAsset
    private val display: FilamentAsset
    private val uiHelper = UiHelper(UiHelper.ContextErrorPolicy.DONT_CHECK)
    private var swapChain: SwapChain? = null

    private val temples = mutableListOf<Pair<Int, FloatArray>>() // entity, (hinge x, y, z, folded angle)
    private val displayNodes = mutableListOf<Pair<Int, FloatArray>>() // entity, position
    private val placement = FloatArray(4) // front centre x, y, z and scale

    private val fold = Spring(1f)
    private val glow = Spring(0f)
    private val yaw = Spring(GlassesMotion.REST_YAW)
    private val pitch = Spring(0f)
    private var flash = 0f
    private var clock = 0f
    private var lastFrame = 0L
    private var dragging = false
    private var downPoint = Offset.Zero
    private var lastTouch = Triple(0f, 0f, 0L)
    private val touchSlop = android.view.ViewConfiguration.get(context).scaledTouchSlop
    private var visible = false
    private var looping = false
    private var settledFrames = 0
    private val matrix = FloatArray(16)

    init {
        isOpaque = false
        engine = Engine.create()
        renderer = engine.createRenderer()
        renderer.clearOptions = renderer.clearOptions.apply {
            clear = true
            clearColor = doubleArrayOf(0.0, 0.0, 0.0, 0.0)
        }
        scene = engine.createScene()
        camera = engine.createCamera(cameraEntity)
        view = engine.createView()
        view.scene = scene
        view.camera = camera
        view.blendMode = View.BlendMode.TRANSLUCENT
        view.antiAliasing = View.AntiAliasing.FXAA
        view.multiSampleAntiAliasingOptions = view.multiSampleAntiAliasingOptions.apply {
            enabled = true
            sampleCount = 4
        }

        LightManager.Builder(LightManager.Type.DIRECTIONAL)
            .color(1f, 0.98f, 0.95f)
            .intensity(90_000f)
            .direction(0.45f, -0.8f, -0.4f)
            .build(engine, light)
        scene.addEntity(light)
        environment = studioCubemap()
        indirectLight = IndirectLight.Builder().reflections(environment).irradiance(3, studioIrradiance()).intensity(60_000f).build(engine)
        scene.indirectLight = indirectLight

        materials = UbershaderProvider(engine)
        loader = AssetLoader(engine, materials, EntityManager.get())
        resourceLoader = ResourceLoader(engine)
        glasses = load(context.assets.open("models/rayneo-io.glb").use { it.readBytes() })
        rig()
        display = load(displayGlb())
        val tm = engine.transformManager
        tm.setParent(tm.getInstance(display.root), tm.getInstance(glasses.root))
        displayNodes.forEachIndexed { index, node -> displayNodes[index] = display.getFirstEntityByName(if (index == 0) "HUD L" else "HUD R") to node.second }

        uiHelper.isOpaque = false
        uiHelper.renderCallback = object : UiHelper.RendererCallback {
            override fun onNativeWindowChanged(surface: Surface) {
                swapChain?.let { engine.destroySwapChain(it) }
                swapChain = runCatching { engine.createSwapChain(surface, uiHelper.swapChainFlags) }.getOrNull()
                if (swapChain == null) post(onFailed) else wake()
            }

            override fun onDetachedFromSurface() {
                swapChain?.let {
                    engine.destroySwapChain(it)
                    engine.flushAndWait()
                    swapChain = null
                }
            }

            override fun onResized(width: Int, height: Int) {
                view.viewport = Viewport(0, 0, width, height)
                val aspect = width.toDouble() / height
                // Constant horizontal field of view (~29.6 degrees) so the frame fills the hero card at any width.
                camera.setLensProjection(45.4 * aspect, aspect, 0.1, 40.0)
                wake()
            }
        }
        uiHelper.attachTo(this)
        camera.lookAt(0.0, 1.05, 5.6, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)

        setOnTouchListener { _, event -> touch(event) }
    }

    private fun load(bytes: ByteArray): FilamentAsset {
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes).flip()
        val asset = loader.createAsset(buffer)!!
        resourceLoader.loadResources(asset)
        asset.releaseSourceData()
        scene.addEntities(asset.entities)
        return asset
    }

    private fun bounds(name: String): FilamentBox {
        val rm = engine.renderableManager
        return FilamentBox().also { rm.getAxisAlignedBoundingBox(rm.getInstance(glasses.getFirstEntityByName(name)), it) }
    }

    /** Scales the frame to a width of 2 units and finds the hinges, lenses and status light. */
    private fun rig() {
        val front = bounds("Continuous crown-panto frame")
        placement[0] = front.center[0]
        placement[1] = front.center[1]
        placement[2] = front.center[2]
        placement[3] = 1f / front.halfExtent[0]
        // Each temple pivots on its hinge knuckle about the vertical axis; signs fold both inward.
        for ((side, angle) in listOf("R" to -GlassesMotion.FOLD_ANGLE, "L" to GlassesMotion.FOLD_ANGLE - 0.06f)) {
            val hinge = bounds("$side hinge knuckle").center
            temples += glasses.getFirstEntityByName("$side temple assembly") to floatArrayOf(hinge[0], hinge[1], hinge[2], angle)
        }
        for (side in listOf("L", "R")) {
            val lens = bounds("$side clear lens")
            // Just in front of the lens (model front is +z), a little above centre.
            displayNodes += 0 to floatArrayOf(lens.center[0], lens.center[1] + lens.halfExtent[1] * 0.16f,
                lens.center[2] + lens.halfExtent[2] + 0.0008f, lens.halfExtent[0] * 1.24f, lens.halfExtent[1] * 0.72f)
        }
    }

    /** A two-node glTF holding the waveguide panels: unlit, alpha-blended quads textured with the display image. */
    private fun displayGlb(): ByteArray {
        val w = displayNodes[0].second[3] / 2
        val h = displayNodes[0].second[4] / 2
        val geometry = ByteBuffer.allocate(4 * 12 + 4 * 8 + 6 * 2 + 4).order(ByteOrder.LITTLE_ENDIAN)
        floatArrayOf(-w, -h, 0f, w, -h, 0f, w, h, 0f, -w, h, 0f).forEach { geometry.putFloat(it) }
        floatArrayOf(0f, 1f, 1f, 1f, 1f, 0f, 0f, 0f).forEach { geometry.putFloat(it) }
        shortArrayOf(0, 1, 2, 0, 2, 3).forEach { geometry.putShort(it) }
        geometry.putShort(0)
        val png = GlassesMotion.displayPng()
        val binLength = (geometry.capacity() + png.size + 3) / 4 * 4
        val nodes = displayNodes.mapIndexed { index, node ->
            val p = node.second
            """{"name":"HUD ${if (index == 0) "L" else "R"}","mesh":0,"translation":[${p[0]},${p[1]},${p[2]}]}"""
        }.joinToString(",")
        val json = """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],"nodes":[$nodes],
            "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
            "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicFactor":0,"roughnessFactor":1},
            "alphaMode":"BLEND","extensions":{"KHR_materials_unlit":{}}}],"extensionsUsed":["KHR_materials_unlit"],
            "textures":[{"source":0,"sampler":0}],"samplers":[{"magFilter":9729,"minFilter":9729}],
            "images":[{"bufferView":3,"mimeType":"image/png"}],
            "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[${-w},${-h},0],"max":[$w,$h,0]},
            {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},{"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}],
            "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},
            {"buffer":0,"byteOffset":80,"byteLength":12},{"buffer":0,"byteOffset":${geometry.capacity()},"byteLength":${png.size}}],
            "buffers":[{"byteLength":$binLength}]}""".toByteArray()
        val jsonLength = (json.size + 3) / 4 * 4
        return ByteBuffer.allocate(12 + 8 + jsonLength + 8 + binLength).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x46546C67); putInt(2); putInt(capacity())
            putInt(jsonLength); putInt(0x4E4F534A); put(json); repeat(jsonLength - json.size) { put(0x20) }
            putInt(binLength); putInt(0x004E4942); put(geometry.array()); put(png); repeat(binLength - geometry.capacity() - png.size) { put(0) }
        }.array()
    }

    /** Studio cubemap; Filament's GGX prefilter derives the rougher reflection mips from the base level. */
    private fun studioCubemap(): Texture {
        val size = 64
        val texture = Texture.Builder().width(size).height(size).levels(7).sampler(Texture.Sampler.SAMPLER_CUBEMAP)
            .format(Texture.InternalFormat.RGB16F).build(engine)
        val faceBytes = size * size * 12
        val buffer = ByteBuffer.allocateDirect(6 * faceBytes).order(ByteOrder.nativeOrder())
        for (face in 0 until 6) for (row in 0 until size) for (column in 0 until size) {
            val u = 2 * (column + 0.5f) / size - 1
            val v = 2 * (row + 0.5f) / size - 1
            val (x, y, z) = when (face) {
                0 -> Triple(1f, -v, -u)
                1 -> Triple(-1f, -v, u)
                2 -> Triple(u, 1f, v)
                3 -> Triple(u, -1f, -v)
                4 -> Triple(u, -v, 1f)
                else -> Triple(-u, -v, -1f)
            }
            val n = sqrt(x * x + y * y + z * z)
            val c = GlassesMotion.radiance(x / n, y / n, z / n)
            buffer.putFloat(c).putFloat(c).putFloat(c * 1.03f)
        }
        buffer.flip()
        texture.generatePrefilterMipmap(engine, Texture.PixelBufferDescriptor(buffer, Texture.Format.RGB, Texture.Type.FLOAT),
            IntArray(6) { it * faceBytes }, Texture.PrefilterOptions())
        return texture
    }

    /**
     * Nine irradiance coefficients in Filament's pre-scaled basis, fitted by least squares to the cosine-weighted
     * studio radiance (divided by pi) over a Fibonacci sphere of normals.
     */
    private fun studioIrradiance(): FloatArray {
        fun sphere(count: Int) = List(count) { i ->
            val y = 1 - 2 * (i + 0.5f) / count
            val r = sqrt(1 - y * y)
            val phi = i * PI.toFloat() * (3 - sqrt(5f))
            floatArrayOf(cos(phi) * r, y, sin(phi) * r)
        }
        val directions = sphere(1024)
        val light = directions.map { GlassesMotion.radiance(it[0], it[1], it[2]) }
        fun basis(n: FloatArray) = floatArrayOf(1f, n[1], n[2], n[0], n[1] * n[0], n[1] * n[2], 3 * n[2] * n[2] - 1, n[2] * n[0], n[0] * n[0] - n[1] * n[1])
        val normal = Array(9) { DoubleArray(10) }
        for (n in sphere(256)) {
            var irradiance = 0f
            directions.forEachIndexed { i, d -> irradiance += light[i] * max(0f, n[0] * d[0] + n[1] * d[1] + n[2] * d[2]) }
            irradiance *= 4f / directions.size
            val b = basis(n)
            for (r in 0 until 9) {
                for (c in 0 until 9) normal[r][c] += (b[r] * b[c]).toDouble()
                normal[r][9] += (b[r] * irradiance).toDouble()
            }
        }
        for (p in 0 until 9) {
            val pivot = (p until 9).maxBy { abs(normal[it][p]) }
            normal[p] = normal[pivot].also { normal[pivot] = normal[p] }
            for (r in 0 until 9) if (r != p) {
                val f = normal[r][p] / normal[p][p]
                for (c in p..9) normal[r][c] -= f * normal[p][c]
            }
        }
        return FloatArray(27) { normal[it / 3][9].toFloat() / normal[it / 3][it / 3].toFloat() * if (it % 3 == 2) 1.03f else 1f }
    }

    private fun touch(event: MotionEvent): Boolean {
        val density = context.resources.displayMetrics.density
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                wake()
                downPoint = Offset(event.x, event.y)
                lastTouch = Triple(event.x, event.y, event.eventTime)
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging) {
                    // Claim the gesture only once it is clearly horizontal; vertical swipes stay with the list.
                    val total = Offset(event.x, event.y) - downPoint
                    if (total.getDistance() < touchSlop) return true
                    if (abs(total.y) >= abs(total.x)) return false
                    dragging = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                    lastTouch = Triple(event.x, event.y, event.eventTime)
                    return true
                }
                val dx = (event.x - lastTouch.first) / density * 0.012f
                val dy = (event.y - lastTouch.second) / density * 0.008f
                val dt = max(event.eventTime - lastTouch.third, 4L) / 1000f
                yaw.value += dx
                yaw.velocity = dx / dt
                pitch.value = min(0.45f, max(-0.45f, pitch.value + dy))
                pitch.velocity = dy / dt
                lastTouch = Triple(event.x, event.y, event.eventTime)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> dragging = false
        }
        return true
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        visible = isVisible
        if (isVisible) wake()
        else if (looping) {
            looping = false
            Choreographer.getInstance().removeFrameCallback(this)
        }
    }

    /** Runs the frame loop until the model settles; pose changes, touches and new surfaces restart it. */
    private fun wake() {
        settledFrames = 0
        if (!visible || looping) return
        looping = true
        lastFrame = 0L
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!looping) return
        val dt = if (lastFrame == 0L) 0f else min((frameTimeNanos - lastFrame) / 1e9f, 1 / 30f)
        lastFrame = frameTimeNanos
        clock += dt
        val settled = animate(dt)
        val chain = swapChain
        val rendered = chain != null && uiHelper.isReadyToRender && renderer.beginFrame(chain, frameTimeNanos)
        if (rendered) {
            renderer.render(view)
            renderer.endFrame()
        }
        settledFrames = if (settled && rendered) settledFrames + 1 else 0
        if (settledFrames >= 2) looping = false else Choreographer.getInstance().postFrameCallback(this)
    }

    /** Steps the springs and pushes transforms; returns true once nothing is moving. */
    private fun animate(dt: Float): Boolean {
        val still = !ValueAnimator.areAnimatorsEnabled()
        val target = GlassesMotion.target(pose, if (still) 0f else clock)
        if (still) {
            fold.value = target.fold
            glow.value = target.glow
            flash = 0f
        } else {
            fold.step(target.fold, 26f, 0.9f, dt)
            glow.step(target.glow, 60f, 1f, dt)
            flash = max(0f, flash - dt * 2.2f)
        }
        // Settle on the nearest full turn of the resting angle so a flick spins and lands cleanly.
        val turn = 2 * PI.toFloat()
        val rest = GlassesMotion.REST_YAW + turn * ((yaw.value - GlassesMotion.REST_YAW) / turn).roundToInt()
        if (!dragging) {
            yaw.step(rest, if (still) 60f else 9f, 0.75f, dt)
            pitch.step(0f, 18f, 0.8f, dt)
        }
        val settled = !dragging && pose != GlassesPose.Connecting && flash == 0f &&
            listOf(fold.value - target.fold, glow.value - target.glow, yaw.value - rest, pitch.value,
                fold.velocity, glow.velocity, yaw.velocity, pitch.velocity).all { abs(it) < 0.0005f }
        if (settled) {
            fold.value = target.fold
            glow.value = target.glow
            yaw.value = GlassesMotion.REST_YAW
            pitch.value = 0f
            listOf(fold, glow, yaw, pitch).forEach { it.velocity = 0f }
        }
        val tm = engine.transformManager
        val s = placement[3]
        Matrix.setIdentityM(matrix, 0)
        Matrix.rotateM(matrix, 0, Math.toDegrees(pitch.value.toDouble()).toFloat(), 1f, 0f, 0f)
        Matrix.rotateM(matrix, 0, Math.toDegrees(yaw.value.toDouble()).toFloat(), 0f, 1f, 0f)
        Matrix.translateM(matrix, 0, -placement[0] * s, -placement[1] * s, -placement[2] * s + 0.6f)
        Matrix.scaleM(matrix, 0, s, s, s)
        tm.setTransform(tm.getInstance(glasses.root), matrix)

        val folded = min(1f, max(0f, fold.value))
        for ((entity, hinge) in temples) {
            Matrix.setIdentityM(matrix, 0)
            Matrix.translateM(matrix, 0, hinge[0], hinge[1], hinge[2])
            Matrix.rotateM(matrix, 0, Math.toDegrees((hinge[3] * folded).toDouble()).toFloat(), 0f, 1f, 0f)
            Matrix.translateM(matrix, 0, -hinge[0], -hinge[1], -hinge[2])
            tm.setTransform(tm.getInstance(entity), matrix)
        }

        // The display opens like a CRT on power-on: a thin bright line that expands to the full panel.
        val rm = engine.renderableManager
        val opacity = min(1f, max(0f, glow.value))
        for ((entity, position) in displayNodes) {
            Matrix.setIdentityM(matrix, 0)
            Matrix.translateM(matrix, 0, position[0], position[1], position[2])
            Matrix.scaleM(matrix, 0, 1f, 1 - 0.85f * flash * flash, 1f)
            tm.setTransform(tm.getInstance(entity), matrix)
            rm.getMaterialInstanceAt(rm.getInstance(entity), 0).setParameter("baseColorFactor", opacity, opacity, opacity, opacity)
        }
        val indicator = rm.getMaterialInstanceAt(rm.getInstance(glasses.getFirstEntityByName("R status indicator")), 0)
        val led = target.indicator * 4f
        indicator.setParameter("baseColorFactor", 0.03f, 0.03f, 0.03f, 1f)
        indicator.setParameter("emissiveFactor", GlassesMotion.phosphor[0] * led, GlassesMotion.phosphor[1] * led, GlassesMotion.phosphor[2] * led)
        return settled
    }

    fun release() {
        looping = false
        Choreographer.getInstance().removeFrameCallback(this)
        uiHelper.detach()
        engine.flushAndWait()
        loader.destroyAsset(display)
        loader.destroyAsset(glasses)
        materials.destroyMaterials()
        materials.destroy()
        loader.destroy()
        resourceLoader.destroy()
        engine.destroyIndirectLight(indirectLight)
        engine.destroyTexture(environment)
        engine.destroyEntity(light)
        engine.destroyRenderer(renderer)
        engine.destroyView(view)
        engine.destroyScene(scene)
        engine.destroyCameraComponent(cameraEntity)
        EntityManager.get().destroy(cameraEntity)
        EntityManager.get().destroy(light)
        engine.destroy()
    }

    companion object {
        init {
            Filament.init()
            Gltfio.init()
        }
    }
}
