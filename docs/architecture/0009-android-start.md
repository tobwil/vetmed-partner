# 0009: Start der nativen Android-App

Datum: 30.09.2026

## Anlass

Der Nutzer bittet, auf einem eigenen Branch mit der Android-App zu beginnen (Plan, Phase 3, P3.1). Ziel ist ein echter, baubarer Anfang mit demselben fachlichen Vertrag wie iOS, keine Attrappe.

## Umsetzung

`apps/android` ist ein Gradle-Projekt (AGP 9.4, Kotlin 2.4, Gradle 9.8, compileSdk 37.2, minSdk 34) mit zwei Modulen:

- **`:core`** (reines Kotlin/JVM): Datenmodell, Transkript-Segmentierung, Berichtsvalidator, Berichtspipeline mit Aufteilung in Abschnitte und genau einem Reparaturversuch, OpenAI-Responses-Vertrag (zustandslos, `store=false`, striktes JSON-Schema, Anfragebudget, Provenienz) und Fall-Operationen. Der Code ist eine direkte Portierung der iOS-Logik. Der Berichtsprompt kommt unverändert aus `shared/prompts`. JSON folgt den iOS-Konventionen: Datum als Sekunden seit 2001, großgeschriebene UUIDs, unbekannte Felder werden ignoriert. App-Zeitstempel haben Millisekundengenauigkeit und überstehen damit den Double-Round-Trip exakt.
- **`:app`** (Jetpack Compose, Material 3): Start, Fälle und Chat wie auf iOS. Diktat mit den Schritten Aufnehmen, Text prüfen und Bericht. Texteingabe speichert automatisch nach einer Sekunde. Online-Bericht mit eigenem OpenAI-Key, Prüfansicht mit Warnungen und Quellenbezügen, Freigabe, neue Version bei Bearbeitung, Kopieren (als sensibel markiert) und Teilen über das Android-Teilen-Menü. Ein Teilvorgang wird erst protokolliert, wenn eine Ziel-App gewählt wurde. Fachwortliste, Einstellungen, Tag/Nacht und die sechs Farbthemen der iOS-App sind enthalten, ebenso animierter Hintergrund, Schrittwechsler, Kreisübergang beim Tag/Nacht-Wechsel und Haptik. Bei ausgeschalteten Systemanimationen entfallen die Bewegungen.

**Speicher:** Fälle mit allen Vorgängen, Transkript- und Berichtsversionen, Teilvorgängen und die Fachwortliste liegen in einer Room-Datenbank, die mit SQLCipher 4.19 verschlüsselt ist. Das Tabellenschema entspricht iOS: eine Zeile pro Fall, Vorgang und Version, jeweils mit JSON-Nutzlast und Position. Gespeichert wird in einer einzigen Transaktion; schlägt sie fehl, bleibt die vorherige Fassung vollständig erhalten. Das Datenbank-Passwort (32 Zufallsbytes) ist mit einem nicht exportierbaren Android-Keystore-Schlüssel versiegelt. Beim Öffnen muss `PRAGMA cipher_version` antworten, sonst wird kein Fallspeicher angelegt. `secure_delete` ist an, und die Room-Schemata sind unter `apps/android/app/schemas` versioniert.

API-Key und Online-Konfiguration liegen wie die Keychain-Einträge auf iOS getrennt als AES-256-GCM-versiegelte Dateien unter einem zweiten Keystore-Schlüssel. Fehlt der Schlüssel zu vorhandenen Daten, wird nichts überschrieben. Alles liegt in `noBackupFilesDir`; Backup und Geräteübertragung sind per `dataExtractionRules` ausgeschlossen. Klartext-HTTP ist gesperrt, und die Vorschau in der App-Übersicht ist ausgeblendet (`setRecentsScreenshotEnabled(false)`).

Der allererste Android-Stand speicherte ein versiegeltes Gesamtdokument. Solche Dateien werden beim Öffnen in die Datenbank übernommen, gegengeprüft und erst danach gelöscht. Die nativen SQLCipher-Bibliotheken liegen für alle vier ABIs vor, sind auf 16-KB-Speicherseiten ausgerichtet und vergrößern die unsignierte Release-APK von etwa 2,9 auf 10,7 MB. Ein App-Bundle liefert pro Gerät nur die passende Architektur.

**Offene Entscheidung:** Der Keystore-Schlüssel verlangt derzeit kein entsperrtes Gerät, damit ein laufender Bericht bei Displaysperre nicht an der Speicherung scheitert. Das ist schwächer als die iOS-Dateischutzklasse `complete` und vor einem Pilot zu entscheiden.

**Noch nicht vorhanden und so gekennzeichnet** (inzwischen umgesetzt, siehe [0010](0010-android-parity.md)): Mikrofonaufnahme und lokale Spracherkennung (P3.2), das Offline-Modell über LiteRT-LM, Chat mit Anhängen, PDF-Export, Brave-Recherche. Die App zeigt an diesen Stellen deutlich „folgt“ und bietet nichts als funktionsfähig an. Online ist auf Android der Berichtsstandard, weil Offline noch keinen Bericht erzeugen kann; es gibt keinen stillen Wechsel.

## Prüfung und Grenzen

- `:core`: 46 JVM-Tests. Sie portieren die plattformneutralen Fälle aus `CoreTests.swift` und `OnlineReportTests.swift` und prüfen das gemeinsame 30-Fälle-Korpus, das Schema und den Prompt aus `shared`. Das Korpus bestätigt, dass die Segmentierung keine kritische Phrase trennt und ein wortgetreuer Bericht ohne Warnung durch die Validierung geht.
- `:app`: 18 Tests. Drei prüfen die versiegelten Dateien (Round-Trip, Manipulation, falscher Schlüssel und Kontext, kein Überschreiben ohne Schlüssel). Acht prüfen die Datenbank auf Robolectric: Round-Trip mit Reihenfolge, Versionen, Freigabe und Teilvorgängen, Löschen samt allen Versionen, Rollback einer fehlgeschlagenen Transaktion, kein Überschreiben ohne Schlüssel, Ablehnung einer unverschlüsselten Datenbank, Migration des ersten Stands, Trennung von Fall- und Geheimnisdaten. Sieben Compose-UI-Tests laufen mit echter Grafikausgabe und synthetischen Fällen. Sie decken Start, Tag/Nacht, Fallliste, Falldetail, Texteingabe mit Autosave und Wiederöffnen, Berichtsprüfung, Einstellungen und Falllöschung ab.
- SQLCipher ist eine native Android-Bibliothek und lädt nicht auf der JVM. Die Robolectric-Tests nutzen deshalb dasselbe Room-Schema mit normalem SQLite. Die eigentliche Verschlüsselung prüft `SqlCipherDeviceTests` (kein SQLite-Klartextkopf, kein Klartext in der Datei, Round-Trip, fremder Keystore-Schlüssel öffnet nicht). Dieser Test ist gebaut, aber mangels Emulator oder Gerät **noch nicht ausgeführt**.
- Die UI-Tests haben zwei echte Fehler gefunden: Navigation von einem Hintergrund-Thread nach dem Anlegen eines Diktats und eine Aktionsleiste, die den ganzen Bildschirm belegte. Beides ist behoben. Die Screenshots zeigten außerdem dunklen Text im Nachtmodus; die Textfarbe wird jetzt zentral gesetzt.
- Lint: keine Befunde. Debug- und minifizierter Release-Build (unsigniert) bauen.

Robolectric nutzt einen Software-Schlüssel statt des Android-Keystore. Es gab keinen Emulator (kein KVM in der Build-Umgebung) und kein Gerät. SQLCipher und Keystore auf echter Hardware, echtes Teilen, Release-Build mit R8 zur Laufzeit und der OpenAI-Aufruf gegen den echten Dienst sind daher **nicht** geprüft. Status nach Gate D: „Android begonnen, Zielgerätetest offen“.
