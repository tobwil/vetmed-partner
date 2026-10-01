# Mitmachen

Danke für dein Interesse an VetMed. Beiträge sind willkommen: Fehlerberichte, Verbesserungen, Tests und fachliches Feedback aus der Praxis.

*English: Contributions are welcome. Issues and pull requests may be written in English or German. Never include real patient data, API keys or model weights.*

## Drei Regeln, die nicht verhandelbar sind

1. **Keine echten Patientendaten.** Nicht in Issues, Screenshots, Logs, Tests oder Fixtures. Verwende ausschließlich erfundene Fälle, wie in [`shared/fixtures`](shared/fixtures).
2. **Keine Schlüssel und keine Modellgewichte.** API-Keys, `local.properties`, `.env`, `*.safetensors` und `*.litertlm` gehören nicht ins Repository.
3. **Keine stillen Wechsel.** Online und Offline wählt die Nutzerin oder der Nutzer ausdrücklich. Es gibt keinen automatischen Wechsel zu einem anderen Anbieter oder in einen anderen Modus und keinen Cloud-Ausweichweg für die Spracherkennung.

## Ablauf

1. Für größere Änderungen zuerst ein Issue öffnen und kurz beschreiben, was du vorhast.
2. Einen eigenen Branch anlegen und die Änderung klein halten.
3. Lokal testen:
   - iOS (macOS mit Xcode 27): `./scripts/test-ios.sh`
   - Android (JDK 21, Android SDK 37.2): `./scripts/test-android.sh`
4. Pull Request öffnen. Beschreibe darin, was sich ändert, wie du es geprüft hast und was **nicht** geprüft ist, zum Beispiel „nur Simulator“ oder „kein echtes Gerät“.

## Worauf wir achten

- **iOS und Android bleiben fachlich gleich.** Prompts und Schemas liegen in [`shared/`](shared) und werden von beiden Apps genutzt. Ändert sich der Berichtsvertrag, betrifft das beide Plattformen.
- **Eine Entscheidung, eine Datei.** Größere Design- oder Architekturentscheidungen kommen als kurze Notiz nach [`docs/architecture`](docs/architecture).
- **Ehrliche Prüfangaben.** In [`docs/test-status.md`](docs/test-status.md) steht nur, was tatsächlich geprüft wurde.
- **Datenschutz zuerst.** Klinische Inhalte bleiben verschlüsselt auf dem Gerät. Neue Netzwerkpfade nur auf ausdrückliche Aktion der Nutzerin oder des Nutzers.

## Sicherheitslücken

Bitte **nicht** als öffentliches Issue melden, sondern wie in [SECURITY.md](SECURITY.md) beschrieben.

## Lizenz

Mit einem Beitrag erklärst du dich einverstanden, dass er unter der [MIT-Lizenz](LICENSE) des Projekts veröffentlicht wird.
