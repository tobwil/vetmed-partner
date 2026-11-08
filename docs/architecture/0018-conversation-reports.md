# 0018: Berichte aus Gesprächen

Datum: 08.11.2026

## Anlass

Ein Bericht aus einem aufgenommenen Gespräch scheiterte, ein Diktat nicht. Zwei Ursachen:

1. **Jeder Satz musste belegt sein.** Die Pipeline verlangte, dass jede Quelle des Transkripts in mindestens einer Berichtsaussage vorkommt. Begrüßung, Smalltalk und Füllwörter („Okay, genau.“) lassen sich aber nicht sinnvoll in einen Befundbericht übernehmen. Das Modell ließ sie weg, die Prüfung meldete fehlende Quellen und nach dem einen Reparaturversuch brach der Bericht ab.
2. **Das Budget war zu klein.** Online wurden höchstens 24 Sätze pro Anfrage und 12 Anfragen pro Bericht verarbeitet. Ein Gespräch von 30 Minuten hat leicht 300 Sätze.

## Entscheidung

**Sichtbares Auslassen statt stillem Weglassen.**

- Der Prompt `shared/prompts/report-v2.txt` (vorher `report-v1.txt`) erlaubt dem Modell, Sätze ohne fachlichen Inhalt unter `skipped` mit Quellen-ID und kurzem Grund aufzuführen. Im Zweifel gehört ein Satz in den Bericht.
- Beide Anbieter-Schemas (OpenAI strict, Gemini) haben dafür das Feld `skipped`. Quellen-IDs sind auf die IDs der Anfrage begrenzt; unbekannte IDs zählen nicht.
- Die App entscheidet, ob ein Satz wirklich ausgelassen werden darf (`ReportSkipPolicy`). Nie ausgelassen werden Sätze mit
  - einer Zahl („3 Tage“, „0,1 mg/kg“),
  - einem Zahlwort („drei Tage“, „zwölf Kilo“, „zweimal täglich“, „eine halbe Tablette“),
  - einer Verneinung („kein Erbrechen“, „nicht schlimm“).
- Will das Modell so einen Satz auslassen, verlangt die Reparatur genau diesen Satz mit der Begründung „enthalten Zahlen oder Verneinungen und dürfen nicht ausgelassen werden“.
- Ausgelassene Sätze landen im Bericht unter `omitted`, nicht im Berichtstext. Die Prüfansicht zeigt sie unter **„Nicht übernommen · bitte prüfen“**, dazu der Prüfhinweis „N Sätze wurden als nicht fachlich ausgelassen“. Gehört ein Satz doch hinein, ergänzt man ihn im Text.
- Besteht ein Gespräch nur aus Smalltalk, entsteht kein leerer Bericht. Die App meldet „In der Aufnahme wurden keine fachlichen Angaben gefunden“; das Transkript bleibt erhalten.

**Größere Abschnitte, größeres Budget (nur online).** Pro Anfrage gehen bis zu 60 Sätze oder 20.000 Zeichen, pro Bericht höchstens 40 Anfragen (`MAX_CALLS` bzw. `reportMaxCalls`). Das reicht für rund 20 Abschnitte mit je einem Reparaturversuch, also ein Gespräch von etwa einer Stunde. Das lokale Modell bleibt bei seinen kleinen Abschnitten.

**Unverändert:** Jede übernommene Aussage braucht weiter ein wörtliches Zitat. Zahlen, Einheiten, Vergleichszeichen und Verneinungen werden weiter gegen das Zitat geprüft. Freigabe bleibt Pflicht.

## Daten

- `StructuredReport.omitted` ist optional. Alte Berichte bleiben lesbar.
- `ReportVersion.promptVersion` ist für neue Berichte `report-v2`.
- `shared/schemas/report-v1.schema.json` kennt `omitted` als optionales Feld; die Schemaversion bleibt 1.

## Prüfung

- **Android:**
  - `ConversationReportTests`: 5 Tests:
    - synthetisches Sprechstundengespräch: Smalltalk wird sichtbar ausgelassen, alle fachlichen Sätze bleiben;
    - eine Dosis kann nicht ausgelassen werden;
    - Zahlwörter und Verneinungen;
    - reiner Smalltalk;
    - Anbieter-Schemas.
  - gesamt: Kern 138 Tests (2 übersprungen), App 52, Lint und Build grün
- **iOS:**
  - `ConversationReportTests.swift` mit denselben 5 Fällen. Unter Linux mit Swift 6.1 zusammen mit den Labor-, Live- und Online-Tests gebaut und ausgeführt: 29/29.
  - Gefunden und behoben:
    - Swifts `JSONEncoder` schrieb „mg/kg“ als „mg\/kg“ in den Prompt. Die Quellen gehen jetzt unverändert an das Modell.
    - Ein langer Ausdruck in `StructuredReport.text` war für den Typprüfer zu teuer.
  - Die Prüfansicht ist nur auf Syntax geprüft. **Vor `main`:** `./scripts/test-ios.sh` auf dem Mac.
- **Mit echtem Gespräch und Key steht aus.**

## Grenzen

- Ein fachlicher Satz ohne Zahl und ohne Verneinung, etwa „Er kratzt sich viel“, kann vom Modell ausgelassen werden. Er ist dann nicht verloren: Er steht in der Liste „Nicht übernommen“, die vor der Freigabe zu prüfen ist.
- Wer was gesagt hat, unterscheidet die App nicht. Ein Gespräch ist für den Bericht ein Text.
- Das Budget von 40 Anfragen ist eine feste Grenze. Längere Aufnahmen bitte in mehrere Vorgänge teilen; gesicherte Abschnitte bleiben beim Abbruch erhalten.
