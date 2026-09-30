package de.tobwil.vetmed.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChatBubble
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.PendingActions
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.germanDateTime
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StartScreen(model: AppViewModel, nav: NavHostController) {
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val colors = LocalVetColors.current
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val recent = remember(document) {
        document.cases.filter { it.archivedAt == null }.flatMap { item -> item.encounters.map { item to it } }
            .sortedByDescending { it.second.lastActivity }.take(5)
    }
    val reportCount = remember(document) { document.cases.sumOf { item -> item.encounters.sumOf { it.reports.size } } }
    val openReviews = remember(document) { document.cases.flatMap { it.encounters }.count { it.reports.lastOrNull()?.approvedAt == null && it.reports.isNotEmpty() } }

    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = {
                LargeTopAppBar(
                    title = { Text("VetMed", fontWeight = FontWeight.Bold) },
                    actions = {
                        DayNightToggle()
                        IconButton(onClick = { nav.navigate(SettingsRoute) }) { Icon(Icons.Rounded.Settings, "Einstellungen") }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)),
                    scrollBehavior = scroll,
                )
            },
        ) { padding ->
            LazyColumn(
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding(), bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { Appear(0) { Header() } }
                item {
                    Appear(1) {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            StatTile(document.cases.size, "Fälle", Icons.Rounded.Folder, Modifier.weight(1f)) { nav.navigate(CasesRoute) }
                            StatTile(openReviews, "Zu prüfen", Icons.Rounded.PendingActions, Modifier.weight(1f)) { nav.navigate(CasesRoute) }
                            StatTile(reportCount, "Berichte", Icons.Rounded.Description, Modifier.weight(1f)) { nav.navigate(CasesRoute) }
                        }
                    }
                }
                item {
                    Appear(2) {
                        HeroCard(enabled = !busy) {
                            model.newEncounter { nav.navigate(EncounterRoute(it.caseID, it.encounterID)) }
                        }
                    }
                }
                item {
                    Appear(3) {
                        ActionCard("Frage stellen", "Chat mit Bildern und Befunden folgt auf Android", Icons.Rounded.ChatBubble) { nav.navigate(ChatRoute) }
                    }
                }
                item { Appear(4) { Text("Weiterarbeiten", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp)) } }
                if (recent.isEmpty()) item {
                    Appear(5) {
                        Row(Modifier.fillMaxWidth().vetCard(colors), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.AutoAwesome, null, tint = colors.primary)
                            Spacer(Modifier.width(14.dp))
                            Text("Deine letzten Diktate und Berichte erscheinen hier.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                itemsIndexed(recent, key = { _, entry -> entry.second.id }) { index, (item, encounter) ->
                    Appear(5 + index) {
                        val approved = encounter.reports.lastOrNull()?.approvedAt != null
                        val accent = if (approved) Color(0xFF34C759) else colors.primary
                        val interaction = remember { MutableInteractionSource() }
                        Row(
                            Modifier.fillMaxWidth().pressable(interaction).clip(RoundedCornerShape(22.dp))
                                .clickable(interaction, indication = null) { nav.navigate(EncounterRoute(item.id, encounter.id)) }
                                .vetCard(colors, padding = 14.dp)
                                .semantics(mergeDescendants = true) {},
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(46.dp).clip(CircleShape).background(accent.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                                Icon(if (approved) Icons.Rounded.Verified else SpeciesIcon.forSpecies(item.species), null, tint = accent)
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(item.displayName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("${item.species} · ${encounter.lastActivity.germanDateTime()}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Spacer(Modifier.height(5.dp))
                                Text(
                                    encounter.nextAction, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.primary,
                                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(colors.primary.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp),
                                )
                            }
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Header() {
    val hour = LocalDateTime.now().hour
    val icon = if (hour in 6..19) Icons.Rounded.WbSunny else Icons.Rounded.Bedtime
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (hour in 6..19) Color(0xFFFF9F0A) else Color(0xFF5E5CE6), modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Text(Greeting.text(hour), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(LocalDateTime.now().format(DateTimeFormatter.ofPattern("EEEE, d. MMMM", Locale.GERMAN)), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun StatTile(value: Int, title: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    val interaction = remember { MutableInteractionSource() }
    Column(
        modifier.pressable(interaction).clip(RoundedCornerShape(18.dp)).clickable(interaction, indication = null, onClick = onClick)
            .vetCard(colors, RoundedCornerShape(18.dp), 12.dp).semantics(mergeDescendants = true) {},
    ) {
        Icon(icon, null, tint = colors.primary, modifier = Modifier.size(18.dp))
        AnimatedContent(value, transitionSpec = { (fadeIn() + scaleIn(initialScale = 0.8f)) togetherWith (fadeOut() + scaleOut(targetScale = 1.2f)) }, label = "count") {
            Text("$it", fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 6.dp))
        }
        Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun HeroCard(enabled: Boolean, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    val interaction = remember { MutableInteractionSource() }
    Box(
        Modifier.fillMaxWidth().pressable(interaction).graphicsLayer { alpha = if (enabled) 1f else 0.5f }
            .shadow(16.dp, RoundedCornerShape(26.dp), spotColor = colors.primary, ambientColor = colors.primary)
            .clip(RoundedCornerShape(26.dp)).background(colors.gradient)
            .clickable(interaction, indication = null, enabled = enabled, onClick = onClick)
            .semantics { contentDescription = "Diktat aufnehmen" },
    ) {
        Icon(Icons.Rounded.GraphicEq, null, tint = Color.White.copy(alpha = 0.13f), modifier = Modifier.size(120.dp).align(Alignment.TopEnd).offset(x = 12.dp, y = (-18).dp))
        Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(56.dp).clip(CircleShape).background(Color.White), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Mic, null, tint = colors.primary, modifier = Modifier.size(28.dp))
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text("Diktat aufnehmen", color = Color.White, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text("Behandlung dokumentieren", color = Color.White.copy(alpha = 0.85f))
            }
            Icon(Icons.AutoMirrored.Rounded.ArrowForward, null, tint = Color.White)
        }
    }
}

@Composable
private fun ActionCard(title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    val interaction = remember { MutableInteractionSource() }
    Row(
        Modifier.fillMaxWidth().pressable(interaction).clip(RoundedCornerShape(26.dp)).clickable(interaction, indication = null, onClick = onClick)
            .vetCard(colors, RoundedCornerShape(26.dp), 20.dp).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GradientIcon(icon, size = 56.dp)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Rounded.ArrowForward, null, tint = colors.primary)
    }
}

/** Sun/moon toggle; the new appearance grows as a circle from this button. */
@Composable
fun DayNightToggle() {
    val appearance = LocalAppearance.current
    val dark = LocalVetColors.current.dark
    val center = remember { floatArrayOf(0f, 0f) }
    IconButton(
        onClick = { appearance.setMode(if (dark) AppearanceMode.LIGHT else AppearanceMode.DARK, Offset(center[0], center[1])) },
        modifier = Modifier.onGloballyPositioned { val bounds = it.boundsInRoot(); center[0] = bounds.center.x; center[1] = bounds.center.y },
    ) {
        AnimatedContent(dark, transitionSpec = { (fadeIn() + scaleIn(initialScale = 0.4f)) togetherWith (fadeOut() + scaleOut(targetScale = 0.4f)) }, label = "sun-moon") { night ->
            Icon(
                if (night) Icons.Rounded.DarkMode else Icons.Rounded.LightMode,
                contentDescription = if (night) "Tagmodus" else "Nachtmodus",
                tint = if (night) Color(0xFFFFD60A) else Color(0xFFFF9F0A),
            )
        }
    }
}

/** Fades and lifts content in once, staggered by index; instant when animations are off. */
@Composable
fun Appear(index: Int, content: @Composable () -> Unit) {
    val reduceMotion = LocalReduceMotion.current
    val progress = remember { Animatable(if (reduceMotion) 1f else 0f) }
    LaunchedEffect(Unit) { progress.animateTo(1f, tween(420, delayMillis = (index * 45).coerceAtMost(300), easing = FastOutSlowInEasing)) }
    Box(Modifier.graphicsLayer { alpha = progress.value; translationY = (1f - progress.value) * 40f }) { content() }
}
