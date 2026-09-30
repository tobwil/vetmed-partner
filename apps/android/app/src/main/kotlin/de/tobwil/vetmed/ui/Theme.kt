package de.tobwil.vetmed.ui

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.FlutterDash
import androidx.compose.material.icons.rounded.Pets
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.edit

// Tag / Nacht ------------------------------------------------------------------------------------

enum class AppearanceMode(val title: String) { SYSTEM("Automatisch"), LIGHT("Tag"), DARK("Nacht") }

/** The six accent themes of the iOS app, with separate day and night values. */
enum class AccentTheme(val title: String, val lightPrimary: Color, val lightSecondary: Color, val darkPrimary: Color, val darkSecondary: Color) {
    KLINIK("Klinik", rgb(0.05, 0.47, 0.43), rgb(0.13, 0.62, 0.78), rgb(0.30, 0.82, 0.74), rgb(0.36, 0.72, 0.95)),
    OZEAN("Ozean", rgb(0.07, 0.38, 0.85), rgb(0.05, 0.66, 0.80), rgb(0.42, 0.66, 1.00), rgb(0.35, 0.88, 0.95)),
    LAVENDEL("Lavendel", rgb(0.44, 0.29, 0.84), rgb(0.84, 0.32, 0.62), rgb(0.72, 0.62, 1.00), rgb(1.00, 0.55, 0.80)),
    KORALLE("Koralle", rgb(0.86, 0.33, 0.26), rgb(0.95, 0.60, 0.15), rgb(1.00, 0.56, 0.47), rgb(1.00, 0.76, 0.36)),
    WALD("Wald", rgb(0.16, 0.50, 0.24), rgb(0.55, 0.66, 0.10), rgb(0.50, 0.83, 0.47), rgb(0.80, 0.90, 0.40)),
    GRAPHIT("Graphit", rgb(0.22, 0.26, 0.32), rgb(0.36, 0.44, 0.60), rgb(0.80, 0.84, 0.90), rgb(0.55, 0.62, 0.78));

    fun primary(dark: Boolean) = if (dark) darkPrimary else lightPrimary
    fun secondary(dark: Boolean) = if (dark) darkSecondary else lightSecondary
}

private fun rgb(r: Double, g: Double, b: Double) = Color(r.toFloat(), g.toFloat(), b.toFloat())

/** Appearance is a preference, not clinical data; plain SharedPreferences are enough. */
class AppearanceStore(context: Context) {
    private val preferences = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    var mode: AppearanceMode
        get() = preferences.getString("appearance-mode", null)?.let { runCatching { AppearanceMode.valueOf(it) }.getOrNull() } ?: AppearanceMode.SYSTEM
        set(value) = preferences.edit { putString("appearance-mode", value.name) }
    var theme: AccentTheme
        get() = preferences.getString("accent-theme", null)?.let { runCatching { AccentTheme.valueOf(it) }.getOrNull() } ?: AccentTheme.KLINIK
        set(value) = preferences.edit { putString("accent-theme", value.name) }
}

data class VetColors(val primary: Color, val secondary: Color, val dark: Boolean) {
    val gradient: Brush get() = Brush.linearGradient(listOf(primary, secondary))
    val card: Color get() = if (dark) Color(0xFF1C1C1E).copy(alpha = 0.86f) else Color.White.copy(alpha = 0.86f)
    val grouped: Color get() = if (dark) Color.Black else Color(0xFFF2F2F7)
    val hairline: Color get() = if (dark) Color.White.copy(alpha = 0.08f) else Color.Black.copy(alpha = 0.06f)
}

val LocalVetColors = staticCompositionLocalOf { VetColors(AccentTheme.KLINIK.lightPrimary, AccentTheme.KLINIK.lightSecondary, false) }
val LocalReduceMotion = staticCompositionLocalOf { false }

@Composable
fun VetMedTheme(mode: AppearanceMode, accent: AccentTheme, content: @Composable () -> Unit) {
    val dark = when (mode) { AppearanceMode.SYSTEM -> isSystemInDarkTheme(); AppearanceMode.LIGHT -> false; AppearanceMode.DARK -> true }
    val context = LocalContext.current
    val reduceMotion = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    val spec = tween<Color>(if (reduceMotion) 0 else 450, easing = FastOutSlowInEasing)
    // Every scheme color animates, so day/night and theme changes cross-fade instead of flashing.
    val primary by animateColorAsState(accent.primary(dark), spec, label = "primary")
    val secondary by animateColorAsState(accent.secondary(dark), spec, label = "secondary")
    val background by animateColorAsState(if (dark) Color.Black else Color(0xFFF2F2F7), spec, label = "background")
    val surface by animateColorAsState(if (dark) Color(0xFF1C1C1E) else Color.White, spec, label = "surface")
    val onSurface by animateColorAsState(if (dark) Color.White else Color.Black, spec, label = "onSurface")
    val variant by animateColorAsState(if (dark) Color(0xFFEBEBF5).copy(alpha = 0.6f) else Color(0xFF3C3C43).copy(alpha = 0.62f), spec, label = "variant")
    val base: ColorScheme = if (dark) darkColorScheme() else lightColorScheme()
    val scheme = base.copy(
        primary = primary, onPrimary = Color.White, secondary = secondary, onSecondary = Color.White, tertiary = secondary,
        primaryContainer = primary.copy(alpha = 0.16f), onPrimaryContainer = onSurface,
        secondaryContainer = primary.copy(alpha = 0.16f), onSecondaryContainer = onSurface,
        background = background, onBackground = onSurface, surface = surface, onSurface = onSurface,
        surfaceVariant = surface, onSurfaceVariant = variant,
        surfaceContainerLowest = surface, surfaceContainerLow = surface, surfaceContainer = surface,
        surfaceContainerHigh = surface, surfaceContainerHighest = if (dark) Color(0xFF2C2C2E) else Color(0xFFE5E5EA),
        outline = variant.copy(alpha = 0.4f), outlineVariant = onSurface.copy(alpha = 0.08f),
    )
    CompositionLocalProvider(LocalVetColors provides VetColors(primary, secondary, dark), LocalReduceMotion provides reduceMotion) {
        MaterialTheme(colorScheme = scheme) {
            // Screens draw on a transparent Scaffold over the ambient background; text must still follow day/night.
            CompositionLocalProvider(LocalContentColor provides scheme.onBackground, content = content)
        }
    }
}

// Hintergrund und Bausteine -----------------------------------------------------------------------

/** Soft, slowly drifting colour field in the current theme; still when animations are off. */
@Composable
fun AmbientBackground(modifier: Modifier = Modifier) {
    val colors = LocalVetColors.current
    val reduceMotion = LocalReduceMotion.current
    val drift = if (reduceMotion) 0f else {
        val transition = rememberInfiniteTransition(label = "ambient")
        val value by transition.animateFloat(-1f, 1f, infiniteRepeatable(tween(9000, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "drift")
        value
    }
    val strong = colors.primary.copy(alpha = if (colors.dark) 0.30f else 0.18f)
    val soft = colors.secondary.copy(alpha = if (colors.dark) 0.20f else 0.12f)
    Canvas(modifier.fillMaxSize().background(colors.grouped)) {
        fun blob(color: Color, x: Float, y: Float, radius: Float) = drawCircle(
            Brush.radialGradient(listOf(color, Color.Transparent), center = Offset(size.width * x, size.height * y), radius = size.maxDimension * radius),
            radius = size.maxDimension * radius, center = Offset(size.width * x, size.height * y),
        )
        blob(strong, 0.05f + drift * 0.05f, 0.02f, 0.55f)
        blob(soft, 0.62f - drift * 0.08f, 0.08f, 0.45f)
        blob(strong.copy(alpha = strong.alpha * 0.6f), 1.0f, 0.45f + drift * 0.06f, 0.45f)
        blob(soft, 0.05f, 0.62f - drift * 0.05f, 0.45f)
        blob(soft.copy(alpha = soft.alpha * 0.8f), 0.95f + drift * 0.03f, 1.0f, 0.55f)
    }
}

/** Rounded content card on the ambient background. */
fun Modifier.vetCard(colors: VetColors, shape: Shape = RoundedCornerShape(22.dp), padding: Dp = 16.dp): Modifier =
    this.clip(shape).background(colors.card).border(1.dp, colors.hairline, shape).padding(padding)

/** Gently scales while pressed, like the iOS PressableButtonStyle. */
@Composable
fun Modifier.pressable(interaction: MutableInteractionSource): Modifier {
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, label = "press")
    return this.scale(scale)
}

@Composable
fun GradientIcon(icon: ImageVector, modifier: Modifier = Modifier, size: Dp = 44.dp) {
    val colors = LocalVetColors.current
    Box(
        modifier.size(size).shadow(6.dp, RoundedCornerShape(size * 0.32f), ambientColor = colors.primary, spotColor = colors.primary)
            .clip(RoundedCornerShape(size * 0.32f)).background(colors.gradient),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.5f)) }
}

/** Mirrors `SpeciesIcon` on iOS as far as Material symbols allow: birds get their own symbol, all else a paw. */
object SpeciesIcon {
    fun forSpecies(species: String): ImageVector {
        val value = species.lowercase()
        return if (listOf("vogel", "papagei", "sittich", "huhn", "bird").any { value.contains(it) }) Icons.Rounded.FlutterDash else Icons.Rounded.Pets
    }
}

object Greeting {
    fun text(hour: Int): String = when (hour) { in 5..10 -> "Guten Morgen"; in 11..16 -> "Guten Tag"; in 17..21 -> "Guten Abend"; else -> "Gute Nacht" }
}

@Composable
fun rememberAppearanceStore(): AppearanceStore { val context = LocalContext.current; return remember { AppearanceStore(context) } }

internal fun Modifier.screenPadding() = this.padding(horizontal = 20.dp)
