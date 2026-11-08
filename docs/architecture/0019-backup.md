# 0019: Verschlüsselte Sicherung aller Fälle

Datum: 08.11.2026

## Anlass

Bisher gab es keine Sicherung. Fälle liegen verschlüsselt nur auf dem Gerät, mit einem Schlüssel aus Android Keystore bzw. iOS-Schlüsselbund. Diese Schlüssel verlassen das Gerät nicht, und die Daten sind von Geräte-Backups ausgeschlossen. Bei Geräteverlust, Defekt, Deinstallation oder Gerätewechsel waren damit alle Fälle verloren. Für eine Praxis ist das nicht tragbar.

## Entscheidung

**Eine Datei, ein Passwort, kein Server.**
- Unter Einstellungen → Lokale Daten → Sicherung schreibt die App alles in eine Datei `VetMed-Sicherung-JJJJ-MM-TT.vetmedbackup`: Fälle, Berichte, Chats, Anhänge (Original und Upload-Fassung), auf Wunsch die Aufnahmen und die Fachwortliste.
- Den Ablageort wählt die Nutzerin im Systemdialog: Computer, USB-Stick, eigener Cloud-Ordner. Die App lädt nichts hoch.
- Nicht enthalten: API-Keys und Anbieter-Einstellungen. Sie werden auf dem neuen Gerät neu eingerichtet.

**Verschlüsselung.**
- Schlüssel: PBKDF2-HMAC-SHA256 mit 600.000 Durchläufen und zufälligem 16-Byte-Salz. Das Passwort wird vorher Unicode-normalisiert (NFC), damit „ü“ auf beiden Plattformen denselben Schlüssel ergibt.
- Inhalt: AES-256-GCM in Blöcken zu 1 MB, damit lange Aufnahmen nicht ganz in den Speicher müssen.
- Jeder Block bestätigt den Dateikopf, seine Nummer und ob er der letzte ist. Ein falsches Passwort, ein verändertes Byte, vertauschte Blöcke, eine abgeschnittene Datei und angehängte Daten werden erkannt.
- Passwortregel: mindestens 10 Zeichen, zweimal eingeben. Das Passwort wird nirgends gespeichert und lässt sich nicht wiederherstellen.

**Ein Format für beide Plattformen.** Android (`core/Backup.kt`) und iOS (`Core/Backup.swift`) schreiben und lesen dasselbe Format. Eine Sicherung vom iPhone lässt sich auf Android öffnen und umgekehrt. Belegt ist das mit einer von Android erzeugten Testdatei (`shared/fixtures/backup-v1-synthetic.vetmedbackup`, synthetisch), die die iOS-Tests öffnen.

**Dateiaufbau:**

    Kopf    "VMBK" | Version | Durchläufe | Salz (16) | Blockgröße            29 Bytes
    Block   Länge | Chiffretext mit Tag                Nonce = 0000 | Blocknummer
    Inhalt  manifest.json, document.json, vocabulary.json, dann jede Datei als
            attachment/<Fall oder quick>/<Vorgang>/<ID>/original|upload und
            audio/<Fall>/<Vorgang>/<Segment>

**Wiederherstellen ergänzt nur, es überschreibt nichts.**
- Ein Fall oder Schnellcheck, dessen ID schon auf dem Gerät ist, bleibt unverändert.
- Nur fehlende kommen hinzu, mit ihren Dateien. Die Fachwortliste wird um neue Einträge ergänzt.
- Erst werden die Dateien verschlüsselt abgelegt, dann der Fallspeicher gespeichert. Scheitert etwas dazwischen, zeigt der Fallspeicher nie auf fehlende Dateien. Übrig gebliebene Dateien entfernt die App beim nächsten Start.
- Dateinamen aus der Sicherung werden streng geprüft (nur IDs, auf iOS nur UUIDs). Ein Name kann keinen Pfad außerhalb des Speichers erzeugen.
- Ergebnis zum Beispiel: „1 Fall und 0 Schnellchecks wiederhergestellt. 3 schon vorhanden, unverändert gelassen.“

**Fehlende Dateien.** Fehlt beim Sichern eine Datei auf dem Gerät, etwa eine durch einen Absturz verlorene Aufnahme, wird sie ausgelassen und gezählt. Die Sicherung läuft trotzdem durch. Beim Wiederherstellen nennt die App, wie viele Dateien fehlten.

## Prüfung

- **Android:**
  - `BackupTests` (Kern, 9 Tests):
    - Schlüsselableitung gegen RFC 7914 und Python;
    - Passwortregeln;
    - vollständige Wiederherstellung;
    - nichts wird überschrieben;
    - ohne Aufnahmen;
    - fehlende Datei;
    - falsches Passwort und jede Beschädigungsart;
    - Dateinamen;
    - reproduzierbare gemeinsame Testdatei.
  - `BackupStorageTests`: zwei „Geräte“ mit verschiedenen Schlüsseln, Fälle, Fotos, Aufnahme und Fachwortliste kommen bytegleich an.
  - UI-Test `aBackupIsSavedWithAPasswordAndBringsADeletedCaseBack`: Passwortprüfung, Sicherung über den Dateidialog, Fall löschen, Wiederherstellen. Screenshot `20-sicherung.png`.
- **iOS:**
  - `BackupTests.swift`, 5 Tests, darunter das Öffnen der Android-Datei mit allen Dateien. Unter Linux mit Swift 6.1 zusammen mit den übrigen Tests: 34/34.
  - Speicher-, Modell- und Ansichtsteil (FileHandle, `fileMover`, `fileImporter`) nur auf Syntax geprüft. **Vor `main`:** `./scripts/test-ios.sh` auf dem Mac.
- **Auf echten Geräten steht aus:** Sicherung auf Pixel und iPhone, Übertragung in beide Richtungen, Dauer der Schlüsselableitung.

## Grenzen

- Die Sicherung ist so stark wie das Passwort. 600.000 Durchläufe bremsen das Durchprobieren, verhindern es bei kurzen Passwörtern aber nicht.
- Wer die Sicherung in einen Cloud-Ordner legt, gibt die verschlüsselte Datei an diesen Anbieter. Lesbar ist sie dort ohne Passwort nicht.
- Es gibt keine automatische, regelmäßige Sicherung. Die App erinnert noch nicht daran.
- Geänderte Fälle werden beim Wiederherstellen nicht zusammengeführt: Ist der Fall schon da, gilt die Fassung auf dem Gerät.
