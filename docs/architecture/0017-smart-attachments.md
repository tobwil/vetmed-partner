# 0017: Anhänge automatisch verstehen, ohne Vorauswahl

Datum: 08.11.2026

## Anlass

ADR 0015 verlangte einen eigenen Menüpunkt „Laborbefund hinzufügen“. Der Nutzer will das nicht: Wie in einem normalen KI-Chat soll man einfach anhängen, und die App soll im Hintergrund erkennen, was es ist.

Dazu kommt eine echte Rücküberweisung einer Tierklinik als Referenz. Sie liegt nur lokal und ist nicht im Repo. Was sie zeigt:

- Ein Brief ist kein Laborbogen. Er enthält Anamnese, Befunde und Therapie als Text, dazwischen eine Wertetabelle.
- Der Referenzbereich steht in zwei Spalten (unten, oben), dazu Balkengrafiken statt H/L.
- Die Wertezeilen sind als Bilder eingebettet. Die PDF-Textebene enthält sie nicht.
- Jeder Absender gestaltet anders. Ein festes Layout taugt als Grundlage nicht; das multimodale Modell soll die Seiten lesen.

## Entscheidung

### Ein Eingang, die App entscheidet

| Anhang | Weg |
|---|---|
| PDF bis 10 Seiten | Das Modell liest die Seitenbilder im Hintergrund, sofort nach dem Hinzufügen. |
| PDF über 10 Seiten | Lokaler Text, zu prüfen wie bisher. |
| Foto | Lokale OCR (ML Kit, Vision) entscheidet: Viel Text oder viele Zahlen bedeuten Dokumentfoto (`DocumentRouting.looksLikeDocument`) und Weg wie ein PDF. Sonst bleibt es ein klinisches Bild, das der Chat-Modell direkt sieht. |
| Text, Markdown | Lokaler Text, zu prüfen wie bisher. |

- Mit „Nur auf dem Gerät“ (ADR 0014) oder ohne Online-Zugang liest die App lokal. Dann ist der lokale Text die Lesart, und Wertezeilen werden als Tabelle angeboten; alles ist zu prüfen.
- Der lokale Zeilenparser zählt eine Zeile nur noch als Messwert, wenn sie einen Referenzbereich oder eine echte Einheit hat. „Kontrolle in 7 Tagen“ ist Text.

### Was das Modell liefert

Der Prompt heißt jetzt `shared/prompts/document-reading-v1.txt` und ersetzt `lab-extraction-v1`. Das Antwortschema:

- `kind`: `lab`, `letter`, `imaging` oder `other`
- `title`, `issuer` (nur Klinik, Praxis oder Labor) und `date`
- `text`: der klinische Inhalt in Lesereihenfolge, wörtlich, ohne Grußformeln
- `values`: jede Messzeile, auch mitten im Brief

Unverändert gilt:

- übertragen, nicht bewerten;
- Referenzbereiche nie erfinden;
- Balken und Farben sind keine Kennzeichnung;
- keine Namen, Adressen, Bank- oder Registerdaten von Haltern und Tieren.

Neu: Zweispaltige Bereiche werden als „unten - oben“ übertragen.

### Absicherung

- **Lokales Original:** Bei PDFs bis 10 Seiten liest die App jede Seite zusätzlich per OCR (`checkText`). So zählen auch Werte, die als Bild im PDF stecken. Die bisherige Textebene allein hätte im Referenzbrief alle Werte rot markiert.
- **Zahlen im Text:** Zahlen im übertragenen Text (Dosis, Gewicht, Temperatur), die im lokalen Original fehlen, nennt die Prüfansicht rot (`unmatchedNumbers`).
- **Tabellenwerte:** Für Tabellenwerte bleibt alles wie in ADR 0015. Rot heißt „nicht im Original gefunden“, orange heißt „Kennzeichnung widerspricht“. Die Bewertung rechnet nur die App.
- **Prüfansicht für jedes gelesene Dokument:**
  - Seitenbild
  - Art und Titel des Dokuments
  - Text zum Bearbeiten
  - Messwerte zum Bearbeiten
  - „Am Original geprüft · übernehmen“
  - Ein Brief ohne Werte ist gültig.
- **Im Chat:** Der Chat bekommt Art, Titel, Absender, Datum, den bestätigten Text und darunter die Wertetabelle mit der App-Bewertung.

### Datenschutz

Neu ist, dass Dokumente direkt beim Anhängen gelesen werden, nicht erst beim Senden.

- Es gehen nur die Seitenbilder an den Anbieter des eigenen Keys. Für diesen Zugang hat der Nutzer beim Aktivieren bereits zugestimmt.
- „Nur auf dem Gerät“ verhindert das vollständig.

## Prüfung

- **Android:**
  - `LabReportTests`: 16 Tests, neu sind Weg nach Inhalt, Brief mit eingebetteten Werten, Zahlen im Text und Brief ohne Werte
  - UI-Test mit synthetischer Rücküberweisung: Der Anbieter liest die Temperatur falsch, die Zahl erscheint rot, danach folgen Korrektur und Übernahme. Screenshot `19-brief-mit-werten-pruefen.png`.
  - gesamt: Kern 133 Tests (2 übersprungen), App 52, Lint und Build grün
- **iOS:** dieselben Fälle in `LabReportTests.swift`, unter Linux mit Swift 6.1 gebaut und ausgeführt: 24/24 mit Online- und Sprachtests. Import, OCR der Seiten und Ansicht sind nur auf Syntax geprüft.
- **Mit dem echten Referenzbrief und echtem Key: steht aus.** Mit `scripts/eval-labs.sh` lässt sich das lokal messen; Brief und Ergebnis bleiben außerhalb des Repos.

## Grenzen

- Die Weiche für Fotos ist eine Faustregel. Ein Foto mit wenig Text, etwa ein Etikett, bleibt ein Bild. Das Chat-Modell sieht es trotzdem.
- Der Zahlenabgleich prüft, ob eine Zahl im Original vorkommt, nicht an welcher Stelle.
- Das Lesen kostet je Dokument eine Modellanfrage.
