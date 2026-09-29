# Prüfstand

Stand: 29.09.2026. Entwicklungsstand; kein vollständiges Meilenstein-Gate abgenommen.

## Belegte Ergebnisse

- Xcode 27.0 (27A266a), Simulator iPhone 17 / iOS 27 und physisches iPhone 17 Pro / iOS 26.6.1 (23G83).
- Signierter Gerätebuild, Installation und Gemma-E2B-Inferenz funktionieren. Modellrevision und SHA-256 sind gepinnt. Die ca. 3,55 GB Gewichte wurden nach zwei abgebrochenen Gerätedownloads auf dem Mac geprüft und in das App-Staging kopiert. In-App-Download/Resume ist damit **nicht** vollständig abgenommen.
- Simulator: 73 Tests ohne Fehler im aktuellen Nachweis `evidence/ios-sparring-tests-2026-09-29.json` (37 Kerntests, 8 Online-Berichtstests, 9 Recorder-Tests, 14 Sparring-/Schnellchecktests, 5 UI-Tests). Frühere Nachweise mit 47 und 56 Tests bleiben erhalten. Enthalten sind echte SQLCipher-Verschlüsselung, Manipulations-/Fremdschlüsselprüfung, Migration, Transaktionsrollback, Quellen-/Zahlen-/Einheitenprüfung, begrenzte Reparatur, gespeicherte Teilberichte und UI-Speicherung nach Neustart.
- Ein tatsächlicher SQLite-`SQLITE_FULL` wird durch ein enges Seitenlimit injiziert, ohne das Gerätelaufwerk zu füllen. Der Fehler wird verständlich gemeldet; vorherige Fassung und Datenbankintegrität bleiben erhalten. Das ersetzt keine vollständige Betriebssystemprüfung bei knappem Gerätelaufwerk.
- Langer PDF-Export enthält die letzte Textpassage, mehrere Seiten und die Entwurfskennzeichnung.
- Deutsche SpeechAnalyzer-Dateitranskription: synthetische Audios von 30/120/300 Sekunden auf dem iPhone verarbeitet. Gesprochene Anteile ca. 24/97/242 Sekunden, übrige Zeit Stille. Kein Nachweis für echte Mikrofone, Nebengeräusche oder veterinärmedizinische Fachqualität.
- Zehn kurze Gemma-Berichtsläufe hintereinander erfolgreich; anschließend bewusster Abbruch und erfolgreiche neue Generierung. Lastresidenz 3130–3131 MiB, Spitze 3142 MiB, Laufzeiten 7,37–14,26 Sekunden, Modellladen 4,98 Sekunden. iOS-Thermik am Ende `fair`, keine kritische Stufe. Nachweis: `evidence/device-memory-10-rounds-2026-09-29.json`. Gilt für diesen kurzen synthetischen Fall, nicht als allgemeine Speicher-/Wärmegarantie.
- Echter Flugmodusversuch mit ausdrücklich ausgeschaltetem WLAN: `NWPathMonitor` meldet `unsatisfied`. Die 300-Sekunden-Datei liefert 112 Satzquellen und wird verschlüsselt gespeichert. Der Bericht wird wegen ungültigem JSON abgewiesen. Spitze 2088 MiB, Gesamtversuch 21,56 Sekunden, Thermik `fair`. Daher **kein erfolgreicher vollständiger Offlinepfad**. Nachweis: `evidence/device-offline-asr-report-rejected.json`.

## Reaktionen auf gefundene Fehler

**Sofortiger Aufnahmeabbruch:** Eigene Audio-Kategorieänderungen wurden bislang wie echte Unterbrechungen behandelt. Die Korrektur unterscheidet Ereignisgrund und Unterbrechungsbeginn/-ende, schützt Start/Sicherung gegen konkurrierende Aktionen und sichert den ursprünglichen Fallbezug. Neun Tests mit synthetischem Recorder und echten NotificationCenter-Ereignissen bestehen einschließlich Pause beim Segmentwechsel und fehlgeschlagener Speicherung. Details: `architecture/0003-recording-interruptions.md`. Signierter Gerätebuild installiert und normal gestartet (`evidence/device-audio-fix-install-2026-09-29.json`). Der Nutzer bestätigt nach Installation: „Aufnahme läuft jetzt“. Damit ist der sofortige Startabbruch auf dem echten iPhone behoben bestätigt. Lange Aufnahme, echte Unterbrechungen und ASR dieser Aufnahme sind damit noch nicht abgenommen.

Metadaten und UUIDs werden von der App gesetzt, nicht vom Modell erzeugt. Das Modell erhält kurze auftragsgebundene Quellen-IDs; Audio-/Zeitmetadaten bleiben außerhalb des Prompts. Satzweise Quellenprüfung verhindert das unbemerkte Weglassen kompletter Aussagen. Ein Reparaturversuch richtet sich nur auf unvollständige Quellen und erhält bereits geprüfte Aussagen. Scheitert er, entsteht kein scheinbar vollständiger Bericht. Fertige Abschnitte bleiben als ausdrücklich unvollständiger, nicht freigebbarer Zwischenstand gespeichert.

Die Fachwortliste speichert manuelle Vorschläge verschlüsselt. Übernahme ist ausdrücklich, ASR-Rohtext bleibt erhalten. Eine zusätzliche App-Authentifizierung/Face ID ist auf Nutzerwunsch entfernt; SQLCipher, Geräte-Keychain und Dateischutz bleiben aktiv.

## Text-Sparring, Schnellchecks und Löschbedienung

Text-Sparring mit OpenAI-Streaming, bewusst ausgewähltem Verlauf, Versandvorschau, gespeicherten Entwürfen/Teilantworten und Abbruch ist technisch verbunden. Fallfreie Schnellchecks liegen separat verschlüsselt; Neustart und unveränderte Fallliste sind durch UI-Test belegt. Falllöschung funktioniert nach Wischen von rechts nach links sowie unten in der Fallansicht; „Behalten“ bricht die Bestätigung ab. Nach einer zusätzlichen Navigationskorrektur bestätigt ein gezielter UI-Test auch die Löschung aus einem geöffneten Diktat, die Rückkehr zur Fallliste und den Fortbestand der Löschung nach Neustart (`evidence/ios-nested-case-deletion-2026-09-29.json`). Drei Simulatoransichten wurden visuell geprüft: `evidence/case-swipe-right-to-left.png`, `evidence/case-delete-bottom.png`, `evidence/standalone-quick-check.png`.

Der erste UI-Lauf fand eine fehlende sichtbare Abbruchaktion beim Bestätigungs-Popover. Nach Umstellung auf einen nativen Alert mit explizitem „Behalten“ bestand der gesamte Lauf mit 73 Tests. Signierter aktueller Gerätebuild installiert und normal gestartet (`evidence/device-sparring-install-2026-09-29.json`). Keine echte Provideranfrage für diesen Nachweis; Streaming-Liveprüfung mit eigenem API-Key bleibt offen. Architektur und Grenzen: `architecture/0004-sparring-and-quick-checks.md`.

## Noch offen

| Phase | Stand | Fehlende Abnahme |
|---|---|---|
| P0 | Kurzer Modellpfad, Dateitranskription, Wiederholungen und Abbruch belegt | Vollständiger langer Offlinebericht, reale Aufnahme, weiterer Mischbetrieb |
| P1 | Lokaler Ablauf, Review/Export, Versionierung, Zwischenstände und Fachwortvorschläge verbunden | Durchgehende Audioverschlüsselung, Aufnahme-/Unterbrechungs-/Wiederherstellungstests, vollständiger Fachkorpus |
| P2 | OpenAI-Berichtspfad und Text-Sparring mit Schnellchecks, Keychain-Konfiguration, dynamische Modellliste, explizite Auswahl und verschlüsselte Requestsnapshots implementiert; synthetische Tests bestanden | OpenAI-/Streaming-Liveprüfung mit eigenem Key; weitere Provider, Anhänge/Labor/Redaktion, Brave/Quellen |
| P3 | Noch nicht implementiert | Native Android-App, LiteRT-LM/ASR, Sicherheit/Parität, Emulator und Pixel-9-Abnahme |
| P4 | Offen | Rückmeldungen, TestFlight, Lizenzen/Datenschutz/Releaseprüfung |

30 synthetische Textfälle unter `shared/fixtures/report-corpus-de.json` vorbereitet; noch kein vollständiger Modelllauf und keine tierärztliche Abnahme. API-Keys wurden nicht aus anderen Apps übernommen. Ohne eigene Liveprüfung keine Providerfreigabe behaupten.

## Neue Priorität: Online-Berichte

Nach der Nutzerentscheidung ist Gemma optional. Online wird nach Hinterlegen eines eigenen Keys und bewusster Aktivierung zum Standard; Moduswechsel bleiben ausdrücklich. [ADR 2](architecture/0002-online-default.md) beschreibt den Vertrag und offene Liveprüfung. Der lange lokale Bericht blieb trotz Verbesserungen bei einzelnen Format-/Rubrikfehlern blockiert; abgeschlossene Abschnitte wurden als Zwischenstände gespeichert. Keine vollständige lokale Langdiktatfreigabe behauptet.

Die Variante mit optionalem Offline-Modus und OpenAI-Berichten wurde erfolgreich für das iPhone gebaut, auf dem gekoppelten Gerät installiert und regulär gestartet. Aktueller Simulatornachweis: 47 Tests bestanden, 0 Fehler. Kein echter OpenAI-Berichtsrequest ohne eigens eingerichteten Nutzer-Key ausgeführt.
