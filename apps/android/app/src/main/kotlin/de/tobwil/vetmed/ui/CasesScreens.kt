package de.tobwil.vetmed.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.VetCase
import de.tobwil.vetmed.core.germanDateTime

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CasesScreen(model: AppViewModel, nav: NavHostController) {
    val document by model.document.collectAsStateWithLifecycle()
    var search by rememberSaveable { mutableStateOf("") }
    var toDelete by remember { mutableStateOf<VetCase?>(null) }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val cases = remember(document, search) {
        document.cases.filter { item -> search.isEmpty() || listOf(item.label, item.animalName, item.species).any { it.contains(search, ignoreCase = true) } }
            .sortedByDescending { item -> item.encounters.maxOfOrNull { it.lastActivity } ?: item.createdAt }
    }
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            modifier = Modifier.nestedScroll(scroll.nestedScrollConnection), containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = {
                LargeTopAppBar(
                    title = { Text("Fälle", fontWeight = FontWeight.Bold) }, scrollBehavior = scroll,
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)),
                )
            },
        ) { padding ->
            LazyColumn(
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding(), bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item {
                    OutlinedTextField(
                        search, { search = it }, Modifier.fillMaxWidth(), singleLine = true, shape = RoundedCornerShape(18.dp),
                        placeholder = { Text("Kennung, Tiername, Tierart") }, leadingIcon = { Icon(Icons.Rounded.Search, null) },
                    )
                }
                if (cases.isEmpty()) item {
                    EmptyState(
                        Icons.Rounded.Folder,
                        if (search.isEmpty()) "Noch keine Fälle" else "Kein passender Fall",
                        if (search.isEmpty()) "Mit einem Diktat legst du einen Fall an." else "Suche nach Kennung, Tiername oder Tierart.",
                    )
                }
                items(cases, key = { it.id }) { item ->
                    val state = rememberSwipeToDismissBoxState()
                    LaunchedEffect(state.currentValue) {
                        if (state.currentValue == SwipeToDismissBoxValue.EndToStart) { toDelete = item; state.reset() }
                    }
                    SwipeToDismissBox(
                        state, enableDismissFromStartToEnd = false, modifier = Modifier.animateItem(),
                        backgroundContent = {
                            val color by animateColorAsState(if (state.targetValue == SwipeToDismissBoxValue.EndToStart) Color(0xFFFF3B30) else Color.Transparent, label = "swipe")
                            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(22.dp)).background(color).padding(end = 24.dp), contentAlignment = Alignment.CenterEnd) {
                                Icon(Icons.Rounded.Delete, "Löschen", tint = Color.White)
                            }
                        },
                    ) { CaseRow(item) { nav.navigate(CaseRoute(item.id)) } }
                }
            }
        }
    }
    toDelete?.let { item ->
        DeleteCaseDialog(item.displayName, onDismiss = { toDelete = null }) { model.deleteCase(item.id); toDelete = null }
    }
}

@Composable
private fun CaseRow(item: VetCase, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(MaterialTheme.colorScheme.background).clickable(onClick = onClick)
            .vetCard(colors, padding = 14.dp).testTag("case-row-" + item.id).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(colors.gradient), contentAlignment = Alignment.Center) {
            Icon(SpeciesIcon.forSpecies(item.species), null, tint = Color.White, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(item.displayName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("${item.species} · ${item.encounters.size} Vorgänge", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CaseDetailScreen(model: AppViewModel, nav: NavHostController, caseID: String) {
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val item = document.cases.firstOrNull { it.id == caseID }
    val colors = LocalVetColors.current
    var editing by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    LaunchedEffect(item == null) { if (item == null) nav.popBackStack() }
    if (item == null) return
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = { BackTopBar(item.label, nav) },
        ) { padding ->
            LazyColumn(
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding() + 8.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item {
                    Row(Modifier.fillMaxWidth().vetCard(colors), verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.size(64.dp).shadow(8.dp, RoundedCornerShape(20.dp), spotColor = colors.primary).clip(RoundedCornerShape(20.dp)).background(colors.gradient),
                            contentAlignment = Alignment.Center,
                        ) { Icon(SpeciesIcon.forSpecies(item.species), null, tint = Color.White, modifier = Modifier.size(32.dp)) }
                        Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f)) {
                            Text(item.animalName.ifEmpty { item.label }, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            Text(if (item.animalName.isEmpty()) item.species else "${item.species} · ${item.label}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = { editing = true }) { Icon(Icons.Rounded.Edit, "Falldaten bearbeiten", tint = colors.primary) }
                    }
                }
                item { SectionTitle("Vorgänge") }
                items(item.encounters, key = { it.id }) { encounter ->
                    val approved = encounter.reports.lastOrNull()?.approvedAt != null
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable { nav.navigate(EncounterRoute(item.id, encounter.id)) }
                            .vetCard(colors).testTag("open-encounter-" + encounter.id),
                    ) {
                        Text(encounter.date.germanDateTime(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (approved) Icons.Rounded.Verified else Icons.Rounded.Description, null, tint = if (approved) Color(0xFF34C759) else colors.primary)
                            Spacer(Modifier.width(10.dp))
                            Text(encounter.nextAction, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
                        }
                        if (encounter.reports.isNotEmpty()) {
                            Text("${encounter.reports.size} Berichtsversionen", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
                        }
                    }
                }
                item {
                    TextButton(
                        enabled = !busy,
                        onClick = { model.newEncounter(item.id) { nav.navigate(EncounterRoute(it.caseID, it.encounterID)) } },
                        modifier = Modifier.testTag("new-case-dictation"),
                    ) { Icon(Icons.Rounded.Add, null); Spacer(Modifier.width(8.dp)); Text("Neues Diktat zu diesem Fall") }
                }
                item {
                    TextButton(onClick = { deleting = true }, enabled = !busy, modifier = Modifier.testTag("delete-case-bottom")) {
                        Icon(Icons.Rounded.Delete, null, tint = Color(0xFFFF3B30)); Spacer(Modifier.width(8.dp)); Text("Fall löschen", color = Color(0xFFFF3B30))
                    }
                }
            }
        }
    }
    if (editing) CaseEditorDialog(model, item) { editing = false }
    if (deleting) DeleteCaseDialog(item.displayName, onDismiss = { deleting = false }) { deleting = false; model.deleteCase(item.id) }
}

@Composable
fun DeleteCaseDialog(name: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Fall löschen?") },
        text = { Text("„$name“ mit allen Vorgängen, Berichten und Aufnahmen endgültig löschen?") },
        confirmButton = { TextButton(onClick = onConfirm) { Text("Fall endgültig löschen", color = Color(0xFFFF3B30)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Behalten") } },
    )
}

@Composable
fun CaseEditorDialog(model: AppViewModel, item: VetCase, onDone: () -> Unit) {
    var label by remember { mutableStateOf(item.label) }
    var species by remember { mutableStateOf(item.species) }
    var name by remember { mutableStateOf(item.animalName) }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Falldaten") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(label, { label = it }, label = { Text("Fallkennung") }, singleLine = true, modifier = Modifier.testTag("case-label"))
                OutlinedTextField(species, { species = it }, label = { Text("Tierart") }, singleLine = true)
                OutlinedTextField(name, { name = it }, label = { Text("Tiername (optional)") }, singleLine = true)
            }
        },
        confirmButton = {
            TextButton(enabled = label.isNotBlank(), onClick = { model.updateCase(item.id, label, species, name, onDone) }) { Text("Speichern") }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Abbrechen") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackTopBar(title: String, nav: NavHostController, actions: @Composable () -> Unit = {}) {
    TopAppBar(
        title = { Text(title, fontWeight = FontWeight.SemiBold) },
        navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Zurück") } },
        actions = { actions() },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)),
    )
}

@Composable
fun SectionTitle(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 16.dp, top = 8.dp))
}

@Composable
fun EmptyState(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, text: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        GradientIcon(icon, size = 64.dp)
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}
