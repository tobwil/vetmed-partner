# 0011: Inkrementelles Speichern, einmalige Modellprüfung, Robustheit auf Android

Datum: 30.09.2026

## Anlass

Der Nutzer fragt, welche Optimierungen auf iOS und Android dringend nötig sind. Gesucht wurde nach Problemen, die erst bei echter Nutzung auffallen, also bei vielen Fällen, App-Wechseln, gedrehtem Gerät oder Abstürzen, und die in den Tests mit drei synthetischen Fällen unsichtbar bleiben.

## Entscheidungen

### 1. Nur geänderte Zeilen speichern (iOS und Android)

Bisher löschte jedes Speichern alle Zeilen und schrieb alle Fälle, Vorgänge und Versionen neu. Wegen `secure_delete` wurden die frei gewordenen Seiten dabei zusätzlich überschrieben. Gespeichert wird nach jedem Tippen (Autosave nach 1 s), während einer Chat-Antwort jede Sekunde bzw. alle 8 KB und bei jedem Aufnahmesegment. Der Aufwand wuchs linear mit dem gesamten Datenbestand.

Jetzt gilt:

- Das Repository merkt sich pro Zeile Elternteil, Position und SHA-256 der Nutzlast. Diesen Stand liest es beim Öffnen aus der Datenbank und aktualisiert ihn nach jedem erfolgreichen Schreiben.
- Ein Speichervorgang schreibt nur Einfügungen, Änderungen und Löschungen, weiterhin in einer Transaktion. Kinder werden vor ihren Eltern gelöscht und nach ihnen eingefügt.
- Änderungen sind echte `UPDATE`s, niemals Löschen und Neueinfügen. So kann `ON DELETE CASCADE` keine Versionen eines unveränderten Vorgangs entfernen.
- Trifft ein `UPDATE` keine Zeile, weicht die Datenbank vom bekannten Stand ab, etwa durch einen zweiten Schreiber. Dann wird die Transaktion zurückgerollt und das ganze Dokument wie früher geschrieben. Nach jedem Fehler wird der bekannte Stand verworfen, der nächste Speichervorgang ist also vollständig.
- Doppelte Kennungen werden abgewiesen, bevor etwas geschrieben wird. Beim vollständigen Schreiben hatte das der Primärschlüssel erledigt.
- iOS schreibt JSON-Nutzlasten jetzt mit sortierten Schlüsseln, damit ein unveränderter Wert denselben Hash behält. Dadurch schreibt der erste Speichervorgang nach dem Update einmalig alle Zeilen neu. Das Lesen ist davon nicht betroffen.
- Tabellen, Spalten und Schema bleiben unverändert. Es gibt keine Migration, und iOS und Android bleiben austauschbar.

Wirkung: Ein Zwischenstand während einer Chat-Antwort schreibt genau eine Vorgangszeile. Eine neue Transkriptversion schreibt eine neue und eine geänderte Zeile. Das Umsortieren von Fällen ändert nur deren Positionen.

### 2. Das Offline-Modell nur einmal pro App-Start vollständig prüfen (iOS und Android)

Beide Apps entladen das Modell bei jedem App-Wechsel und prüften bisher vor jedem Laden die gesamte Datei per SHA-256 (iOS 3,6 GB, Android 2,6 GB). Jetzt läuft die vollständige Prüfung direkt nach der Installation und dann einmal pro Prozess. Danach wird nur noch verglichen, ob Größe und Änderungsdatum der geprüften Datei gleich geblieben sind. Eine veränderte Datei wird wieder vollständig geprüft und abgelehnt.

### 3. Android: Drehen beendet keine Aufnahme mehr

Die Activity wird beim Drehen, bei Split-Screen und beim Wechsel des Dunkelmodus neu aufgebaut. Dabei liefen `ON_STOP` und `onDispose`, und die Aufnahme pausierte. Jetzt wird nur pausiert, wenn die Activity nicht bloß neu aufgebaut wird (`isChangingConfigurations`). Aufnahme, Wiedergabe und das geladene Modell laufen dann weiter.

### 4. Android: Wiederherstellung nach einem Absturz wie auf iOS

Beim Start passiert jetzt:

- Vorgänge im Zustand Aufnahme, Transkription oder Berichtserstellung werden als unterbrochen markiert. Vorher zeigten sie nach einem Prozessende dauerhaft „Bericht entsteht“.
- Verwaiste verschlüsselte Anhänge und Aufnahmen werden entfernt, ebenso abgelaufene PDF-Exporte, die unverschlüsselt im Cache liegen.
- Jeder Fehler beim Öffnen führt zur Meldung mit „Erneut versuchen“, nicht mehr nur ein erwarteter.

## Prüfung

- **Android** (`./scripts/test-android.sh`): 83 Kern- und 43 App-Tests ohne Fehler, Lint ohne Befunde, Build erfolgreich. Neu geprüft wird:
  - Anzahl der geschriebenen Zeilen je Änderung: unverändert, neue Version, Umsortieren, Chat-Zwischenstand und Löschen
  - Wiederöffnen, abgewiesenes Speichern und fremder Schreiber (Rückfall auf vollständiges Schreiben)
  - Modellprüfung einmal pro Prozess und erneut nach einer Veränderung der Datei
  - Drehen bei laufender Aufnahme gegenüber dem Verlassen der App
  - Zustände nach einem Prozessende und das Aufräumen verwaister Dateien
- **iOS**: In dieser Umgebung gibt es kein Xcode. Stattdessen:
  - Die neue Speicherlogik (`CaseRows`, `RowChanges`, `write`, `replaceAll`, `load`) wurde unverändert zusammen mit den iOS-Domänentypen unter Linux mit Swift 6.1 im Swift-6-Sprachmodus gegen GRDB 7.11.1 und SQLite gebaut. Das ist dieselbe GRDB-Version wie im Projekt, aber der Upstream-Stand ohne SQLCipher.
  - Ein Prüfprogramm mit denselben Szenarien wie der neue XCTest lief ohne Fehler, einschließlich `SQLITE_FULL` und fremdem Schreiber.
  - `ModelVerificationMemory` wurde einzeln gebaut und geprüft.
  - Die XCTests `testSavesWriteOnlyChangedRowsAndFallBackWhenTheStoreDiffers` und `testModelIsHashedOncePerProcessAndAgainAfterAnyChange` sind geschrieben, aber noch nicht in Xcode ausgeführt.
  - Vor dem Übernehmen auf `main` muss `./scripts/test-ios.sh` auf dem Mac laufen.

## Was auf dem Branch gemacht wurde

Branch `claude/urgent-fixes`, abgezweigt von `main` (Stand `4561e04`). Die Commits in dieser Reihenfolge:

1. **Android: Drehen und Absturz-Wiederherstellung**
   - `background(changingConfigurations)` in `AppViewModel`
   - `isChangingConfigurations`-Prüfung in `VetMedApp` und `EncounterScreen`
   - `CaseOperations.recoverInterruptedWork`
   - `VaultRepository.cleanUnreferencedFiles`
   - `exports.cleanExpired()` beim Start
   - `open()` fängt jeden Fehler
   - Tests in `CaseOperationsTests`, `ChatStorageTests` und `WalkthroughTests`
2. **Modellprüfung einmal pro App-Start (beide Plattformen)**
   - Android: `ModelStore.verify` mit Merker (`fullChecks` für Tests), Test in `LocalModelTests`
   - iOS: `ModelVerificationMemory` und `ModelRepository.currentStamps`, genutzt in `MLXLocalReportEngine.load/install/delete`; XCTest `testModelIsHashedOncePerProcessAndAgainAfterAnyChange`
3. **Android: inkrementelles Speichern**
   - `RowChanges`, `RowSnapshot` und `CaseDao.applyChanges` in `CaseDatabase.kt`
   - `VaultRepository.write` mit `lastWrite`
   - fünf neue Tests in `CaseDatabaseTests`
4. **iOS: inkrementelles Speichern und diese Doku**
   - `CaseRows`, `RowChanges` und `CaseRepository.write/replaceAll/load` mit `lastWrite` in `SecureStore.swift`
   - XCTest `testSavesWriteOnlyChangedRowsAndFallBackWhenTheStoreDiffers`
   - ADR 0011 und `docs/test-status.md`

## Vor dem Übernehmen auf `main`

Der Branch wird bewusst **nicht** vorgespult. Einige Commits ändern iOS, und iOS konnte hier nicht in Xcode gebaut werden. Offen sind:

1. **iOS-Tests auf dem Mac:** `./scripts/test-ios.sh`. Alle Tests müssen grün sein, insbesondere die beiden neuen und die vorhandenen Speichertests: Round-Trip, doppelte Kennung, `SQLITE_FULL`, Migration, Anhänge und Audio.
2. **iOS-Build mit SQLCipher:** Die Linux-Prüfung lief gegen GRDB ohne SQLCipher. Zu bestätigen ist, dass `db.changesCount` und das Öffnen einer zweiten `CaseRepository`-Instanz auf dieselbe Datei im Test auch mit SQLCipher funktionieren.
3. **iOS-Gerät, kurzer Rauchtest mit vorhandenen Daten:**
   - App mit dem neuen Build öffnen und prüfen, dass alle Fälle da sind.
   - Einen Text ändern, eine Chat-Frage stellen und die App neu starten; der Stand muss erhalten sein.
   - Das erste Speichern schreibt wegen der sortierten JSON-Schlüssel einmalig alles neu. Das ist erwartet und sollte nur einmal spürbar sein.
4. **Offline-Modell auf dem iPhone, falls installiert:**
   - Ein Offline-Bericht, dann App-Wechsel, dann ein weiterer Offline-Bericht.
   - Der zweite darf nicht mehr lange mit „Integrität prüfen“ warten.
5. **Android auf einem Gerät oder Emulator, sobald verfügbar:**
   - Während einer Aufnahme das Gerät drehen; die Aufnahme läuft weiter.
   - Die App verlassen; die Aufnahme pausiert und ist gespeichert.
6. **Übernahme:** Erst wenn 1 bis 3 grün sind, `main` vorspulen, also `git push origin claude/urgent-fixes:main` (reiner Fast-Forward, `main` hat sich seitdem nicht bewegt). Alternativ einen Pull Request öffnen. Die Punkte 4 und 5 können danach folgen, blockieren aber einen Pilotbetrieb.

Falls ein iOS-Test fehlschlägt, lassen sich die Android-Commits 1 und 3 einzeln übernehmen. Commit 2 enthält iOS-Anteile und müsste dafür aufgeteilt werden.
