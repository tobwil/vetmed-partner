# 0014: Online zuerst, lokal nur bei Bedarf

Datum: 08.11.2026

## Anlass

In der Praxis war die Qualität auf dem Gerät zu schwach:

- Die Android-Spracherkennung auf dem Pixel erkannte Fachsprache schlecht oder gar nicht.
- Lokale Berichte brauchen ein großes Modell und viel Zeit.
- Tabellen wie Laborbefunde lassen sich mit OCR und Fließtext nur fehleranfällig lesen.

Der Nutzer will deshalb: Online ist Standard für die beste Qualität, lokal ist nur eine Option für Bedarf.

## Entscheidung

### Grundsatz, der bleibt: kein stiller Wechsel

- Ist ein Online-Zugang eingerichtet, ist Online der Standard.
- Scheitert ein Online-Schritt, zeigt die App den Fehler. Darunter erscheinen zwei Knöpfe: „Erneut online“ und „Auf dem Gerät transkribieren“ bzw. „Offline-Bericht erstellen“.
- Die App wechselt nie von selbst und sendet bei Netzrückkehr nichts nach.

### Regeln (`Processing`, gleich in Kotlin und Swift)

| Schritt | Online, wenn … | sonst |
|---|---|---|
| Transkription | Gemini-Key vorhanden **und** einmal zugestimmt **und** nicht „Nur auf dem Gerät“ | Gerät; ohne Antwort auf die Zustimmungsfrage: einmal fragen |
| Bericht (Vorauswahl) | Online-Zugang aktiviert **und** Key vorhanden **und** nicht „Nur auf dem Gerät“ | Offline |
| Chat | immer online (unverändert) | – |

- **Einmalige Zustimmung:** Vor der ersten Online-Transkription fragt die App „Online transkribieren?“. Der Dialog sagt, was das Gerät verlässt (Audioteile), und weist darauf hin, dass für Patientendaten ein Key mit Abrechnung nötig ist. Die Antwort wird gespeichert (`GeminiTranscriptionConfiguration.decidedAt`).
- **Bestehende Installationen:** Ältere Speicherstände ohne `decidedAt` werden einmal gefragt, statt still umgestellt zu werden. Ein früheres ausdrückliches „an“ bleibt online.
- **„Nur auf dem Gerät verarbeiten“:** Der Schalter hat Vorrang vor allem anderen (`OnlineReportConfiguration.deviceOnly`). Der Chat braucht weiterhin den Online-Zugang.
- **Einstellungen:** Der Bereich „Verarbeitung“ steht ganz oben. Er zeigt in einem Satz, was gerade wo läuft.

### iOS bekommt Gemini

Bisher gab es Gemini nur auf Android (ADR 0012). Jetzt hat iOS dieselben Teile:

- **Anbieterwahl** OpenAI/Gemini für Berichte und Chat. Ein Gemini-Key im Schlüsselbund gilt auch für die Transkription.
- **`GeminiOnline.swift`:** Port von `GeminiOnline.kt` mit Berichtsanfrage (`responseSchema`), Chat-Stream (`streamGenerateContent?alt=sse`), Modellliste und Transkription in Sechserpaketen mit Wiederholung bei 429/5xx.
- **CAF zu WAV:** Der iOS-Recorder schreibt 16-Bit-PCM als CAF; Gemini nimmt WAV. Die Umwandlung ist eine reine Byte-Umsetzung ohne Audio-APIs.
- **Quellensuche:** Gibt es weiterhin nur mit OpenAI (ADR 0013). Eine mit Quellensuche vorbereitete Anfrage wird an Gemini nie ohne Suche gesendet.
- **Lokal bleibt wählbar:** SpeechAnalyzer bleibt die Option auf dem Gerät.

## Prüfung

- **Android:**
  - `ProcessingTests`: 4 Tests (Matrix, „Nur auf dem Gerät“, Berichtsmodus, alte Speicherstände)
  - drei UI-Tests: Zustimmungsfrage vor dem ersten Versand; Fehler mit Knopf „Auf dem Gerät“ ohne stillen Wechsel; Schalter „Nur auf dem Gerät“
  - Screenshots `15-online-fehler-geraet-anbieten.png` und `16-verarbeitung-einstellungen.png`
  - gesamt: Kern 107 Tests (1 übersprungen: Live-Prüfung ohne Key), App 49, Lint und Debug-Build grün
- **iOS:**
  - `OnlineFirstTests.swift` mit 6 Tests: Regeln, Schlüsselbund, Berichtsanfrage, Anbieterwahl, Chat-Stream, Transkription und CAF/WAV
  - Logik und Tests wurden unter Linux mit Swift 6.1 im Swift-6-Modus kompiliert und ausgeführt: bestanden
  - `VetAppModel` und SwiftUI-Dateien sind nur auf Syntax geprüft
  - Xcode-Build, XCTest und UI-Tests auf dem Mac stehen aus
- **Live mit echtem Gemini-Key:** steht aus, auf beiden Geräten. Zu prüfen:
  - Zustimmung
  - lange Aufnahme
  - Fehler ohne Netz
  - Bericht und Chat mit Gemini auf dem iPhone

## Grenzen

- Online-Qualität hängt vom Anbieter und Modell ab. Auch online erstellte Texte sind Entwürfe und fachlich zu prüfen.
- Im kostenlosen Gemini-Kontingent darf Google Eingaben nutzen. Für Patientendaten ist ein Key mit Abrechnung nötig; die App weist darauf hin, kann es aber nicht prüfen.
