# 0009: Start der nativen Android-App

Datum: 30.09.2026

## Anlass

Der Nutzer bittet, auf einem eigenen Branch mit der Android-App zu beginnen (Plan, Phase 3, P3.1). Ziel ist ein echter, baubarer Anfang mit demselben fachlichen Vertrag wie iOS, keine Attrappe.

## Umsetzung

`apps/android` ist ein Gradle-Projekt (AGP 9.4, Kotlin 2.4, Gradle 9.8, compileSdk 37.2, minSdk 34) mit zwei Modulen:

- **`:core`** (reines Kotlin/JVM): Datenmodell, Transkript-Segmentierung, Berichtsvalidator, Berichtspipeline mit Aufteilung in Abschnitte und genau einem Reparaturversuch, OpenAI-Responses-Vertrag (zustandslos, `store=false`, striktes JSON-Schema, Anfragebudget, Provenienz) und Fall-Operationen. Der Code ist eine direkte Portierung der iOS-Logik. Der Berichtsprompt kommt unverändert aus `shared/prompts`. JSON folgt den iOS-Konventionen: Datum als Sekunden seit 2001, großgeschriebene UUIDs, unbekannte Felder werden ignoriert. App-Zeitstempel haben Millisekundengenauigkeit und überstehen damit den Double-Round-Trip exakt.
- **`:app`** (Jetpack Compose, Material 3): Start, Fälle und Chat wie auf iOS. Diktat mit den Schritten Aufnehmen, Text prüfen und Bericht. Texteingabe speichert automatisch nach einer Sekunde. Online-Bericht mit eigenem OpenAI-Key, Prüfansicht mit Warnungen und Quellenbezügen, Freigabe, neue Version bei Bearbeitung, Kopieren (als sensibel markiert) und Teilen über das Android-Teilen-Menü. Ein Teilvorgang wird erst protokolliert, wenn eine Ziel-App gewählt wurde. Fachwortliste, Einstellungen, Tag/Nacht und die sechs Farbthemen der iOS-App sind enthalten, ebenso animierter Hintergrund, Schrittwechsler, Kreisübergang beim Tag/Nacht-Wechsel und Haptik. Bei ausgeschalteten Systemanimationen entfallen die Bewegungen.

**Speicher:** Fälle, Fachwortliste, API-Key und Online-Konfiguration liegen getrennt als AES-256-GCM-versiegelte Dateien in `noBackupFilesDir`. Fall- und Geheimnisdaten haben je einen eigenen, nicht exportierbaren Android-Keystore-Schlüssel. Ein Kontextstring ist authentifiziert, Schreiben ist atomar. Fehlt der Schlüssel zu vorhandenen Daten, wird nichts überschrieben. Backup und Geräteübertragung sind per `dataExtractionRules` ausgeschlossen. Klartext-HTTP ist gesperrt. Die Vorschau in der App-Übersicht ist ausgeblendet (`setRecentsScreenshotEnabled(false)`).

**Bewusste Abweichungen vom Plan:** Der Plan sieht Room mit SQLCipher vor. Für den Anfang wird wie im ersten iOS-Stand ein verschlüsseltes Gesamtdokument gespeichert; die Migration auf SQLCipher bleibt offen. Der Keystore-Schlüssel verlangt derzeit kein entsperrtes Gerät, damit ein laufender Bericht bei Displaysperre nicht an der Speicherung scheitert. Das ist schwächer als die iOS-Dateischutzklasse `complete` und vor einem Pilot zu entscheiden.

**Noch nicht vorhanden und so gekennzeichnet:** Mikrofonaufnahme und lokale Spracherkennung (P3.2), das Offline-Modell über LiteRT-LM, Chat mit Anhängen, PDF-Export, Brave-Recherche. Die App zeigt an diesen Stellen deutlich „folgt“ und bietet nichts als funktionsfähig an. Online ist auf Android der Berichtsstandard, weil Offline noch keinen Bericht erzeugen kann; es gibt keinen stillen Wechsel.

## Prüfung und Grenzen

- `:core`: 46 JVM-Tests. Sie portieren die plattformneutralen Fälle aus `CoreTests.swift` und `OnlineReportTests.swift` und prüfen das gemeinsame 30-Fälle-Korpus, das Schema und den Prompt aus `shared`. Das Korpus bestätigt, dass die Segmentierung keine kritische Phrase trennt und ein wortgetreuer Bericht ohne Warnung durch die Validierung geht.
- `:app`: 12 Tests. Fünf prüfen den versiegelten Speicher (Round-Trip, Manipulation, falscher Schlüssel und Kontext, kein Überschreiben ohne Schlüssel, Trennung von Fall- und Geheimnisdaten). Sieben Compose-UI-Tests laufen auf Robolectric mit echter Grafikausgabe und synthetischen Fällen. Sie decken Start, Tag/Nacht, Fallliste, Falldetail, Texteingabe mit Autosave und Wiederöffnen, Berichtsprüfung, Einstellungen und Falllöschung ab.
- Die UI-Tests haben zwei echte Fehler gefunden: Navigation von einem Hintergrund-Thread nach dem Anlegen eines Diktats und eine Aktionsleiste, die den ganzen Bildschirm belegte. Beides ist behoben. Die Screenshots zeigten außerdem dunklen Text im Nachtmodus; die Textfarbe wird jetzt zentral gesetzt.
- Lint: keine Befunde. Debug- und minifizierter Release-Build (unsigniert) bauen.

Robolectric nutzt einen Software-Schlüssel statt des Android-Keystore. Es gab keinen Emulator (kein KVM in der Build-Umgebung) und kein Gerät. Keystore-Verhalten, echtes Teilen, Release-Build mit R8 zur Laufzeit und der OpenAI-Aufruf gegen den echten Dienst sind daher **nicht** geprüft. Status nach Gate D: „Android begonnen, Zielgerätetest offen“.
