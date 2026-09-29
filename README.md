# VetMed

Native tierärztliche Arbeitsassistenz. Die Umsetzung folgt [dem vollständigen Plan](docs/implementation-plan.md): iOS-Diktatablauf, Online-Berichte mit eigenem API-Key und optionales Offline-Modell; Text-Sparring und fallfreie Schnellchecks; anschließend multimodales Sparring mit Brave und native Android-Parität.

## Aktueller Stand

Die erste iOS-Implementierung enthält getrennte Fall-/Vorgangsdaten, verschlüsselten Speicher, segmentierte Vordergrundaufnahme, lokale deutsche SpeechAnalyzer-Transkription, Transkriptversionen, wahlweise OpenAI- oder Gemma/MLX-Berichte mit Quellenvalidierung, Fachwortvorschläge, Review und Text-/PDF-Teilen. Sparring bietet Textfragen mit explizit ausgewähltem Verlauf, Versandvorschau, Streaming und gespeicherten Teilantworten. Schnellchecks funktionieren unabhängig von einem Fall. Dies ist ein Entwicklungsstand, keine abgeschlossene Pilotfreigabe. Der tatsächliche Prüfstand und Restumfang stehen in [docs/test-status.md](docs/test-status.md).

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

App öffnen; es gibt auf Nutzerwunsch keine Face-ID-Abfrage. Für Online-Berichte unter Einstellungen → API-Key & Modell den eigenen Key eintragen, Modelle laden/auswählen, den synthetischen Modelltest ausführen und Online aktivieren. Danach ist Online der Standard. Für Offline-Berichte Gemma ausdrücklich installieren und Offline auswählen. Deutsche Sprachressourcen werden unabhängig davon für lokale Diktate installiert. Neues Diktat anlegen oder Text eingeben, Transkript prüfen, Bericht erstellen, Quellen prüfen und die konkrete Version freigeben. Ungeprüfte Exporte bleiben als Entwurf gekennzeichnet.

Im Bereich Sparring startet „Schnellcheck starten“ ein Gespräch ohne Fall. Eine Frage und bei Bedarf einen bereinigten Falltext eingeben, optional frühere Antworten auswählen, Vorschau ansehen und bewusst senden. Fallbezogene Gespräche bleiben beim gewählten Vorgang. Fälle lassen sich in der Fallliste von rechts nach links aufwischen oder unten in der Fallansicht löschen.

## Struktur

- `apps/ios`: eigenständiges SwiftUI-Target und Tests.
- `shared`: versionierte Schemas, Prompts und synthetische Fixtures.
- `docs`: Plan, Herkunft, Architekturentscheidungen, Prüfstand.
- `.reference`: ignorierter rag2go-Checkout; nicht Teil der App und nicht verändert.

Keine produktiven Fallinhalte, API-Schlüssel oder Modellgewichte einchecken. Ohne eigene fachliche und Geräteabnahme keine klinische Freigabe behaupten.
