# VetMed Partner

Native tierärztliche Arbeitsassistenz. Die Umsetzung folgt [dem vollständigen Plan](docs/implementation-plan.md): iOS-Diktatablauf, Online-Berichte mit eigenem API-Key und optionales Offline-Modell; Chat mit Bildern/Befunden und fallfreie Schnellchecks; anschließend Recherche mit Brave und native Android-Parität.

## Projektverlauf und erster GitHub-Stand

Die App heißt **VetMed**. Der erste GitHub-Stand umfasst den Quellcode samt Entwicklungs-Commits, den vollständigen Umsetzungsplan und ein [Projektarchiv](docs/history/README.md) mit [Gesprächsverlauf](docs/history/conversation-2026-09-29.md), [Chronik](docs/history/project-history.md) und [technischer Übergabe](docs/history/handoff.md). Entscheidungen, fehlgeschlagene Versuche und offene Abnahmen bleiben nachvollziehbar.

## Aktueller Stand

Die erste iOS-Implementierung enthält getrennte Fall-/Vorgangsdaten, verschlüsselten Speicher, segmentierte Vordergrundaufnahme, lokale deutsche SpeechAnalyzer-Transkription, Transkriptversionen, wahlweise OpenAI- oder Gemma/MLX-Berichte mit Quellenvalidierung, Fachwortvorschläge, Review und Text-/PDF-Teilen. Sparring bietet einen normalen Chat mit automatischem Gesprächsverlauf, Bildern, geprüften PDF-/Textbefunden, Streaming und gespeicherten Teilantworten. Schnellchecks funktionieren unabhängig von einem Fall. Dies ist ein Entwicklungsstand, keine abgeschlossene Pilotfreigabe. Der tatsächliche Prüfstand und Restumfang stehen in [docs/test-status.md](docs/test-status.md).

## Build

Voraussetzungen: macOS, Xcode 27, XcodeGen. iOS-Mindestziel 26. Gemma-Inferenz benötigt ein physisches iPhone mit Metal und mindestens 8 GB RAM.

```sh
xcodegen generate --spec apps/ios/project.yml
open apps/ios/VetMed.xcodeproj
```

Schema `VetMed`, eigenes Bundle `de.tobwil.vetmed`. Signing-Team in `project.yml` anpassen, falls ein anderes Konto verwendet wird. Im Projekt die gepinnten MLX-Paketplugins/Makros zulassen. Die reproduzierbaren CLI-Skripte verwenden explizite Validierungsflags für diese geprüften Paketversionen.

```sh
./scripts/test-ios.sh
```

App öffnen; es gibt auf Nutzerwunsch keine Face-ID-Abfrage. Für Online-Berichte unter Start → Zahnrad → API-Key & Modell den eigenen Key eintragen, Modelle laden/auswählen, den synthetischen Modelltest ausführen und Online aktivieren. Danach ist Online der Standard. Für Offline-Berichte Gemma ausdrücklich installieren und Offline auswählen. Deutsche Sprachressourcen werden unabhängig davon für lokale Diktate installiert. Neues Diktat anlegen oder Text eingeben, Transkript prüfen, Bericht erstellen, Quellen prüfen und die konkrete Version freigeben. Ungeprüfte Exporte bleiben als Entwurf gekennzeichnet.

Die drei Bereiche heißen Start, Fälle und Chat. Der Sonne/Mond-Knopf auf Start wechselt zwischen Tag und Nacht; unter Einstellungen → Darstellung stehen Automatisch/Tag/Nacht und sechs Farbthemen zur Wahl ([Entscheidung 0007](docs/architecture/0007-appearance-themes-and-motion.md)). Auf Start führen „Diktat aufnehmen“ und „Frage stellen“ direkt zur jeweiligen Aufgabe; letzte Vorgänge lassen sich darunter fortsetzen. Ein Diktat führt durch Aufnahme, Textprüfung und Bericht. Einstellungen liegen am Zahnrad.

Im Chat startet der sichtbare Neuer-Chat-Knopf ein Gespräch ohne Fall. Eine Frage eingeben, über + bei Bedarf ein Bild oder einen Befund hinzufügen und senden. PDF-/Textbefunde werden vor dem Versand lokal geprüft. Frühere vollständige Nachrichten desselben Chats werden automatisch berücksichtigt. Der Fallbezug bleibt über den Nachrichten sichtbar. Formatierte Antworten lassen sich als lesbarer Text kopieren oder teilen. Fälle lassen sich in der Fallliste von rechts nach links aufwischen oder unten in der Fallansicht löschen.

## Android (Beginn)

Voraussetzungen: JDK 21 und Android SDK mit Plattform 37.2 (`sdk.dir` in `apps/android/local.properties` oder `ANDROID_HOME`).

```sh
./scripts/test-android.sh            # Kern- und App-Tests, Lint, Debug-APK
cd apps/android && ./gradlew :app:installDebug
```

Der Android-Stand umfasst Fälle, Texteingabe, Online-Berichte mit Quellenprüfung, Freigabe, Teilen, Tag/Nacht und Farbthemen. Aufnahme, Offline-Modell und Chat folgen. Details und Grenzen: [Entscheidung 0009](docs/architecture/0009-android-start.md).

## Struktur

- `apps/ios`: eigenständiges SwiftUI-Target und Tests.
- `apps/android`: Kotlin-Kern (`core`) und Compose-App (`app`) mit Tests.
- `shared`: versionierte Schemas, Prompts und synthetische Fixtures.
- `docs`: Plan, Herkunft, Architekturentscheidungen, Prüfstand.
- `.reference`: ignorierter rag2go-Checkout; nicht Teil der App und nicht verändert.

Keine produktiven Fallinhalte, API-Schlüssel oder Modellgewichte einchecken. Ohne eigene fachliche und Geräteabnahme keine klinische Freigabe behaupten.
