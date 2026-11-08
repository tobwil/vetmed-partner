# 0020: Dosisrechner, feste Warnregeln und Laborverlauf

Datum: 08.11.2026

## Anlass

Im Praxisalltag fehlten drei Werkzeuge:

- ein Dosisrechner, der die Rechnung nachvollziehbar zeigt;
- Warnungen bei bekannten, gefährlichen Kombinationen;
- der Verlauf von Laborwerten als Grafik. Bisher gab es nur „Vorher: …“ in der Prüfansicht (ADR 0015).

Gewünscht war auch eine Arzneimitteldatenbank. Eine **frei nutzbare, amtliche Schnittstelle mit Dosierungen für Tierarzneimittel gibt es nicht**:

- Die Unionsdatenbank der EMA und das PharmNet.Bund-Portal sind zum Nachschlagen gedacht. Sie bieten keine maschinenlesbaren Dosierungen zur Einbindung.
- Kommerzielle Datenbanken wie Vetidata oder der Arzneimittelkompass sind lizenzpflichtig.

Eine selbst gepflegte Liste von Präparaten und Dosierungen wäre ungeprüft und würde veralten. Deshalb gibt es keine.

## Entscheidung

**Alles deterministisch, ohne Sprachmodell.**

**Dosisrechner** (`DoseCalculator`):

- Gewicht × Dosis pro kg = Menge, geteilt durch die Stärke. Ergebnis in ml (Lösung) oder Tabletten.
- Jede Zahl gibt die Tierärztin ein. Die App schlägt keine Dosis vor und kennt keine Präparate.
- Der Rechenweg steht ausgeschrieben da, zum Beispiel „12,5 kg × 0,1 mg/kg = 1,25 mg“ und „1,25 mg ÷ 1,5 mg/ml = 0,83 ml“.
- Hinweise erscheinen
  - bei sehr kleinen Mengen unter 0,1 ml;
  - bei großen Mengen über 50 ml;
  - bei mehr als 100 mg/kg (Verwechslung von mg und µg?);
  - wenn eine Vierteltablette schon zu viel ist.
- Bei Tabletten nennt die App die Rundung auf Vierteltabletten mit der Abweichung in Prozent. Ob die Tablette teilbar ist, steht in der Fachinformation.
- Ungültige Eingaben werden abgelehnt, nicht geraten: Text statt Zahl, 0, negative Werte, mehr als 1.500 kg.

**Feste Warnregeln** (`DrugRules`) erkennen den Wirkstoff am Namen. Die Liste ist geschlossen und durch Tests belegt:

| Regel | Stufe |
|---|---|
| Paracetamol bei der Katze | Nicht geben |
| Permethrin bei der Katze | Nicht geben |
| Makrozyklische Laktone und weitere MDR1-Substrate (Ivermectin, Milbemycin, Moxidectin, Selamectin, Emodepsid, Loperamid, Acepromazin, Butorphanol, Vincristin u. a.) beim Hund mit nachgewiesenem MDR1-Defekt | Vorsicht |
| dieselben bei unbekanntem MDR1-Status | Hinweis |
| NSAID, wenn der neueste bestätigte Kreatinin- oder SDMA-Wert des Falls über dem gedruckten Referenzbereich liegt | Vorsicht, mit Wert, Bereich und Datum |
| NSAID im Fall ohne bestätigten Nierenwert | Hinweis |
| Humane NSAIDs (Ibuprofen, Naproxen, Diclofenac) bei Hund und Katze | Vorsicht |

Grenzen der Regeln:

- „Kreatinkinase“ (CK) zählt nicht als Nierenwert.
- Unbestätigte Befunde zählen nicht.
- Ist der neueste Wert wieder normal, gibt es keine Warnung.
- Unter jeder Warnung steht: Fehlt eine Warnung, heißt das nicht, dass das Mittel unbedenklich ist.

**Laborverlauf** (`LabTrend`):

- Je Parameter und Einheit gibt es eine Linie aus den bestätigten, zahlenmäßigen Werten des Falls, nach Probendatum geordnet. Fehlt das Probendatum, gilt der Tag der Bestätigung.
- Grün hinterlegt ist der gedruckte Referenzbereich des neuesten Befunds. Werte, die die App als hoch oder niedrig bewertet, sind rot.
- Werte wie „< 0,1“ oder „positiv“ werden nicht gezeichnet.
- Ab zwei Werten erscheint in der Fallansicht „Laborverlauf“.

**Einstiege:**

- Startseite: „Dosis berechnen“, ohne Fall.
- Fallansicht: „Dosis berechnen“ mit Tierart und Laborwerten des Falls, dazu „Laborverlauf“.

## Prüfung

- **Android:**
  - `DosingTests` (Kern, 8 Tests): Rechnung, µg, Tabletten, Ablehnungen, Katzenregeln, MDR1, Nierenwerte mit CK und unbestätigten Befunden, Verlauf.
  - UI-Test `theDoseIsCalculatedWithFixedWarningsAndTheLabCourseIsDrawn`: Meloxicam bei Hund mit steigendem Kreatinin, dann Paracetamol bei der Katze, dann Laborverlauf. Screenshots `21-dosis-warnregeln.png` und `22-laborverlauf.png`.
- **iOS:**
  - `DosingTests.swift` mit denselben Fällen. Unter Linux mit Swift 6.1 zusammen mit den übrigen Tests: 40/40.
  - Ansichten (Swift Charts) nur auf Syntax geprüft. **Vor `main`:** `./scripts/test-ios.sh` auf dem Mac.
- **Fachliche Durchsicht der Regeltexte durch eine Tierärztin steht aus.**

## Grenzen

- Der Wirkstoff wird am Namen erkannt, nicht am Handelsnamen. „Metacam“ löst keine Regel aus, „Meloxicam“ schon.
- Die Regeln decken wenige, gut belegte Gefahren ab. Wechselwirkungen, Kontraindikationen und Dosisgrenzen aus der Fachinformation prüft die App nicht.
- Der Rechner kennt keine Körperoberfläche und keine Dauertropfinfusion.
