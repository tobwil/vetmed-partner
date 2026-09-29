# ADR 1 – Eigenständiger nativer iOS-Vertikalschnitt

Status: umgesetzt, Prüfung läuft.

- Eigene Bundle-ID, Keychain-Service, Application-Support-Wurzel.
- `VetAppModel` orchestriert; kein importiertes Wissenswerk-AppModel.
- `CaseRepository` kapselt verschlüsselte Speicherung; `OfflineTranscriber` und `ReportTextEngine` sind austauschbare Grenzen.
- Ausschließlich `install()` darf Modell-/Sprachressourcen laden. Berichtsstart lädt nur bereits installierte, verifizierte Dateien. Der lokale Adapter enthält weiterhin keinen Cloudclient. Der gemeinsame Berichtspfad wählt nach ADR 2 ausdrücklich den lokalen oder den Online-Adapter.
- Audio und Gemma laufen sequenziell. Aufnahme stoppt im Hintergrund, Route-/Sitzungswechsel pausieren.
- Versions-IDs sind unveränderlich. Bearbeitete Berichte bekommen neue IDs ohne Freigabe.
- Berichtsaussagen benötigen existierende Segment-IDs und exakte Zitate. Zahlen und Einheiten werden am jeweiligen Beleg geprüft; Negationsänderung und mögliche Auslassungen sichtbar markiert. Dies prüft keine vollständige klinische Semantik.

## Umsetzungsstand und noch zu schließende Abweichungen

1. Der ursprüngliche AES-GCM-Container wurde durch SQLCipher 4.19.0 und den offiziellen SQLCipher-GRDB-Fork 7.11.1 ersetzt. Fälle, Vorgänge, Transkript-/Berichtsversionen und Exportereignisse liegen in relationalen Tabellen. Der alte Container wird erst nach erfolgreichem Transaktionsimport und vollständigem Vergleich gelöscht. Migration, falscher Schlüssel, Manipulation und Transaktionsrollback sind im Simulator getestet; Sperr-/Backupverhalten auf Zielhardware bleibt offen.
2. Die Aufnahme verwendet kurze iOS-geschützte CAF-Zwischendateien und verschlüsselt abgeschlossene 20-Sekunden-Segmente. Unterbrochene Dateien werden anhand von UUIDs wiedergefunden. Ziel ist eine durchgehend verschlüsselte segmentweise Audioablage; unvollständige CAF-Dateien und Sperrzeitpunkt müssen auf dem Gerät geprüft werden.
3. Import-/OCR-Bausteine sind vorhanden, aber noch nicht in Labor-/Anhangs-UI integriert.
4. Die verschlüsselte Fachwortliste liefert ausdrücklich zu übernehmende Korrekturvorschläge. Cloudprovider, Brave-Recherche und Android sind noch offen.

Keine dieser Zwischenlösungen gilt als vollständige Erfüllung des Plans.

## Datenbankabhängigkeiten

Offizielle Pakete: https://github.com/sqlcipher/GRDB.swift (7.11.1), https://github.com/sqlcipher/SQLCipher.swift (4.19.0). Paketlock versioniert. SQLCipher ist zwingend: `PRAGMA cipher_version` muss einen Wert liefern, andernfalls wird das Öffnen abgebrochen. Keine Rückkehr zu unverschlüsseltem SQLite. Bibliothekslizenztexte werden in der App mitgeliefert.

## Nutzerkorrektur vom 29.09.2026

Keine Face-ID-Abfrage und keine zusätzliche App-Authentifizierung. Der Fallspeicher öffnet nach dem Start automatisch. Keychain (`WhenUnlockedThisDeviceOnly`), SQLCipher, authentifizierte Anhangsverschlüsselung und iOS Complete File Protection bleiben aktiv. Die App-Switcher-Vorschau wird weiterhin verdeckt. Diese ausdrückliche Nutzerentscheidung ersetzt die biometrische App-Sperre im ursprünglichen Plan. Speicher-/Arbeitsspeicherfehler sind durch Belastungs-, Abbruch- und Wiederherstellungstests zu prüfen; keine absolute Fehlerfreiheit behaupten.
