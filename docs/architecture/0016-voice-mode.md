# 0016: Sprachmodus mit Gemini 3.8 Live

Datum: 08.11.2026

## Anlass

Im Praxisalltag sind oft die Hände nicht frei. Der Nutzer wünscht sich, Fälle sprechend mit dem Sparringspartner zu besprechen, mit Gemini 3.8 Live.

## Entscheidung

### Verbindung und Anmeldung

- **Modell:** `gemini-3.8-live` über WebSocket `BidiGenerateContent`. Die Live API ist laut Anbieter noch Preview.
- **Einmal-Token statt Key:** Die App erzeugt mit dem Gemini-Key einen Einmal-Token (`POST v1beta/auth_tokens`):
  - `uses: 1`
  - 30 Minuten gültig, 1 Minute für den Sitzungsstart
  - an das Modell gebunden
  - Der Key steht nur im Header dieser Anfrage. Die Sprachverbindung (`BidiGenerateContentConstrained?access_token=…`) sieht ihn nie.
- **Setup:**
  - Sparring-Prompt mit Arzneimittel- und Laborregeln, dazu „Quellensuche: nicht aktiviert“ und der Prompt `shared/prompts/voice-v2.txt`. Er verlangt kurze, gesprochene Sätze, ausgesprochene Zahlen, Nachfragen bei Unverstandenem statt Raten und ausschließlich Deutsch (seit v2, siehe Grenzen).
  - Fallkontext: ausgewählte Berichte, Falltext und bestätigte Labortabellen des Chats, höchstens 60.000 Zeichen.
  - Mitschrift beider Seiten. Die Eingabe hat den Sprachhinweis `de-DE` und die eigene Fachwortliste (`customVocabulary`, höchstens 100 Begriffe).
  - `contextWindowCompression.slidingWindow` hebt die 15-Minuten-Grenze für Audio auf; `sessionResumption` ist an.
- **Keine Websuche:** Google Search lässt sich in Live nicht auf amtliche Seiten begrenzen (vgl. ADR 0013).
- **Fortsetzen:** Kündigt der Server mit `goAway` das Ende der Verbindung an (~10 min), baut die App mit neuem Token und dem letzten `newHandle` eine neue Verbindung auf. Inhalte werden dabei nicht neu gesendet.
- **Kein automatischer Neustart:** Bei Netzverlust endet das Gespräch sichtbar. Ein `goAway` ohne Handle wird ebenfalls nicht fortgesetzt.

### Audio

| | Android | iOS |
|---|---|---|
| Mikrofon (16 kHz, 16 Bit, mono) | `AudioRecord` `VOICE_COMMUNICATION`, `AcousticEchoCanceler`, `NoiseSuppressor` | `AVAudioEngine` mit Voice-Processing (`.voiceChat`) |
| Wiedergabe (24 kHz) | `AudioTrack` `USAGE_VOICE_COMMUNICATION` | `AVAudioPlayerNode` |
| Unterbrechung | Server meldet `interrupted` oder Knopf „Unterbrechen“: Warteschlange sofort leeren; der Rest der laufenden Antwort wird verworfen | wie Android |
| WebSocket | OkHttp 4.12.0 (Android hat keinen eingebauten Client) | `URLSessionWebSocketTask` |

- Audio liegt nur im Arbeitsspeicher. Es wird nie gespeichert.
- Beim Verlassen der App endet das Gespräch, und die Mitschrift wird gespeichert.

### Bedienung und Speicherung

- **Starten:** Im Chat gibt es einen Knopf „Sprechen“, sobald ein Gemini-Key hinterlegt ist. Vor dem ersten Gespräch fragt die App einmal um Zustimmung. Der Dialog sagt, was gesendet wird, was es kostet und dass für Patientendaten ein Key mit Abrechnung nötig ist.
- **Während des Gesprächs:**
  - Ein Kreis zeigt den Pegel.
  - Darunter steht die Live-Mitschrift.
  - Es gibt die Knöpfe Stumm, Unterbrechen und „Beenden und Mitschrift speichern“.
  - Dauer und geschätzte Kosten werden angezeigt (0,5 ct/min Eingabe, 1,8 ct/min Ausgabe, bezahltes Kontingent).
- **Nach dem Gespräch:**
  - Die Mitschrift wird als Chat-Eintrag „Sprachgespräch“ verschlüsselt gespeichert. Ein Hinweis sagt, dass der Wortlaut abweichen kann; dazu kommen Dauer und Kosten.
  - Arzneimittelwarnung und Export gelten wie bei jeder Antwort.
  - Die Mitschrift kann als Verlauf in späteren Chat-Nachrichten verwendet werden.

## Prüfung

- **Android:**
  - `GeminiLiveTests` mit 9 Tests über eine Fake-Verbindung: Token, Setup, Nachrichten, Mitschrift, Kosten, Fortsetzen nach `goAway`, späte Nachrichten der alten Verbindung, Netzverlust, `goAway` ohne Handle, abgewiesener Token, lokales Unterbrechen
  - UI-Test: Zustimmung, Verbindung, Audio hin und zurück, Unterbrechen, Beenden und gespeicherte Mitschrift. Screenshot `18-sprachmodus.png`.
  - gesamt: Kern 130 (2 übersprungen: Live-Prüfungen ohne Key), App 51, Lint und Build grün
- **iOS:**
  - `GeminiLiveTests.swift` mit 7 Tests; mit den Labor- und Online-Tests unter Linux mit Swift 6.1 im Swift-6-Modus gebaut und ausgeführt: 22/22 bestanden
  - `VoiceAudio`, `VoiceView` und die Anbindung im Chat sind nur auf Syntax geprüft. Der Mikrofon-Callback läuft bewusst außerhalb des Main Actors, sonst bricht Swift 6 zur Laufzeit ab.
- **Live mit echtem Key: steht aus.** Diese Punkte sind in der Dokumentation nicht eindeutig und werden erst dabei bestätigt:
  - die genaue URL für Einmal-Tokens (`BidiGenerateContentConstrained`)
  - die Form des Token-Bodys (`bidiGenerateContentSetup` statt `liveConnectConstraints`)
  - Text- oder Binär-Frames (beide werden gelesen)
  - der Platz von `speechConfig` im Setup
  - die deutsche Aussprache
  - Abweichungen sind jeweils eine Konstante in `GeminiLive`.

## Grenzen

- Die Live API ist Preview. Formate können sich ändern.
- Gemini wählt die Sprache selbst; die App setzt keinen Sprachcode für die Ausgabe. Auf dem Pixel 9a antwortete v1 bei undeutlicher Eingabe auf Französisch und Hindi. Seit `voice-v2` verlangt der Prompt ausdrücklich nur Deutsch und bei fremd klingender oder unverständlicher Eingabe eine Rückfrage auf Deutsch. Das senkt das Risiko, garantiert es aber nicht.
- Die Mitschrift ist eine Spracherkennung und kann vom Gesagten abweichen.
- Ohne Websuche kann der Sprachmodus Präparatangaben nicht amtlich belegen; die Prompt-Regeln aus ADR 0013 gelten.
