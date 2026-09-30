# Technische Übergabe

## Stand und verbindliche Nutzerentscheidungen

Neuester Quellstand: Berichtszielgruppe automatisch aus Vorlage und auswählbare Fallberichte im Chat. 39 gezielte Tests bestanden, signierter Gerätebuild erfolgreich. Installation dieses Updates wartet auf das derzeit nicht erreichbare iPhone; zuvor installiert bleibt der Senior-Persona-Stand. Nachweis: `docs/evidence/device-report-context-install-2026-09-30.json`.

Die native iOS-App ist implementiert und auf dem iPhone 17 Pro installiert. Der Designstand aus `02793da` wurde am 30.09.2026 um die bestätigte Senior-Sparring-Persona ergänzt, erfolgreich installiert und normal gestartet. Prompt- und Binary-Hashes: `docs/evidence/device-senior-persona-install-2026-09-30.json`. Die App heißt VetMed, Bundle `de.tobwil.vetmed`. Der gesamte Zielumfang bleibt im [Plan](../implementation-plan.md) und der [Nachverfolgung](../requirements-trace.md) erhalten.

Aktuelle Nutzerentscheidungen:

- Keine Face ID oder zusätzliche biometrische App-Sperre.
- Online-Berichte nach bewusster Einrichtung/Aktivierung des eigenen API-Keys als Standard; Offline-Modell optional, kein stiller Fallback.
- Normaler Chat mit Fragen/Bildern/Befunden; unabhängige Gespräche ohne Fall möglich. Die Persona arbeitet im Stil einer erfahrenen klinischen Kollegin, fachübergreifend und kritisch mitdenkend.
- Berichtszielgruppe automatisch aus der Vorlage; nur „Information für Tierhalter“ verwendet Tierhaltersprache.
- Fallchat mit sichtbarer, gespeicherter Berichtsauswahl; neuester Bericht bei der ersten Öffnung vorausgewählt, weitere Berichte desselben Falls auswählbar. Details: [0008](../architecture/0008-report-audience-and-chat-context.md).
- Falllöschung durch Wischen von rechts nach links oder unten im Fall.
- Start/Fälle/Chat, schrittweises Diktat und sichtbare Fallzuordnung.
- Chatformatierung rendern und vollständigen Inhalt über Teilen an andere Apps übergeben.

Letzte offene Rückfrage: Erscheint nach Teilen → WhatsApp der vollständige Text im WhatsApp-Entwurf? Die neue Version ist installiert; eine Nutzerbestätigung liegt zum Archivstand nicht vor. „Aufnahme läuft jetzt“ wurde für die vorherige Aufnahme-Korrektur ausdrücklich bestätigt.

## Orientierung im Code

| Bereich | Einstieg |
|---|---|
| App-Lebenszyklus, Root-Navigation, Bericht prüfen/teilen | [VetMedApp.swift](../../apps/ios/VetMed/Views/VetMedApp.swift) |
| Start, Fallliste und Falldetails | [NavigationViews.swift](../../apps/ios/VetMed/Views/NavigationViews.swift) |
| Aufnahme → Text → Bericht | [EncounterWorkflowView.swift](../../apps/ios/VetMed/Views/EncounterWorkflowView.swift) |
| Chat, Anhänge, Composer | [SparringView.swift](../../apps/ios/VetMed/Views/SparringView.swift) |
| Zustandsübergänge und feste Fall-/Vorgangszuordnung | [VetAppModel.swift](../../apps/ios/VetMed/Core/VetAppModel.swift), [NavigationContext.swift](../../apps/ios/VetMed/Core/NavigationContext.swift) |
| Markdown und System-Teilen | [ChatMarkdown.swift](../../apps/ios/VetMed/Core/ChatMarkdown.swift), [ActivitySheet.swift](../../apps/ios/VetMed/Views/ActivitySheet.swift), [ExportService.swift](../../apps/ios/VetMed/Services/ExportService.swift) |
| Persistenz, Aufnahme, ASR, Engines und Provider | [Services](../../apps/ios/VetMed/Services/) |
| Datenmodell, Quellen-/Berichtsvertrag und Chatrequests | [Core](../../apps/ios/VetMed/Core/) |
| Unit-/Integrationstests | [VetMedTests](../../apps/ios/VetMedTests/) |
| End-to-End-Oberflächentests | [WorkflowTests.swift](../../apps/ios/VetMedUITests/WorkflowTests.swift) |
| Schemas, Prompts und synthetischer Korpus | [shared](../../shared/) |

## Build und Tests

Entwicklungsumgebung dieses Stands: Xcode 27.0 (27A266a), Swift 6.4, XcodeGen; Simulator iPhone 17 / iOS 27. Physisches Ziel: iPhone 17 Pro / iOS 26.6.1. Mindestziel iOS 26. Modellinferenz erfordert das reale Metal-Gerät und ausreichend RAM. Signing-Team in `apps/ios/project.yml` an das eigene Konto anpassen.

```sh
xcodegen generate --spec apps/ios/project.yml
./scripts/test-ios.sh
```

Das Testskript spielt ein synthetisches Bild für den Fotos-Picker ein. Die UI-Tests nutzen `--ui-testing` und einen separaten verschlüsselten Speicher. `--ui-testing-share-fixture` ergänzt ausschließlich dort einen synthetischen Bericht und eine formatierte Chatantwort. Für normale Geräteinstallation keine Testflags verwenden.

Gezielter UI-Test für Textübergabe, anschließend Prüfung der Simulator-Zwischenablage:

```sh
xcodebuild -project apps/ios/VetMed.xcodeproj -scheme VetMed \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/ios \
  -skipPackagePluginValidation -skipMacroValidation \
  -collect-test-diagnostics never \
  -only-testing:VetMedUITests/WorkflowTests/testReportShareSheetRetainsTextAndReportAfterAppSwitch test
xcrun simctl pbpaste 'iPhone 17'
```

Für Chat entsprechend `testMarkdownAnswerAndSharingSurviveAppSwitch`. Die Zwischenablage unmittelbar nach dem einzelnen Test prüfen, bevor ein anderer UI-Test sie verändern kann. Der Bericht endet auf `ENDE-DES-TESTBERICHTS`, der Chat auf `ENDE-DER-TESTANTWORT`. Der separate XCTest-Runner darf die Zwischenablage nicht zuverlässig direkt lesen; ein Zugriff dort wurde vom System abgewiesen.

Gerätebuild:

```sh
xcodebuild -project apps/ios/VetMed.xcodeproj -scheme VetMed \
  -destination 'generic/platform=iOS' -derivedDataPath .build/ios \
  -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates build
```

Build-/Testprozesse mit demselben DerivedData-Verzeichnis sequenziell ausführen. Der vorliegende signierte Build wurde per `devicectl` installiert und ohne Argumente gestartet. Die Hashes von Binary und relevanten Quellen stehen im [Installationsnachweis](../evidence/device-navigation-sharing-install-2026-09-29.json).

## Grenzen, die nicht übergangen werden dürfen

Der Prüfstand enthält auch gescheiterte Tests und korrigierte Selektoren. Der Designstand vom 30.09.2026 besteht den vollständigen bisherigen Lauf mit 95 Tests sowie einen separaten zusätzlichen UI-Test für Darstellungseinstellungen (insgesamt 96 unterschiedliche Tests). Die älteren Nachweise vom 29.09.2026 bleiben historisch erhalten. Die System-Textübergabe ersetzt keine WhatsApp-Abnahme. Kurze Gemma-Lasttests ersetzen keinen langen Offlinebericht, und synthetische Audiodateien ersetzen keine Langaufnahme am Mikrofon.

Aktive Audiosegmente sind während der Aufnahme noch nicht durchgehend auf App-Ebene verschlüsselt; iOS-Dateischutz und Verschlüsselung abgeschlossener Segmente sind davon getrennt. Größen- und RAM-Grenzen gelten für die dokumentierten Pfade und sind keine allgemeine Garantie gegen Speicherfehler.

Vor weiteren Produktzusagen [test-status.md](../test-status.md) und [requirements-trace.md](../requirements-trace.md) fortschreiben. Der umfangreiche Restplan einschließlich Android, weiterer Provider und Brave bleibt offen.
