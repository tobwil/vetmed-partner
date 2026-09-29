# Aufnahme: eigene Sessionänderung löste sofortigen Abbruch aus

29.09.2026. Nutzerbefund: „Audioaufnahmen gehen sofort auf abgebrochen.“

## Ursache und Korrektur

Der bisherige Observer behandelte sämtliche `routeChangeNotification`- und `interruptionNotification`-Ereignisse gleich. Das beim Start aufgerufene `setCategory(.playAndRecord)` kann selbst eine Meldung mit `categoryChange` auslösen. Der zusätzliche MainActor-Task verarbeitete diese teils erst nach `record()`, sah eine laufende Aufnahme und pausierte sie. Auch eine Meldung über das **Ende** einer Unterbrechung stoppte bislang die Aufnahme.

Die neue Klassifizierung berücksichtigt den Grund. Eigene Kategorieänderungen, Overrides und reine Route-Konfigurationen pausieren nicht. Ein tatsächlich gestoppter Recorder wird weiterhin im 200-ms-Statuscheck erkannt. Beginn einer Unterbrechung, neue/entfernte Audiogeräte, fehlende geeignete Route und Verlust/Reset des Audiodiensts sichern und pausieren. Es gibt kein automatisches Wiederaufnehmen des Mikrofons. Der konkrete Unterbrechungsgrund wird angezeigt.

Ein Aufnahmelauf besitzt eine Generation, sodass bereits eingeplante Observer-Aktionen keinen späteren Lauf abbrechen. Während Start und Sicherung ist der Wechsel des Falls gesperrt. Die Startaktion ist bereits vor dem ersten asynchronen Speichern gegen Doppeltippen geschützt; Callbacks verwenden die ursprünglichen Fall-/Vorgangs-IDs. Eine etwaige Audiowiedergabe wird vor dem Start beendet.

Pause wartet auf eine bereits laufende Segmentsicherung mittels Continuation, nicht durch Polling im abgebrochenen Task. Ein neuer Start kann diese Sicherung nicht überholen. Fehlgeschlagene Sicherung lässt die geschützte CAF zur Wiederherstellung liegen. Die bisherige Einschränkung bleibt: aktive CAFs sind durch iOS-Dateischutz geschützt, erst abgeschlossene Segmente werden separat mit AES-GCM verschlüsselt; Segmentwechsel sind noch nicht nachweislich lückenlos.

## Nachweise und Grenze

Neun neue `AudioRecorderTests` betreiben die produktive Recorder-Steuerung mit einer injizierten synthetischen Dateiquelle und einem eigenen NotificationCenter. Sie prüfen verzögerten Kategorie-/Override-/Konfigurationswechsel, Unterbrechungsbeginn/-ende, Headsetverlust, manuelles Fortsetzen, Audiodienst-Reset, ausstehende/fehlgeschlagene Sicherung, Pause beim 20-Sekunden-Segmentwechsel, fehlende Berechtigung/inaktive App, zu wenig Speicher und Wiederöffnen im richtigen verschlüsselten Fallspeicher. Dabei wird kein Mikrofon geöffnet.

Der gezielte Lauf bestand 9/9. Der umfassende Simulatorlauf und der echte Nachtest auf dem iPhone werden getrennt in `test-status.md` nachgeführt. Diese Tests beweisen die Steuerungslogik und Speicherung, nicht die Qualität eines realen Mikrofons oder eine lückenlose Aufnahme unter jeder iOS-Unterbrechung.

Primärquellen: [Apple: Audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes), [categoryChange](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason/categorychange), [Audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions). Der aktuelle Gerätepfad unterstützt iOS 26; die neuen iOS-27-Lifecycle-APIs sind hierfür nicht vorausgesetzt.
