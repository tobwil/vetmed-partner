package de.tobwil.vetmed.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Block
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.DoseCalculator
import de.tobwil.vetmed.core.DrugRules
import de.tobwil.vetmed.core.LabAssessment
import de.tobwil.vetmed.core.LabTrend

private val stopRed = Color(0xFFFF3B30)
private val cautionOrange = Color(0xFFFF9F0A)

@Composable
private fun ToolScaffold(title: String, nav: NavHostController, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground, topBar = { BackTopBar(title, nav) }) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) { content(); Spacer(Modifier.size(32.dp)) }
        }
    }
}

@Composable
private fun Small(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, modifier: Modifier = Modifier) =
    Text(text, style = MaterialTheme.typography.bodySmall, color = color, modifier = modifier)

@Composable
private fun NumberField(value: String, label: String, tag: String, onChange: (String) -> Unit) = OutlinedTextField(
    value, onChange, label = { Text(label) }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
    modifier = Modifier.fillMaxWidth().testTag(tag),
)

/**
 * Dose calculator with fixed warning rules (ADR 0020). Every number comes from the user; the app only calculates and
 * checks a short list of known dangers. Opened from a case, species and confirmed lab values of that case are used.
 */
@Composable
fun DoseScreen(model: AppViewModel, nav: NavHostController, caseID: String?) {
    val colors = LocalVetColors.current
    val document by model.document.collectAsStateWithLifecycle()
    val item = document.cases.firstOrNull { it.id == caseID }
    var drug by rememberSaveable { mutableStateOf("") }
    var species by rememberSaveable { mutableStateOf(item?.species ?: "") }
    var weight by rememberSaveable { mutableStateOf("") }
    var dose by rememberSaveable { mutableStateOf("") }
    var strength by rememberSaveable { mutableStateOf("") }
    var unit by rememberSaveable { mutableStateOf(DoseCalculator.DoseUnit.MG_PER_KG) }
    var form by rememberSaveable { mutableStateOf(DoseCalculator.Form.LIQUID) }
    var mdr1 by rememberSaveable { mutableStateOf(DrugRules.Mdr1.UNKNOWN) }
    ToolScaffold("Dosis berechnen", nav) {
        Column(Modifier.fillMaxWidth().vetCard(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item?.let { Small("Fall: ${it.displayName}") }
            OutlinedTextField(drug, { drug = it }, label = { Text("Wirkstoff") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("dose-drug"))
            OutlinedTextField(species, { species = it }, label = { Text("Tierart") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("dose-species"))
            if (DrugRules.species(species) == DrugRules.Species.DOG) {
                Text("MDR1-Status", style = MaterialTheme.typography.labelLarge)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    DrugRules.Mdr1.entries.forEachIndexed { index, value ->
                        SegmentedButton(mdr1 == value, { mdr1 = value }, SegmentedButtonDefaults.itemShape(index, DrugRules.Mdr1.entries.size)) {
                            Text(value.label, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
            NumberField(weight, "Gewicht in kg", "dose-weight") { weight = it }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { NumberField(dose, "Dosis", "dose-per-kg") { dose = it } }
                Spacer(Modifier.width(8.dp))
                SingleChoiceSegmentedButtonRow(Modifier.width(150.dp)) {
                    DoseCalculator.DoseUnit.entries.forEachIndexed { index, value ->
                        SegmentedButton(unit == value, { unit = value }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(value.label, style = MaterialTheme.typography.labelSmall) }
                    }
                }
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                DoseCalculator.Form.entries.forEachIndexed { index, value ->
                    SegmentedButton(form == value, { form = value }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(value.label) }
                }
            }
            NumberField(strength, "Stärke in ${form.strengthUnit}", "dose-strength") { strength = it }
            Small("Dosis und Stärke bitte aus der Fachinformation übernehmen. Die App schlägt keine Dosis vor und prüft nicht, ob sie stimmt.")
        }

        val ready = weight.isNotBlank() && dose.isNotBlank() && strength.isNotBlank()
        if (ready) {
            val result = remember(weight, dose, unit, form, strength) {
                try { Result.success(DoseCalculator.calculate(weight, dose, unit, form, strength)) } catch (error: AppFailure) { Result.failure(error) }
            }
            Column(Modifier.fillMaxWidth().vetCard(colors).testTag("dose-result"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                result.onSuccess { value ->
                    Text(value.amountText, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = colors.primary, modifier = Modifier.testTag("dose-amount"))
                    value.steps.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
                    value.notes.forEach { Small(it, cautionOrange) }
                }.onFailure { Text(it.message ?: "", color = stopRed, modifier = Modifier.testTag("dose-error")) }
            }
        }

        val warnings = remember(drug, species, mdr1, document, caseID) { DrugRules.warnings(drug, species, mdr1, document, caseID) }
        warnings.forEach { warning ->
            val tint = when (warning.severity) { DrugRules.Severity.STOP -> stopRed; DrugRules.Severity.CAUTION -> cautionOrange; DrugRules.Severity.INFO -> colors.primary }
            Row(Modifier.fillMaxWidth().vetCard(colors).testTag("dose-warning-${warning.severity.name.lowercase()}"), verticalAlignment = Alignment.Top) {
                Icon(when (warning.severity) { DrugRules.Severity.STOP -> Icons.Rounded.Block; DrugRules.Severity.CAUTION -> Icons.Rounded.Warning; DrugRules.Severity.INFO -> Icons.Rounded.Info }, null, tint = tint)
                Spacer(Modifier.width(10.dp))
                Column {
                    Text("${warning.severity.label}: ${warning.title}", fontWeight = FontWeight.SemiBold, color = tint)
                    Text(warning.text, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        if (drug.isNotBlank()) Small(DrugRules.DISCLAIMER)
    }
}

/** Confirmed lab values of a case over time, one chart per parameter with the laboratory's printed range shaded. */
@Composable
fun LabTrendScreen(model: AppViewModel, nav: NavHostController, caseID: String) {
    val colors = LocalVetColors.current
    val document by model.document.collectAsStateWithLifecycle()
    val series = remember(document, caseID) { LabTrend.series(document, caseID) }
    ToolScaffold("Laborverlauf", nav) {
        Small("Nur am Original bestätigte Werte mit Zahl, je Parameter und Einheit. Grün hinterlegt: Referenzbereich des Labors vom neuesten Befund. Bewertung durch die App.")
        if (series.isEmpty()) Text("Für einen Verlauf braucht es mindestens zwei bestätigte Befunde mit demselben Parameter.", modifier = Modifier.padding(top = 12.dp))
        series.forEach { line ->
            Column(Modifier.fillMaxWidth().vetCard(colors).testTag("trend-${line.parameter}"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(if (line.unit.isEmpty()) line.parameter else "${line.parameter} (${line.unit})", fontWeight = FontWeight.SemiBold)
                TrendChart(line, colors.primary, Modifier.fillMaxWidth().height(140.dp))
                line.points.forEach { point ->
                    Row {
                        Small(point.label, modifier = Modifier.weight(1f))
                        val flagged = point.assessment == LabAssessment.HIGH || point.assessment == LabAssessment.LOW
                        Text("${point.raw} ${point.assessment.symbol}".trim(), style = MaterialTheme.typography.bodyMedium,
                            color = if (flagged) stopRed else MaterialTheme.colorScheme.onSurface, fontWeight = if (flagged) FontWeight.SemiBold else FontWeight.Normal)
                        Small(if (point.reference.isEmpty()) "  Ref. –" else "  Ref. ${point.reference}")
                    }
                }
            }
        }
    }
}

@Composable
private fun TrendChart(series: LabTrend.Series, line: Color, modifier: Modifier) {
    val band = series.band
    val values = series.points.map { it.value } + listOfNotNull(band?.low, band?.high)
    val low = values.min(); val high = values.max()
    val padding = if (high == low) 1.0 else (high - low) * 0.12
    val bottom = low - padding; val top = high + padding
    val description = "Verlauf ${series.parameter}: " + series.points.joinToString(", ") { "${it.label} ${it.raw}" }
    val grid = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.25f)
    Canvas(modifier.semantics { contentDescription = description }) {
        fun y(value: Double) = (size.height * (1 - (value - bottom) / (top - bottom))).toFloat()
        fun x(index: Int) = if (series.points.size == 1) size.width / 2 else 12f + (size.width - 24f) * index / (series.points.size - 1)
        if (band != null) drawRect(Color(0xFF34C759).copy(alpha = 0.16f), Offset(0f, y(band.high!!)), Size(size.width, y(band.low!!) - y(band.high!!)))
        drawLine(grid, Offset(0f, size.height - 1), Offset(size.width, size.height - 1), 1f)
        val path = Path()
        series.points.forEachIndexed { index, point -> if (index == 0) path.moveTo(x(index), y(point.value)) else path.lineTo(x(index), y(point.value)) }
        drawPath(path, line, style = Stroke(width = 5f))
        series.points.forEachIndexed { index, point ->
            val flagged = point.assessment == LabAssessment.HIGH || point.assessment == LabAssessment.LOW
            drawCircle(if (flagged) stopRed else line, radius = 9f, center = Offset(x(index), y(point.value)))
            drawCircle(Color.White, radius = 4f, center = Offset(x(index), y(point.value)))
        }
    }
}
