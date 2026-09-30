package de.tobwil.vetmed.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.MedicalServices
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.EncounterLocation
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

@Serializable object StartRoute
@Serializable object CasesRoute
@Serializable object ChatRoute
@Serializable data class CaseRoute(val caseID: String)
@Serializable data class EncounterRoute(val caseID: String, val encounterID: String) { val location get() = EncounterLocation(caseID, encounterID) }
@Serializable data class ReportRoute(val caseID: String, val encounterID: String, val reportID: String) { val location get() = EncounterLocation(caseID, encounterID) }
@Serializable data class ChatConversationRoute(val caseID: String? = null, val encounterID: String) {
    val location get() = de.tobwil.vetmed.core.ChatLocation(caseID, encounterID)
}
@Serializable object SettingsRoute
@Serializable object OnlineRoute
@Serializable object VocabularyRoute

/** Day/night and theme actions shared by the toggle on Start and the settings screen. */
class AppearanceController(
    val mode: AppearanceMode,
    val theme: AccentTheme,
    val setMode: (AppearanceMode, Offset?) -> Unit,
    val setTheme: (AccentTheme) -> Unit,
)
val LocalAppearance = staticCompositionLocalOf<AppearanceController> { error("No appearance controller") }

@Composable
fun VetMedApp(model: AppViewModel = viewModel()) {
    val store = rememberAppearanceStore()
    var mode by remember { mutableStateOf(store.mode) }
    var theme by remember { mutableStateOf(store.theme) }
    val scope = rememberCoroutineScope()
    val radius = remember { Animatable(0f) }
    val overlay = remember { Animatable(0f) }
    var reveal by remember { mutableStateOf<Pair<Offset, Color>?>(null) }
    // Like iOS `background()`: leaving the app stops playback, pauses a recording safely and frees an idle model.
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_STOP) { model.background() }

    VetMedTheme(mode, theme) {
        val reduceMotion = LocalReduceMotion.current
        val dark = LocalVetColors.current.dark
        val controller = AppearanceController(
            mode = mode, theme = theme,
            setMode = { next, origin ->
                store.mode = next
                val targetDark = when (next) { AppearanceMode.LIGHT -> false; AppearanceMode.DARK -> true; AppearanceMode.SYSTEM -> dark }
                if (origin == null || reduceMotion || targetDark == dark) { mode = next } else scope.launch {
                    // A circle in the new background colour grows from the toggle, then the theme cross-fades beneath it.
                    reveal = origin to (if (targetDark) Color.Black else Color(0xFFF2F2F7))
                    overlay.snapTo(1f); radius.snapTo(0f)
                    radius.animateTo(1f, tween(480, easing = FastOutSlowInEasing))
                    mode = next
                    overlay.animateTo(0f, tween(380))
                    reveal = null
                }
            },
            setTheme = { store.theme = it; theme = it },
        )
        CompositionLocalProvider(LocalAppearance provides controller) {
            Box(Modifier.fillMaxSize()) {
                AppContent(model)
                reveal?.let { (center, color) ->
                    Canvas(Modifier.fillMaxSize()) {
                        val max = listOf(Offset.Zero, Offset(size.width, 0f), Offset(0f, size.height), Offset(size.width, size.height)).maxOf { (it - center).getDistance() }
                        drawCircle(color.copy(alpha = overlay.value), radius = max * radius.value, center = center)
                    }
                }
            }
        }
    }
}

@Composable
private fun AppContent(model: AppViewModel) {
    val ready by model.ready.collectAsStateWithLifecycle()
    val error by model.error.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val status by model.workStatus.collectAsStateWithLifecycle()
    val navController = rememberNavController()

    if (!ready) PrivacyCover(onOpen = if (error != null) model::open else null) else {
        Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            Box(Modifier.weight(1f)) {
                NavHost(
                    navController, startDestination = StartRoute,
                    enterTransition = { fadeIn(tween(220)) + slideInHorizontally(tween(260)) { it / 8 } },
                    exitTransition = { fadeOut(tween(180)) },
                    popEnterTransition = { fadeIn(tween(220)) },
                    popExitTransition = { fadeOut(tween(180)) + slideOutHorizontally(tween(260)) { it / 8 } },
                ) {
                    composable<StartRoute> { StartScreen(model, navController) }
                    composable<CasesRoute> { CasesScreen(model, navController) }
                    composable<ChatRoute> { ChatListScreen(model, navController) }
                    composable<ChatConversationRoute> { ChatConversationScreen(model, navController, it.toRoute<ChatConversationRoute>().location) }
                    composable<CaseRoute> { CaseDetailScreen(model, navController, it.toRoute<CaseRoute>().caseID) }
                    composable<EncounterRoute> { EncounterScreen(model, navController, it.toRoute<EncounterRoute>().location) }
                    composable<ReportRoute> { entry -> val route = entry.toRoute<ReportRoute>(); ReportReviewScreen(model, navController, route.location, route.reportID) }
                    composable<SettingsRoute> { SettingsScreen(model, navController) }
                    composable<OnlineRoute> { OnlineSettingsScreen(model, navController) }
                    composable<VocabularyRoute> { VocabularyScreen(model, navController) }
                }
                androidx.compose.animation.AnimatedVisibility(
                    busy, Modifier.align(Alignment.BottomCenter),
                    enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut(),
                ) { BusyBar(status, model::cancel) }
            }
            BottomBar(navController)
        }
    }
    error?.let { message ->
        AlertDialog(
            onDismissRequest = model::dismissError,
            confirmButton = { TextButton(onClick = model::dismissError) { Text("OK") } },
            title = { Text("Hinweis") }, text = { Text(message) },
        )
    }
}

@Composable
private fun BottomBar(navController: NavHostController) {
    val entry by navController.currentBackStackEntryAsState()
    val destination = entry?.destination
    val topLevel = listOf(StartRoute::class, CasesRoute::class, ChatRoute::class).any { route -> destination?.hierarchy?.any { it.hasRoute(route) } == true }
    AnimatedVisibility(topLevel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
        NavigationBar(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)) {
            data class Tab(val route: Any, val tag: String, val title: String, val icon: androidx.compose.ui.graphics.vector.ImageVector, val selected: Boolean)
            listOf(
                Tab(StartRoute, "tab-start", "Start", Icons.Rounded.Home, destination?.hierarchy?.any { it.hasRoute(StartRoute::class) } == true),
                Tab(CasesRoute, "tab-cases", "Fälle", Icons.Rounded.Folder, destination?.hierarchy?.any { it.hasRoute(CasesRoute::class) } == true),
                Tab(ChatRoute, "tab-chat", "Chat", Icons.AutoMirrored.Rounded.Chat, destination?.hierarchy?.any { it.hasRoute(ChatRoute::class) } == true),
            ).forEach { tab ->
                NavigationBarItem(
                    modifier = Modifier.testTag(tab.tag),
                    selected = tab.selected,
                    onClick = {
                        navController.navigate(tab.route) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true; restoreState = true
                        }
                    },
                    icon = { Icon(tab.icon, contentDescription = null) }, label = { Text(tab.title) },
                    colors = NavigationBarItemDefaults.colors(indicatorColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f), selectedIconColor = MaterialTheme.colorScheme.primary, selectedTextColor = MaterialTheme.colorScheme.primary),
                )
            }
        }
    }
}

@Composable
private fun BusyBar(status: String, cancel: () -> Unit) {
    val colors = LocalVetColors.current
    Row(
        Modifier.padding(16.dp).fillMaxWidth().shadow(10.dp, RoundedCornerShape(28.dp)).clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surface).padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.primary)
        Spacer(Modifier.width(12.dp))
        Text(status, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f), maxLines = 2)
        TextButton(onClick = cancel) { Text("Abbrechen", fontWeight = FontWeight.SemiBold) }
    }
}

@Composable
fun PrivacyCover(onOpen: (() -> Unit)? = null) {
    val colors = LocalVetColors.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AmbientBackground()
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(96.dp).shadow(18.dp, RoundedCornerShape(28.dp), spotColor = colors.primary).clip(RoundedCornerShape(28.dp)).background(colors.gradient),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.MedicalServices, null, tint = Color.White, modifier = Modifier.size(48.dp)) }
            Spacer(Modifier.size(18.dp))
            Text("VetMed", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
            Text("Deine Fälle bleiben geschützt.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (onOpen != null) {
                Spacer(Modifier.size(32.dp))
                FilledTonalButton(onClick = onOpen, shape = CircleShape) { Text("Lokale Daten öffnen") }
            }
        }
    }
}
