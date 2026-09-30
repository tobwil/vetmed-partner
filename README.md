# VetMed Partner

Native tierärztliche Arbeitsassistenz. Die Umsetzung folgt [dem vollständigen Plan](docs/implementation-plan.md): iOS-Diktatablauf, Online-Berichte mit eigenem API-Key und optionales Offline-Modell; Chat mit Bildern/Befunden und fallfreie Schnellchecks; anschließend Recherche mit Brave und native Android-Parität.

## Projektverlauf und erster GitHub-Stand

Die App heißt **VetMed**. Der erste GitHub-Stand umfasst den Quellcode samt Entwicklungs-Commits, den vollständigen Umsetzungsplan und ein [Projektarchiv](docs/history/README.md) mit [Gesprächsverlauf](docs/history/conversation-2026-09-29.md), [Chronik](docs/history/project-history.md) und [technischer Übergabe](docs/history/handoff.md). Entscheidungen, fehlgeschlagene Versuche und offene Abnahmen bleiben nachvollziehbar.

## Aktueller Stand

Die erste iOS-Implementierung enthält getrennte Fall-/Vorgangsdaten, verschlüsselten Speicher, segmentierte Vordergrundaufnahme, lokale deutsche SpeechAnalyzer-Transkription, Transkriptversionen, wahlweise OpenAI- oder Gemma/MLX-Berichte mit Quellenvalidierung, Fachwortvorschläge, Review und Text-/PDF-Teilen. Sparring bietet einen normalen Chat mit automatischem Gesprächsverlauf, Bildern, geprüften PDF-/Textbefunden, Streaming und gespeicherten Teilantworten. Schnellchecks funktionieren unabhängig von einem Fall. Dies ist ein Entwicklungsstand, keine abgeschlossene Pilotfreigabe. Der tatsächliche Prüfstand und Restumfang stehen in [docs/test-status.md](docs/test-status.md).

## Screenshots

Alle Bilder zeigen ausschließlich synthetische Testfälle.

### iPhone

Aufgenommen im iOS-Simulator (iPhone 17) bei der Designabnahme am 30.09.2026.

<table>
  <tr>
    <td align="center"><img src="docs/evidence/theme-start-day-2026-09-30.png" width="180" alt="iPhone: Start im Tagmodus"><br><sub>Start · Tag</sub></td>
    <td align="center"><img src="docs/evidence/theme-start-night-2026-09-30.png" width="180" alt="iPhone: Start im Nachtmodus"><br><sub>Start · Nacht</sub></td>
    <td align="center"><img src="docs/evidence/theme-dictation-2026-09-30.png" width="180" alt="iPhone: Diktat aufnehmen"><br><sub>Diktat</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/evidence/theme-chat-2026-09-30.png" width="180" alt="iPhone: Chat mit formatierter Antwort"><br><sub>Chat</sub></td>
    <td align="center"><img src="docs/evidence/case-reports-chat-knowledge-2026-09-30.png" width="180" alt="iPhone: Berichte als Wissen im Chat"><br><sub>Berichte als Wissen im Chat</sub></td>
    <td align="center"><img src="docs/evidence/theme-settings-2026-09-30.png" width="180" alt="iPhone: Einstellungen mit Farbthemen"><br><sub>Einstellungen · Farbthemen</sub></td>
  </tr>
</table>

### Android

Gerendert aus den Compose-UI-Tests (Robolectric, Bildschirmgröße wie Pixel 9), nicht von einem Gerät. Neu erzeugen mit `./scripts/test-android.sh -PrecordScreenshots`.

<table>
  <tr>
    <td align="center"><img src="docs/evidence/android/01-start-tag-klinik.png" width="180" alt="Android: Start im Tagmodus"><br><sub>Start · Tag · Klinik</sub></td>
    <td align="center"><img src="docs/evidence/android/02-start-nacht-lavendel.png" width="180" alt="Android: Start im Nachtmodus"><br><sub>Start · Nacht · Lavendel</sub></td>
    <td align="center"><img src="docs/evidence/android/03-faelle-ozean.png" width="180" alt="Android: Fallliste"><br><sub>Fälle · Ozean</sub></td>
    <td align="center"><img src="docs/evidence/android/04-fall-ozean.png" width="180" alt="Android: Falldetail"><br><sub>Fall</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/evidence/android/05-diktat-text-nacht.png" width="180" alt="Android: Diktat, Text prüfen"><br><sub>Diktat · Text prüfen</sub></td>
    <td align="center"><img src="docs/evidence/android/06-bericht-pruefen-nacht.png" width="180" alt="Android: Bericht prüfen"><br><sub>Bericht prüfen</sub></td>
    <td align="center"><img src="docs/evidence/android/07-einstellungen-koralle.png" width="180" alt="Android: Einstellungen mit Farbthemen"><br><sub>Einstellungen · Koralle</sub></td>
    <td align="center"><img src="docs/evidence/android/08-chats-lavendel.png" width="180" alt="Android: Chatliste"><br><sub>Chats · Lavendel</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/evidence/android/09-chat-antwort-nacht.png" width="180" alt="Android: Fallchat mit formatierter Antwort"><br><sub>Fallchat · Nacht</sub></td>
    <td align="center"><img src="docs/evidence/android/10-neuer-chat-anhang.png" width="180" alt="Android: neuer Chat mit Anhangmenü"><br><sub>Neuer Chat · Anhang</sub></td>
    <td align="center"><img src="docs/evidence/android/11-aufnahme-laeuft-koralle.png" width="180" alt="Android: laufende Aufnahme"><br><sub>Aufnahme läuft</sub></td>
    <td align="center"><img src="docs/evidence/android/12-transkript-mit-aufnahme.png" width="180" alt="Android: Transkript mit Original und Wiedergabe"><br><sub>Transkript · Original</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/evidence/android/13-offline-modell-nacht.png" width="180" alt="Android: Offline-Modell in den Einstellungen"><br><sub>Offline-Modell · Wald</sub></td>
    <td></td><td></td><td></td>
  </tr>
</table>

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

## Android

Voraussetzungen: JDK 21 und Android SDK mit Plattform 37.2 (`sdk.dir` in `apps/android/local.properties` oder `ANDROID_HOME`).

```sh
./scripts/test-android.sh            # Kern- und App-Tests, Lint, Debug-APK
cd apps/android && ./gradlew :app:installDebug
```

Android hat denselben Funktionsumfang wie das iPhone:

- Fälle und Diktat mit Aufnahme und lokaler Spracherkennung
- Online-Berichte mit Quellenprüfung
- optionales Offline-Modell (Gemma 4 E2B über LiteRT-LM)
- Freigabe sowie Teilen als Text oder PDF
- Chat mit Bildern und Befunden
- Tag/Nacht und Farbthemen

Die deutschen Sprachressourcen und das Offline-Modell werden nur auf Knopfdruck in den Einstellungen geladen. Geprüft ist das in Tests auf Robolectric, noch nicht auf einem echten Gerät. Details und Grenzen: [Entscheidung 0009](docs/architecture/0009-android-start.md) und [Entscheidung 0010](docs/architecture/0010-android-parity.md).

## FAQ

**Was ist VetMed?**
Eine Arbeitshilfe für Tierärztinnen und Tierärzte: Behandlung diktieren, Text prüfen, daraus einen strukturierten Bericht erstellen lassen und fachliche Fragen im Chat besprechen, mit und ohne Fall. Die App heißt VetMed, das Repository `vetmed-partner`.

**Gibt es VetMed für iPhone und Android?**
Ja. Das iPhone ist die Hauptplattform und bereits auf einem echten Gerät installiert. Android hat seit dem 30.09.2026 denselben Funktionsumfang, ist aber bisher nur in automatisierten Tests ohne echtes Gerät geprüft.

| Funktion | iPhone | Android |
| --- | --- | --- |
| Fälle, Diktat-Ablauf, Tag/Nacht, Farbthemen | ja | ja |
| Aufnahme und lokale Spracherkennung | ja (SpeechAnalyzer) | ja (On-Device-Erkenner des Systems) |
| Online-Bericht mit Quellenprüfung, Freigabe | ja | ja |
| Offline-Bericht auf dem Gerät | Gemma über MLX (optional) | Gemma über LiteRT-LM (optional) |
| Chat mit Bildern und Befunden | ja | ja |
| Teilen | Text und PDF | Text und PDF |
| Auf echtem Gerät installiert | iPhone 17 Pro | noch nicht |

**Landen meine Fälle in der Cloud?**
Nein. Fälle, Aufnahmen und Berichte liegen verschlüsselt nur auf dem Gerät. Es gibt keine Synchronisation und kein Backup. Etwas verlässt das Gerät nur, wenn du es ausdrücklich startest: „Bericht online erstellen“ sendet das geprüfte Transkript, „Senden“ im Chat die Frage, die angehängten Inhalte und den Verlauf dieses Chats. Aufnahme und Transkription bleiben lokal.

**Wie sind die Daten geschützt?**
Auf dem iPhone mit SQLCipher und der Dateischutzklasse von iOS; der Schlüssel liegt im Schlüsselbund. Auf Android mit Room und SQLCipher; der Schlüssel ist über den Android Keystore gesichert. API-Keys liegen jeweils getrennt davon. Eine zusätzliche Face-ID-Sperre gibt es auf Wunsch nicht. Wer die App löscht oder das Gerät verliert, verliert auch die Daten.

**Brauche ich einen API-Key, und was kostet das?**
Für Online-Berichte und den Chat brauchst du einen eigenen OpenAI-API-Key. Die Kosten laufen über dein OpenAI-Konto. Der Modelltest in den Einstellungen sendet nur einen festen synthetischen Satz. Anfragen werden mit `store=false` gestellt; was OpenAI darüber hinaus aufbewahrt, regelt dein API-Vertrag.

**Geht es auch ohne Internet?**
Auf dem iPhone optional: Das lokale Modell (Gemma 4 E2B, einmalig ca. 3,6 GB) braucht ein iPhone mit mindestens 8 GB RAM. Es wird nie still als Ersatz genutzt; du wählst Offline ausdrücklich. Ein vollständiger Offline-Lauf mit langem Diktat ist noch nicht erfolgreich abgenommen, siehe [Prüfstand](docs/test-status.md). Auf Android genauso, mit Gemma 4 E2B im LiteRT-LM-Format (einmalig ca. 2,6 GB, mindestens 8 GB RAM). Revision und Prüfsumme sind fest hinterlegt; vor jedem Laden wird die Datei geprüft. Mit echten Gewichten auf einem Android-Gerät ist das noch nicht erprobt.

**Was passiert, wenn die Spracherkennung auf meinem Android-Gerät fehlt?**
VetMed nutzt nur den Offline-Erkenner, den Android selbst mitbringt (auf Pixel-Geräten vorhanden, bei anderen Herstellern nicht immer). Fehlen die deutschen Sprachdaten, bietet die App unter Einstellungen → Spracherkennung die Installation an. Ohne sie bleibt die Aufnahme verschlüsselt gespeichert, und du kannst den Text selbst eingeben. Einen Cloud-Erkenner als Ausweichweg gibt es nicht.

**Kann ich einen Bericht direkt verwenden?**
Nein. Jeder Bericht ist ein Entwurf. Die App prüft, dass jede Aussage auf eine Stelle im Diktat verweist und dass Zahlen, Einheiten, Vergleichszeichen und Verneinungen übereinstimmen. Erfundene Werte werden abgewiesen, Abweichungen als Warnung angezeigt. Erst wenn du eine konkrete Version am Original geprüft und freigegeben hast, verschwindet die Entwurfskennzeichnung beim Export.

**Ist VetMed klinisch freigegeben?**
Nein. Es ist ein Entwicklungsstand ohne fachliche Abnahme. Die Testdaten sind synthetisch. Was geprüft ist und was nicht, steht im [Prüfstand](docs/test-status.md).

**Wie wechsle ich Tag/Nacht und Farbthema?**
Mit dem Sonne/Mond-Knopf auf Start oder unter Einstellungen → Darstellung (Automatisch, Tag, Nacht und sechs Farbthemen). Auf beiden Plattformen gleich.

**Wo finde ich Entscheidungen und Hintergründe?**
In [docs/architecture](docs/architecture) (eine Datei pro Entscheidung), im [Umsetzungsplan](docs/implementation-plan.md) und im [Projektarchiv](docs/history/README.md).

## Struktur

- `apps/ios`: eigenständiges SwiftUI-Target und Tests.
- `apps/android`: Kotlin-Kern (`core`) und Compose-App (`app`) mit Tests.
- `shared`: versionierte Schemas, Prompts und synthetische Fixtures.
- `docs`: Plan, Herkunft, Architekturentscheidungen, Prüfstand.
- `.reference`: ignorierter rag2go-Checkout; nicht Teil der App und nicht verändert.

Keine produktiven Fallinhalte, API-Schlüssel oder Modellgewichte einchecken. Ohne eigene fachliche und Geräteabnahme keine klinische Freigabe behaupten.
