# Prüfstand

Stand: 30.09.2026. Entwicklungsstand; kein vollständiges Meilenstein-Gate abgenommen.

## Belegte Ergebnisse

- Xcode 27.0 (27A266a), Simulator iPhone 17 / iOS 27 und physisches iPhone 17 Pro / iOS 26.6.1 (23G83).
- Signierter Gerätebuild, Installation und Gemma-E2B-Inferenz funktionieren. Modellrevision und SHA-256 sind gepinnt. Die ca. 3,55 GB Gewichte wurden nach zwei abgebrochenen Gerätedownloads auf dem Mac geprüft und in das App-Staging kopiert. In-App-Download/Resume ist damit **nicht** vollständig abgenommen.
- Frühere Text-Sparring-Version: 73 Tests ohne Fehler im Nachweis `evidence/ios-sparring-tests-2026-09-29.json` (37 Kerntests, 8 Online-Berichtstests, 9 Recorder-Tests, 14 Sparring-/Schnellchecktests, 5 UI-Tests). Frühere Nachweise mit 47 und 56 Tests bleiben erhalten. Enthalten sind echte SQLCipher-Verschlüsselung, Manipulations-/Fremdschlüsselprüfung, Migration, Transaktionsrollback, Quellen-/Zahlen-/Einheitenprüfung, begrenzte Reparatur, gespeicherte Teilberichte und UI-Speicherung nach Neustart.
- Ein tatsächlicher SQLite-`SQLITE_FULL` wird durch ein enges Seitenlimit injiziert, ohne das Gerätelaufwerk zu füllen. Der Fehler wird verständlich gemeldet; vorherige Fassung und Datenbankintegrität bleiben erhalten. Das ersetzt keine vollständige Betriebssystemprüfung bei knappem Gerätelaufwerk.
- Langer PDF-Export enthält die letzte Textpassage, mehrere Seiten und die Entwurfskennzeichnung.
- Deutsche SpeechAnalyzer-Dateitranskription: synthetische Audios von 30/120/300 Sekunden auf dem iPhone verarbeitet. Gesprochene Anteile ca. 24/97/242 Sekunden, übrige Zeit Stille. Kein Nachweis für echte Mikrofone, Nebengeräusche oder veterinärmedizinische Fachqualität.
- Zehn kurze Gemma-Berichtsläufe hintereinander erfolgreich; anschließend bewusster Abbruch und erfolgreiche neue Generierung. Lastresidenz 3130–3131 MiB, Spitze 3142 MiB, Laufzeiten 7,37–14,26 Sekunden, Modellladen 4,98 Sekunden. iOS-Thermik am Ende `fair`, keine kritische Stufe. Nachweis: `evidence/device-memory-10-rounds-2026-09-29.json`. Gilt für diesen kurzen synthetischen Fall, nicht als allgemeine Speicher-/Wärmegarantie.
- Echter Flugmodusversuch mit ausdrücklich ausgeschaltetem WLAN: `NWPathMonitor` meldet `unsatisfied`. Die 300-Sekunden-Datei liefert 112 Satzquellen und wird verschlüsselt gespeichert. Der Bericht wird wegen ungültigem JSON abgewiesen. Spitze 2088 MiB, Gesamtversuch 21,56 Sekunden, Thermik `fair`. Daher **kein erfolgreicher vollständiger Offlinepfad**. Nachweis: `evidence/device-offline-asr-report-rejected.json`.

## Reaktionen auf gefundene Fehler

**Sofortiger Aufnahmeabbruch:** Eigene Audio-Kategorieänderungen wurden bislang wie echte Unterbrechungen behandelt. Die Korrektur unterscheidet Ereignisgrund und Unterbrechungsbeginn/-ende, schützt Start/Sicherung gegen konkurrierende Aktionen und sichert den ursprünglichen Fallbezug. Neun Tests mit synthetischem Recorder und echten NotificationCenter-Ereignissen bestehen einschließlich Pause beim Segmentwechsel und fehlgeschlagener Speicherung. Details: `architecture/0003-recording-interruptions.md`. Signierter Gerätebuild installiert und normal gestartet (`evidence/device-audio-fix-install-2026-09-29.json`). Der Nutzer bestätigt nach Installation: „Aufnahme läuft jetzt“. Damit ist der sofortige Startabbruch auf dem echten iPhone behoben bestätigt. Lange Aufnahme, echte Unterbrechungen und ASR dieser Aufnahme sind damit noch nicht abgenommen.

Metadaten und UUIDs werden von der App gesetzt, nicht vom Modell erzeugt. Das Modell erhält kurze auftragsgebundene Quellen-IDs; Audio-/Zeitmetadaten bleiben außerhalb des Prompts. Satzweise Quellenprüfung verhindert das unbemerkte Weglassen kompletter Aussagen. Ein Reparaturversuch richtet sich nur auf unvollständige Quellen und erhält bereits geprüfte Aussagen. Scheitert er, entsteht kein scheinbar vollständiger Bericht. Fertige Abschnitte bleiben als ausdrücklich unvollständiger, nicht freigebbarer Zwischenstand gespeichert.

Die Fachwortliste speichert manuelle Vorschläge verschlüsselt. Übernahme ist ausdrücklich, ASR-Rohtext bleibt erhalten. Eine zusätzliche App-Authentifizierung/Face ID ist auf Nutzerwunsch entfernt; SQLCipher, Geräte-Keychain und Dateischutz bleiben aktiv.

## Erste Text-Sparring-Version, Schnellchecks und Löschbedienung

Die erste Version (inzwischen durch den Chat unten ersetzt) mit OpenAI-Streaming, bewusst ausgewähltem Verlauf, Versandvorschau, gespeicherten Entwürfen/Teilantworten und Abbruch ist technisch verbunden. Fallfreie Schnellchecks liegen separat verschlüsselt; Neustart und unveränderte Fallliste sind durch UI-Test belegt. Falllöschung funktioniert nach Wischen von rechts nach links sowie unten in der Fallansicht; „Behalten“ bricht die Bestätigung ab. Nach einer zusätzlichen Navigationskorrektur bestätigt ein gezielter UI-Test auch die Löschung aus einem geöffneten Diktat, die Rückkehr zur Fallliste und den Fortbestand der Löschung nach Neustart (`evidence/ios-nested-case-deletion-2026-09-29.json`). Drei Simulatoransichten wurden visuell geprüft: `evidence/case-swipe-right-to-left.png`, `evidence/case-delete-bottom.png`, `evidence/standalone-quick-check.png`.

Der erste UI-Lauf fand eine fehlende sichtbare Abbruchaktion beim Bestätigungs-Popover. Nach Umstellung auf einen nativen Alert mit explizitem „Behalten“ bestand der gesamte Lauf mit 73 Tests. Signierter aktueller Gerätebuild installiert und normal gestartet (`evidence/device-sparring-install-2026-09-29.json`). Keine echte Provideranfrage für diesen Nachweis; Streaming-Liveprüfung mit eigenem API-Key bleibt offen. Architektur und Grenzen: `architecture/0004-sparring-and-quick-checks.md`.

## Normaler Chat mit Anhängen

Auf Nutzerwunsch ersetzt eine normale Nachrichtenansicht die technischen Formulare. Fragen, automatischer Verlauf innerhalb desselben Chats, Plus-Menü für Fotos/Dateien, Senden/Abbrechen und verschlüsselte Entwürfe sind verbunden. API-/Modell-/Anfragedetails bleiben optional im Menü. Der Prompt verlangt passende dialogische Antworten statt eines starren Berichtsschemas.

Bildimport bewahrt das verschlüsselte Original und bereitet ein ausgerichtetes JPEG ohne EXIF/GPS vor. Datei-, Pixel- und Speichergrenzen greifen vor umfangreicher Verarbeitung. Der Requestbuilder prüft die gespeicherten Bildhashes und bezieht vorherige Bilder desselben Chats ein. PDF-/Textanhänge werden lokal ausgelesen und vor Versand überprüft; nur der geprüfte Text wird übertragen. Original und geprüfter Text bleiben getrennt. Architektur, Größenlimits und verbleibende Einschränkungen: `architecture/0005-conversational-chat-and-attachments.md`.

Prüfung: Der vollständige Lauf bestand mit 82 von 83 Tests; der zusätzliche Fototest verwendete zunächst einen unpassenden Selektor für den neuen iOS-Fotodialog (`evidence/ios-chat-full-tests-2026-09-29.json`). Nach dessen Korrektur zeigte der echte Importpfad, dass `os_proc_available_memory` im Simulator kein iPhone-App-Limit liefert. Wie im bestehenden MLX-Code wird diese Vorprüfung jetzt nur auf dem echten Gerät verwendet; Größen-/Pixelgrenzen gelten weiterhin überall. Danach bestanden alle zehn Anhangstests und der vollständige Fotoauswahl-UI-Test (`evidence/ios-chat-attachment-tests-2026-09-29.json`, elf Tests, null Fehler). Zusammen mit dem vorherigen Lauf sind damit 84 unterschiedliche Tests erfolgreich belegt; kein einzelner neuer Gesamtlauf mit 84 Tests behauptet. Foto-UI-Tests benötigen das vom Testskript eingespielte synthetische Bildschirmfoto.

Visuell geprüft: `evidence/normal-chat-composer.png` und `evidence/chat-with-image-attachment.png`. Signierter Gerätebuild auf dem iPhone 17 Pro installiert und normal gestartet (`evidence/device-chat-install-2026-09-29.json`). Keine echte OpenAI-Anfrage mit einem Nutzer-Key in diesen Nachweisen; Anbieterantworten auf echte Bild-/Chatfragen und klinische Qualität bleiben offen.


## Vereinfachte Navigation, Markdown und Teilen

Start, Fälle und Chat ersetzen die bisherige Navigation. Diktate führen durch Aufnahme, Textprüfung und Bericht. Einstellungen liegen am Zahnrad, neue unabhängige Chats sind direkt erreichbar und der Fallbezug bleibt im Chat sichtbar. Editoren und verspätete Speicher-/Exportaktionen tragen feste Fall-/Vorgangs-IDs. Architektur: `architecture/0006-navigation-markdown-and-sharing.md`.

Der Gesamtlauf enthält 86 erfolgreiche Unit-/Integrationstests und acht zunächst erfolgreiche UI-Tests; ein Navigationstest musste zuerst die Tastatur schließen (`evidence/ios-navigation-full-tests-2026-09-29.json`, 94/95). Der gezielte Folgelauf bestätigt diesen Navigationstest (`evidence/ios-navigation-targeted-tests-2026-09-29.json`); dessen weiterer Teilen-Test scheiterte am Selektor für die neue Systemansicht. Die ursprünglichen Teilen-Tests hatten fälschlich den Kopieren-Knopf unter der Systemansicht gefunden. Das wurde ausdrücklich korrigiert: Die echte iOS-Copy-Zelle wird angesprochen, nach Hintergrundwechsel betätigt und ihre Entfernung geprüft.

Beide endgültigen Teilen-Tests bestehen separat (`evidence/ios-chat-share-ui-tests-2026-09-29.json`, `evidence/ios-report-share-ui-tests-2026-09-29.json`). Direkt nach jedem einzelnen Lauf prüft `simctl pbpaste` den vollständigen synthetischen Text, Status, Zahlen/Negationen und das Fehlen von Markdown-Fettmarkierungen; es werden nur Prüfergebnisse gespeichert (`evidence/ios-chat-system-share-2026-09-29.json`, `evidence/ios-report-system-share-2026-09-29.json`). Lesen aus dem separaten XCTest-Runner wurde vom iOS-Zwischenablageschutz abgewiesen und deshalb nicht als Nachweis verwendet. Über die Läufe sind 95 unterschiedliche Tests erfolgreich belegt; kein einzelner komplett grüner Gesamtlauf wird behauptet.

Visuell geprüft: `evidence/start-two-primary-actions.png`, `evidence/focused-dictation-step.png`, `evidence/formatted-chat-answer.png`. Fett/Kursiv, Überschrift und Listen erscheinen formatiert. Die Teilenansicht übersteht den Appwechsel; aktuelle Exportdateien werden beim Zurückkehren nicht mehr sofort gelöscht. **Die tatsächliche WhatsApp-Übergabe auf dem Nutzergerät ist noch nicht bestätigt.** Ein ItemSource-Vertragstest mit dem WhatsApp-Aktivitätstyp ersetzt keine reale Share Extension.

Signierter Gerätebuild installiert und regulär ohne Testflags gestartet: `evidence/device-navigation-sharing-install-2026-09-29.json`. Die Nutzerprüfung von Teilen → WhatsApp ist angefragt.


## Design-Branch integriert am 30.09.2026

Auf Nutzerwunsch wurde `claude/optimized-ui-themes-animations-4a60zm` bei `02793da` vollständig übernommen: Kartenlayouts, Tierartensymbole, sechs Farbthemen, Tag/Nacht, animierte Hintergründe, Aufnahmetaste und Chatoberfläche. Die fachlichen Daten-/Providerpfade wurden dabei nicht verändert. Das Xcode-Projekt wurde mit XcodeGen neu erzeugt.

Der vollständige vorhandene Testlauf besteht jetzt mit **95 Tests, null Fehlern**, einschließlich der zuvor korrigierten Navigation und System-Teilenansicht (`evidence/ios-theme-integration-tests-2026-09-30.json`). Ein zusätzlicher UI-Test bestätigt den Wechsel zwischen Tag und Nacht, Auswahl von Ozean sowie Fortbestand beider Einstellungen nach Neustart (`evidence/ios-theme-persistence-test-2026-09-30.json`, ein Test, null Fehler). Anschließend stellt der Test seine Simulator-Einstellungen auf Automatisch/Klinik zurück. Zusammen: 96 unterschiedliche erfolgreiche Tests in zwei Läufen.

Visuell im Simulator geprüft: `evidence/theme-start-day-2026-09-30.png`, `evidence/theme-start-night-2026-09-30.png`, `evidence/theme-settings-2026-09-30.png`, `evidence/theme-dictation-2026-09-30.png` und `evidence/theme-chat-2026-09-30.png`. Die zugehörigen Bildschirmfotos enthalten ausschließlich synthetische Testdaten. Dies ersetzt weder eine vollständige Barrierefreiheitsabnahme noch den weiterhin offenen echten WhatsApp-Test.

Signierter Build auf dem iPhone 17 Pro erfolgreich installiert (`evidence/device-theme-install-2026-09-30.json`). Nach einem anfänglichen Verbindungsreset gelang die Installation beim zweiten Versuch. Der normale Appstart wurde vom gesperrten iPhone abgewiesen; Start/Sichtprüfung auf dem echten Gerät sind deshalb noch nicht bestätigt.


## Senior-Sparring-Persona am 30.09.2026

Der Nutzer hat die fachübergreifende Persona im Stil einer erfahrenen klinischen Kollegin bestätigt. Der Prompt priorisiert klinische Hypothesen, kritisch-kollegiale Rückfragen und entscheidungsrelevante nächste Schritte. Tierart, Kontext und Dringlichkeit sowie Grenzen bei Bildern und Dosierungsgrundlagen werden berücksichtigt. Er behauptet keine reale Qualifikation. Normaler Chatstil, Falltrennung, Befundtreue und das Verbot erfundener Quellen bleiben erhalten.

Gezielt erneut geprüft: **24 Chat-/Anhangstests, null Fehler** (`evidence/ios-senior-persona-tests-2026-09-30.json`). Der Prompt ist bytegleich im Simulator- und signierten iPhone-Bundle enthalten. Der Builder übernimmt ihn weiterhin als Anweisungen in den gespeicherten Request; die neue Persona gilt für neue Anfragen in neuen und bestehenden Chats. Bereits gespeicherte Antworten bleiben unverändert. Für diese Änderung wurde keine echte Provideranfrage ausgeführt: Die Prüfung belegt Einbindung und Anfrageverträge, keine klinische Antwortqualität.

Der signierte Build mit der neuen Persona wurde erfolgreich auf dem iPhone installiert und ohne Testflags normal gestartet (`evidence/device-senior-persona-install-2026-09-30.json`). Damit ist auch der zuvor durch die Bildschirmsperre blockierte Start des neuen Designstands erfolgt.

## Android-Start am 30.09.2026

Branch `claude/android-app`, Details in `architecture/0009-android-start.md`. Gebaut und getestet unter Linux mit JDK 21, Android SDK 37.2 und Gradle 9.8:

- `./gradlew :core:test`: 46 Tests ohne Fehler (portierte iOS-Kern- und Online-Vertragstests, gemeinsames Korpus, Schema, Prompt, iOS-kompatibles JSON).
- `./gradlew :app:testDebugUnitTest`: 18 Tests ohne Fehler (versiegelte Dateien; Room-Datenbank mit Transaktionen, Schlüsselschutz und Migration; Compose-UI-Tests auf Robolectric mit synthetischen Fällen). Zweimal wiederholt, stabil.
- Fallspeicher: Room mit SQLCipher 4.19.1, Passwort per Keystore-Schlüssel versiegelt. Native Bibliotheken aller ABIs sind auf 16-KB-Seiten ausgerichtet (`zipalign -P 16` und ELF-Prüfung). Der Gerätetest `SqlCipherDeviceTests` ist gebaut, aber nicht ausgeführt.
- `./gradlew :app:lintDebug`: keine Befunde. `assembleDebug` und `assembleRelease` (R8, unsigniert) bauen.
- Screenshots der UI-Tests: `evidence/android/`. Sie stammen aus Robolectric, nicht von einem Gerät.

Nicht geprüft: SQLCipher und Android-Keystore auf echter Hardware, Emulator, Pixel 9, echter OpenAI-Aufruf, Android-Teilen-Menü, Release-Build zur Laufzeit. Aufnahme/ASR, LiteRT-LM, Chat, PDF und Brave fehlen auf Android noch.

## Noch offen

| Phase | Stand | Fehlende Abnahme |
|---|---|---|
| P0 | Kurzer Modellpfad, Dateitranskription, Wiederholungen und Abbruch belegt | Vollständiger langer Offlinebericht, reale Aufnahme, weiterer Mischbetrieb |
| P1 | Lokaler Ablauf, Review/Export, Versionierung, Zwischenstände und Fachwortvorschläge verbunden | Durchgehende Audioverschlüsselung, Aufnahme-/Unterbrechungs-/Wiederherstellungstests, vollständiger Fachkorpus |
| P2 | OpenAI-Berichtspfad und Chat mit Bild-/PDF-/Textanhängen und Schnellchecks, Keychain-Konfiguration, dynamische Modellliste, explizite Auswahl und verschlüsselte Requestsnapshots implementiert; synthetische Tests bestanden | OpenAI-/Streaming-Liveprüfung mit eigenem Key; weitere Provider, strukturierte Labordaten/Redaktion, Audioanhänge, Brave/Quellen |
| P3 | Noch nicht implementiert | Native Android-App, LiteRT-LM/ASR, Sicherheit/Parität, Emulator und Pixel-9-Abnahme |
| P4 | Offen | Rückmeldungen, TestFlight, Lizenzen/Datenschutz/Releaseprüfung |

30 synthetische Textfälle unter `shared/fixtures/report-corpus-de.json` vorbereitet; noch kein vollständiger Modelllauf und keine tierärztliche Abnahme. API-Keys wurden nicht aus anderen Apps übernommen. Ohne eigene Liveprüfung keine Providerfreigabe behaupten.

## Neue Priorität: Online-Berichte

Nach der Nutzerentscheidung ist Gemma optional. Online wird nach Hinterlegen eines eigenen Keys und bewusster Aktivierung zum Standard; Moduswechsel bleiben ausdrücklich. [ADR 2](architecture/0002-online-default.md) beschreibt den Vertrag und offene Liveprüfung. Der lange lokale Bericht blieb trotz Verbesserungen bei einzelnen Format-/Rubrikfehlern blockiert; abgeschlossene Abschnitte wurden als Zwischenstände gespeichert. Keine vollständige lokale Langdiktatfreigabe behauptet.

Die Variante mit optionalem Offline-Modus und OpenAI-Berichten wurde erfolgreich für das iPhone gebaut, auf dem gekoppelten Gerät installiert und regulär gestartet. Aktueller Simulatornachweis: 47 Tests bestanden, 0 Fehler. Kein echter OpenAI-Berichtsrequest ohne eigens eingerichteten Nutzer-Key ausgeführt.


## Berichtszielgruppe und Berichtswissen im Chat – 30.09.2026

„Für wen?“ entfernt; neue Berichte leiten ihre Zielgruppe aus der Vorlage ab. Fallchats zeigen ihre Berichtsauswahl direkt am Eingabefeld. Der neueste Bericht wird initial vorausgewählt; zusätzliche Berichte desselben Falls lassen sich mit Textvorschau hinzufügen. Abwahl bleibt über Neustarts erhalten. Historische Anfragen speichern den verwendeten Berichtsstand; Folgefragen enthalten nur die aktuell ausgewählten Quelldokumente zusätzlich zum Chatverlauf.

Gezielter abschließender Lauf: **39 Tests bestanden, null Fehler** (19 Sparring-, zehn Anhang-, acht Onlineberichtstests und zwei UI-Tests). Nachweis: [ios-report-context-tests-2026-09-30.json](evidence/ios-report-context-tests-2026-09-30.json). Der erste Lauf hatte 37 erfolgreiche Vertragstests und einen UI-Testfehler beim Antippen der Mitte des zusammengesetzten Switch-Elements; der Test tippt nun den sichtbaren Schalter rechts und prüft dessen Zustand vor dem Schließen. Vorauswahl, Vorschau, Abwahl und Neustart bestanden schon im ersten Lauf. Der finale Lauf bestätigt zusätzlich erneute Auswahl und die bestehende Fallnavigation. Eine SwiftUI-Laufzeitwarnung zu einer ungültigen Frame-Dimension bleibt im Ergebnisprotokoll enthalten; keine fehlerfreie Accessibility-/Layoutabnahme behauptet.

[Auswahlansicht](evidence/case-reports-chat-knowledge-2026-09-30.png) visuell geprüft. Kein Live-API-Aufruf mit Nutzer-Key und keine klinische Qualitätsprüfung in diesem Nachweis. Architektur und Verhalten: [0008](architecture/0008-report-audience-and-chat-context.md).

Signierter Gerätebuild erfolgreich. Die Installation des Berichtswissen-Updates ist derzeit noch offen: Das gekoppelte iPhone wird als nicht erreichbar gemeldet (CoreDeviceError 4016). Der Nutzer wurde zum erneuten Verbinden/Entsperren aufgefordert. [Gerätenachweis](evidence/device-report-context-install-2026-09-30.json).
