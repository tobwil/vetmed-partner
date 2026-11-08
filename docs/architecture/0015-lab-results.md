# 0015: Laborbefunde als geprüfte Wertetabelle

Erweitert durch [0017](0017-smart-attachments.md): kein eigener Menüpunkt mehr, jedes Dokument wird erkannt und gelesen.

Datum: 08.11.2026

## Anlass

Laborbefunde wie Blutbild und Organprofil sind Tabellen. Bisher las die App sie als Fließtext: Android über die PDF-Textebene oder OCR, iOS über den Layout-Leser. Das Modell sah nie das Seitenbild. Tabellen gehen dabei leicht kaputt:

- Spalten verrutschen.
- Ein Referenzbereich landet beim falschen Parameter.
- OCR liest aus „5,8“ eine „5,3“.

Der Nutzer will Befunde als echter Praxispartner nutzen. Ein falscher Wert darf nicht unbemerkt in die Einschätzung gehen.

## Entscheidung

Vier Stufen, jede mit eigener Absicherung:

1. **Lesen mit Bild (online, Standard).**
   - Die Seitenbilder gehen an das gewählte Modell, OpenAI oder Gemini, mit strengem JSON-Schema. PDFs werden mit etwa 200 dpi gerendert; erlaubt sind höchstens 6 Seiten zu je höchstens 2 MB.
   - Die Anweisung `shared/prompts/lab-extraction-v1.txt` (seit ADR 0017 `document-reading-v1.txt`) erlaubt nur Übertragen: nichts berechnen, nichts ergänzen, Referenzbereiche nie erfinden, keine Tier- oder Halterdaten.
   - Ohne Online-Zugang oder mit „Nur auf dem Gerät“ (ADR 0014) arbeitet ein Zeilenparser auf dem lokalen Text. Jede so gelesene Zeile ist orange markiert.
2. **Abgleich mit dem Original (immer, lokal).**
   - Jede Zahl aus Wert und Referenz muss im lokal gelesenen Text vorkommen. Lokal gelesen wird über die PDF-Textebene, den iOS-Layout-Leser oder OCR mit ML Kit bzw. Vision.
   - Fehlt eine Zahl, wird die Zeile rot: „Nicht im Original gefunden“.
   - Zusätzlich orange markiert:
     - Zeilen, die das Modell als unleserlich meldet;
     - Zeilen, deren Kennzeichnung vom Labor (H/L/↑/↓) der App-Bewertung widerspricht. Das deutet auf einen falsch gelesenen Wert oder Bereich hin.
3. **Prüfansicht.**
   - Oben das Seitenbild zum Zoomen, darunter die Zeilen.
   - Jede Zeile lässt sich bearbeiten, löschen oder ergänzen. Speichern verlangt das Häkchen „Am Original verglichen“.
   - Erst „Tabelle am Original geprüft · bestätigen“ macht den Befund im Chat nutzbar.
   - Wird ein bestätigter Befund neu gelesen, gilt er wieder als unbestätigt.
4. **Bewertung durch die App, nicht durch das Modell.**
   - `LabMath` berechnet „niedrig“, „im Bereich“ oder „hoch“ nur aus einem Zahlwert und einem eindeutigen gedruckten Bereich.
   - Erkannt werden: „a - b“, „a–b“, „a bis b“, „< b“, „≤ b“, „> a“, „bis b“, „ab a“ sowie deutsche Dezimalkommas.
   - Alles andere heißt „nicht bewertbar“, etwa geschlechtsspezifische Bereiche, Text oder Werte wie „< 0,1“.

**Im Chat:**

- Der Chat bekommt die bestätigte Tabelle als Markdown mit den Spalten Parameter, Wert, Einheit, Referenz (Labor), Kennz. (Labor) und Bewertung (App).
- Der Sparring-Prompt hat dafür einen eigenen Abschnitt: Werte nur aus der Tabelle, die App-Bewertung übernehmen, keine eigenen Referenzbereiche oder Normalwerte.

**Verlauf:** Bei jedem Wert zeigt die Prüfansicht frühere bestätigte Werte desselben Parameters im selben Fall, zum Beispiel „Vorher: 1,4 (01.10.2026)“. Verglichen wird nur bei gleicher Einheit. Ein Diagramm folgt später.

**Datenschutz:**

- Online gehen nur die Seitenbilder, an den Anbieter des eigenen Keys.
- Die App weist darauf hin, Tier- und Halternamen vorher abzudecken.
- Original und lokaler Text bleiben verschlüsselt auf dem Gerät.
- Die Seitenbilder werden nicht zusätzlich als Anfragekopie gespeichert; das Original liegt ohnehin verschlüsselt vor.

## Prüfung

- **Android:**
  - `LabReportTests`: 13 Tests (Zahlen, Referenzen, Bewertung, Kennzeichnungs-Widerspruch, Anfragen, Parsen, Abgleich, Gerät-Parser, Bestätigung, Verlauf, Prompt)
  - UI-Test mit synthetischem Befundbild: Der Anbieter liest absichtlich falsch, die Zeile wird rot. Dann folgen Korrektur, Bestätigung und die Tabelle im Chat mit „↑ hoch“. Screenshot `17-laborbefund-pruefen.png`.
  - gesamt: Kern 120 Tests (1 übersprungen), App 50, Lint und Build grün
- **iOS:**
  - `LabReportTests.swift`: 9 Tests mit denselben Fällen; zusammen mit `OnlineFirstTests` unter Linux mit Swift 6.1 im Swift-6-Modus gebaut und ausgeführt: 15/15 bestanden
  - Prüfansicht und Import (PDFKit, Vision) nur auf Syntax geprüft
  - Xcode und Gerät stehen aus
- **Echte Befunde:** `scripts/eval-labs.sh ORDNER` mit eigenen, anonymisierten Befunden und eigenem Key.
  - Gemessen wird: richtig gelesene Werte, falsch gelesene Werte und wie viele der falschen die App markiert hat.
  - Die Befunde und `lab-eval.json` bleiben außerhalb des Repos.
  - **Noch nicht gelaufen**, weil die Beispielbefunde noch fehlen.

## Grenzen

- Liest das lokale OCR dieselbe Zahl genauso falsch wie das Modell, fällt der Abgleich nicht an. Deshalb bleibt die Bestätigung am Original Pflicht.
- Der Abgleich prüft Zahlen, nicht ihre Zuordnung zur Zeile. Ein vertauschter Wert, der irgendwo im Befund vorkommt, gilt als gefunden. Hier hilft die Prüfung der Kennzeichnung nur teilweise.
- Der Gerät-Parser erkennt nur einfache Zeilen der Form „Name Wert Einheit Referenz“.
- Die App-Bewertung ersetzt keine klinische Einordnung. Laborbereiche gelten nur für Labor, Methode und Tierart.
