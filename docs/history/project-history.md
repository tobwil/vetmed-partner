# Projektchronik bis zum ersten GitHub-Stand

Stand: 29.09.2026. Diese Chronik ordnet den [sichtbaren Gesprächsverlauf](conversation-2026-09-29.md) den Implementierungen und Nachweisen zu. Historische Zwischenergebnisse bleiben von der aktuellen Abnahme getrennt.

## Ausgangspunkt

Übergeben wurde der [Umsetzungsplan](../implementation-plan.md), Version 1.3 vom 26.09.2026: eine native Arbeitsassistenz für eine Tierärztin, zuerst auf dem iPhone 17 Pro, später auf dem Pixel 9. Der Plan beschreibt Diktat, lokale Transkription, strukturierte Berichte mit Review, multimodales Cloud-Sparring und Brave-Fachrecherche. Er ist eine Anforderungsquelle; spätere ausdrückliche Nutzerentscheidungen ändern die dortige Reihenfolge und Bedienung.

Als technische Referenz wurde [tobwil/rag2go](https://github.com/tobwil/rag2go) bereitgestellt. Der aktuelle Referenzcheckout wurde bei Commit `d06132b90aa86082bd4ed76a17e965889c237820` geprüft. README und Projektkonfiguration nennen Wissenswerk 2.0.0 / Build 24. Das im Plan historisch geprüfte ZIP stand in dieser Projektaufgabe nicht erneut zur Verfügung; es wurde keine Identität von ZIP und Git-Checkout behauptet. Übernahmen und Abweichungen stehen im [Herkunftsaudit](../rag2go-audit.md).

Der Nutzerauftrag wurde ausdrücklich erweitert um „ohne Face ID“ und die Vermeidung von Speicher-/Arbeitsspeicherfehlern. Die App nutzt deshalb keine zusätzliche biometrische Zugangssperre. Verschlüsselung, Keychain, Dateischutz und verdeckte App-Vorschau bleiben bestehen. Speichergrenzen und Fehlerprüfungen sind implementiert; eine allgemeine Fehlerfreiheit oder RAM-Garantie ist nicht belegt.

## Chronologie der Entwicklung

### 1. Nativer iOS-Grundablauf und lokale Pipeline

Ein eigenständiges SwiftUI-Projekt wurde angelegt. Es verwendet das Bundle `de.tobwil.vetmed`, eigene Daten- und Keychain-Bereiche sowie eigene Fall-/Vorgangsdaten. Die Referenz-App und ihre Zugangsdaten wurden nicht übernommen oder verändert.

Implementiert wurden:

- SQLCipher/GRDB-Speicher mit Fall-/Vorgangstrennung, Versionierung, Migration, atomaren Schreibvorgängen und Wiederherstellung.
- Verschlüsselte abgeschlossene Audiosegmente und Anhänge mit an den Kontext gebundener AES-GCM-Authentifizierung.
- Segmentierte Vordergrundaufnahme, Pause/Fortsetzen, lokale deutsche SpeechAnalyzer-Transkription und Transkriptbearbeitung mit Quellen-/Audiobezug.
- Gemma/MLX-Berichte mit gepinnter Modellrevision, begrenzter Verarbeitung, Quellenprüfung, begrenzten Reparaturversuchen und gespeicherten Zwischenständen.
- Prüfung von Zahlen, Einheiten, Verneinungen und Quellenabdeckung; manuelle Freigabe der konkreten Berichtsversion.
- Berichtsvorlagen, Längen/Zielgruppen, Fachwortvorschläge, Klartext-/PDF-Export und Entwurfskennzeichnung.

Die Modellbereitstellung benötigte Fehlerbehebung: Nach zwei abgebrochenen Gerätedownloads wurden die ca. 3,55 GB Gewichte am Mac geprüft und in das App-Staging kopiert. Damit war die Inferenz auf dem Gerät möglich, aber In-App-Download und Wiederaufnahme sind nicht vollständig abgenommen.

### 2. Geräte-, Speicher- und Offlineprüfungen

Der Nutzer entsperrte das iPhone für die Tests. Deutsche synthetische Audiodateien mit 30, 120 und 300 Sekunden Gesamtlänge wurden lokal transkribiert. Die fünfminütige Datei enthält ca. 242 Sekunden Sprache und zusätzliche Stille; das ist kein Nachweis für fünf Minuten reales Mikrofon-Diktat.

Zehn kurze Gemma-Läufe hintereinander, ein bewusster Abbruch und eine erneute Generierung bestanden. Die gemessene Speicherspitze lag bei 3142 MiB, die Lastresidenz bei 3130–3131 MiB; die Thermik war am Ende `fair`. Diese Messung gilt für den dokumentierten kurzen synthetischen Fall und den damaligen Samplingstand.

Für den echten Offlineversuch aktivierte der Nutzer den Flugmodus und schaltete WLAN ausdrücklich aus. Nach einer weiteren Installation startete er den synthetischen Test direkt in der App und stellte anschließend WLAN wieder her. Der Netzwerkstatus war `unsatisfied`; Transkription und verschlüsselte Speicherung lieferten 112 Satzquellen. Die Berichtsausgabe scheiterte an ungültigem JSON und wurde abgewiesen. Ein vollständiger langer Offlinebericht ist deshalb weiterhin offen.

Nach den gefundenen Format-/Auslassungsfehlern wurde der lokale Ausgabe-/Reparaturvertrag vereinfacht und Sampling verändert. Frühere erfolgreiche Messungen werden nicht als erneute Abnahme dieser Änderungen ausgegeben.

### 3. Nutzerentscheidung: Online als Standard, Offline optional

Auf die Frage, ob bei vorhandenem API-Key normalerweise die Online-Version verwendet werden sollte, wurde der OpenAI-Berichtspfad vorgezogen. Die App bietet Keychain-Konfiguration, dynamische Modellliste, explizite Modellauswahl, synthetischen Verbindungstest und bewusste Aktivierung. Danach ist Online der Standard; das lokale Modell ist optional und Offline wird ausdrücklich ausgewählt. Es gibt keinen stillen Anbieterwechsel.

Der OpenAI-Berichtspfad verwendet gespeicherte Anfragesnapshots, strukturierte Ausgaben und dieselbe fachliche Quellenvalidierung. Aufnahme und Transkription bleiben lokal. Eine echte Anbieter-/Qualitätsabnahme mit dem Nutzer-Key ist noch offen.

Diese erste umfangreiche Implementierung ist im Commit `2b8ac2b` zusammengefasst. Arbeitsschritte davor sind im Gespräch und den Nachweisen dokumentiert, wurden jedoch nicht nachträglich als einzelne Git-Commits erfunden.

### 4. Sofortiger Aufnahmeabbruch

Der Nutzer meldete zunächst sofortige Abbrüche und nach einer ersten Bearbeitung erneut ausdrücklich, dass Audio noch nicht funktioniere. Ursache war die Behandlung eigener Audio-Kategorieänderungen beim Start wie echter Unterbrechungen.

Die Korrektur unterscheidet Ereignisgründe sowie Unterbrechungsbeginn und -ende, schützt Start und Speicherung vor konkurrierenden Aktionen und erhält den ursprünglichen Fallbezug. Neun Recorder-Tests decken unter anderem Pause beim Segmentwechsel, fehlgeschlagene Speicherung, Gerätewechsel und Berechtigungen ab.

Nach Installation und Neustart bestätigte der Nutzer: **„Aufnahme läuft jetzt“**. Diese Bestätigung belegt den reparierten Start auf dem iPhone. Lange echte Aufnahmen, Anrufe/Unterbrechungen und lückenlose Aufnahme bleiben gesonderte Abnahmen.

Commits: `4f55c93` (Korrektur), `6c713b9` (Nutzerbestätigung).

### 5. Schnellchecks und Löschbedienung

Der Nutzer wünschte Sparring ohne vorherigen Fall und eine natürliche Löschgeste. Die Richtung wurde ausdrücklich von links/rechts auf **rechts nach links** korrigiert.

Unabhängige Schnellchecks werden separat verschlüsselt gespeichert und erzeugen keine leeren klinischen Fälle. Eine Streaming-Chatbasis mit gespeicherten Entwürfen, Snapshots, Teilantworten und Abbruch wurde ergänzt. Die Fallliste erlaubt Wischen von rechts nach links; im Fall steht die Löschaktion unten. Eine Bestätigung mit „Behalten“ verhindert versehentliches endgültiges Löschen. UI-Tests prüfen auch die Rückkehr aus einem geöffneten Vorgang und den Zustand nach Neustart.

Commit: `54033b8`.

### 6. Vom technischen Sparringformular zum normalen Chat

Der Nutzer kritisierte das technische Formular und verlangte einen normalen Chat mit Fragen, Bildern und Befunden. Die Oberfläche wurde auf Nachrichtenverlauf, Eingabefeld, Plus-Menü und Senden/Abbrechen umgestellt. Der Gesprächsverlauf desselben Chats wird automatisch berücksichtigt. API-/Modell-/Anfragedetails bleiben im Menü erreichbar.

Bilder werden lokal als verschlüsseltes Original erhalten und für den Versand als ausgerichtetes JPEG ohne EXIF/GPS vorbereitet. PDF- und Textbefunde werden lokal gelesen bzw. mit OCR verarbeitet; vor Versand wird der erkannte Text geprüft. Dateigrößen-, Pixel-, Kontext- und Speichergrenzen schützen den Verarbeitungspfad. Der Requestbuilder prüft Hashes und Fallzuordnung und bezieht frühere Bilder desselben Chats ein.

Der Foto-UI-Test fand zunächst einen unpassenden Selektor und anschließend eine Simulatorbesonderheit von `os_proc_available_memory`. Die Speicher-Vorprüfung wird wie im bestehenden MLX-Pfad nur auf realer Hardware verwendet; Datei-/Pixelgrenzen gelten überall. Der reale Fotoauswahl-/Import-/Entfernungspfad wurde danach im Simulator erfolgreich geprüft.

Commit: `4a1cf4a`.

### 7. Navigation, feste Fallzuordnung, Markdown und Teilen

Auf die Nachfrage nach der bestmöglichen UI/UX wurde der bisherige Aufbau erneut überarbeitet: **Start · Fälle · Chat**, Einstellungen am Zahnrad, zwei Hauptaktionen auf Start und ein Diktatablauf mit Aufnahme → Textprüfung → Bericht. Neue Chats sind direkt erreichbar; der zugehörige Fall bzw. „Ohne Fall“ steht dauerhaft über dem Gespräch.

Dabei wurde die gemeinsame globale Fallauswahl durch feste Fall-/Vorgangs-IDs pro Ansicht ersetzt. Offene Diktate, verzögertes Speichern, Berichtsfreigaben und Exportprotokolle bleiben dadurch beim ursprünglichen Fall, auch wenn ein anderer Chat geöffnet wird.

Zusätzlich meldete der Nutzer sichtbare `**` statt Fettdruck und leere Übergaben an WhatsApp. Auf Rückfrage präzisierte er den Weg als **Teilen → WhatsApp**. Native Markdown-Darstellung zeigt nun Fett, Kursiv, Überschriften, Listen, Links, Zitate und Code. Kopieren und Teilen liefern lesbaren Klartext mit Prüfstatus; Tabellen werden derzeit als Text dargestellt.

Beim Appwechsel wurde bislang die Navigation samt Teilenansicht abgebaut, und Exportdateien wurden beim Zurückkehren sofort bereinigt. Die Oberfläche bleibt jetzt bestehen, Inhalte werden weiterhin während Inaktivität verdeckt, und junge Exportdateien bleiben für die empfangende Erweiterung verfügbar. Text wird als eingefrorenes NSString mit explizitem Texttyp bereitgestellt.

Die erste UI-Prüfung für Teilen hatte irrtümlich einen Kopieren-Knopf hinter der Teilenansicht gefunden. Der Selektor wurde auf die tatsächliche Systemaktion korrigiert. Ein weiterer Versuch, die Zwischenablage aus dem separaten XCTest-Runner zu lesen, wurde vom Betriebssystem abgewiesen. Die abschließenden Nachweise verwenden die echte Systemaktion und unmittelbar anschließend `simctl pbpaste`: Chat und Bericht waren vollständig, einschließlich letzter Zeile, Zahlen/Negationen und Prüfstatus. **Der echte WhatsApp-Entwurf auf dem Nutzergerät ist weiterhin nicht bestätigt.**

Commit: `076b034`. Signierter Build installiert und normal auf dem iPhone gestartet.

## Erhaltene Entwicklungs-Commits

| Commit | Datum/Zeit, Europe/Berlin | Inhalt |
|---|---|---|
| `2b8ac2b` | 29.09.2026, 22:17 | iOS-Berichtsablauf, OpenAI-Modus, optionaler lokaler Pfad und erste Nachweise |
| `4f55c93` | 29.09.2026, 22:29 | Aufnahmeabbruch durch eigene Session-Benachrichtigungen behoben |
| `6c713b9` | 29.09.2026, 22:30 | Bestätigung der funktionierenden Aufnahme dokumentiert |
| `54033b8` | 29.09.2026, 22:50 | Streaming-Sparring, fallfreie Schnellchecks und native Falllöschung |
| `4a1cf4a` | 29.09.2026, 23:21 | Normaler Chat mit verschlüsselten Anhängen |
| `076b034` | 29.09.2026, 23:51 | Vereinfachte Navigation, Markdown und stabile Textübergabe |

## Prüfstand des Snapshots

Der letzte Gesamtlauf enthält 95 Tests: 86 Unit-/Integrationstests bestanden; ein Navigationstest und die Aussagekraft zweier zunächst grüner Teilen-Tests mussten nachbearbeitet werden. Gezielte Folgeläufe belegen den Navigationstest und beide korrigierten Teilen-Tests. Insgesamt sind 95 unterschiedliche Tests über diese Läufe erfolgreich nachgewiesen; es wird kein einzelner vollständig grüner Gesamtlauf behauptet.

Die gesonderten Teilenproben bestätigen 143 Zeichen Chat-Klartext bzw. 129 Zeichen Berichtstext mit vollständigem Schluss und Status. Das sind synthetische Systemübergaben, keine Nachrichtenzustellung an WhatsApp-Kontakte. Es wurden dafür keine Nachrichten verschickt.

Die vollständigen Belege, älteren Prüfstände und ihre Grenzen stehen in [test-status.md](../test-status.md) und [evidence](../evidence/).

## Weiterhin offen

- Vollständiger langer Offlinebericht mit fachlicher Abnahme; längere echte Mikrofonaufnahme und reale Unterbrechungs-/Wiederherstellungsprüfungen.
- Durchgehende App-Verschlüsselung der aktiven Aufnahme und Prüfung möglicher Lücken beim Segmentwechsel.
- Tatsächliche WhatsApp-Übergabe sowie echte Anbieter-/Streaming-/Bildantworten mit eingerichtetem Nutzer-Key.
- Strukturierte Laborwerte mit Originalausschnitten/Redaktion, Audioanhänge und geprüfte Übernahme aus dem Chat in Berichte.
- Anthropic, OpenRouter und Gemini, Fähigkeiten-/Modellfreigaben sowie Brave-Recherche mit belastbaren Quellen.
- Native Android-App, Emulatorprüfungen und Pixel-9-Abnahme.
- Vollständiger Fachkorpus, Lizenz-/Datenschutz-/TestFlight-/Store- und Releaseprüfung.

Der GitHub-Auftrag veröffentlicht den Entwicklungsstand und seine Historie. Er stellt keine Fertigmeldung für den Gesamtplan dar.

## Fortsetzung am 30.09.2026: Design-Branch übernehmen

Neuer Nutzerauftrag: „bitte das besssere design/ui vom anderen branch übernehmen und aufs smartphone installieren und dann auch main updaten“.

Als einziger anderer GitHub-Branch wurde `claude/optimized-ui-themes-animations-4a60zm` mit Commit `02793da08e32aab5f8ad65af2aff070e0843b563` gefunden. Er baut auf dem ersten veröffentlichten Stand auf und ergänzt Kartenlayouts, Tag/Nacht, sechs Farbthemen, Hintergrund-/Aufnahmeanimationen und überarbeitete Chatansichten. Der ursprüngliche Design-Commit bleibt durch Fast-forward erhalten.

Der Branch hatte bisher keinen Xcode-Build. Bei der Integration wurde das Projekt mit XcodeGen erzeugt, der vollständige bisherige Simulator-Testlauf mit 95 Tests erfolgreich durchgeführt und ein weiterer UI-Test für Darstellung/Farbwahl über einen Neustart ergänzt; auch dieser besteht. Start in Tag/Nacht, Einstellungen, Diktat und Markdown-Chat wurden anhand synthetischer Simulator-Screenshots geprüft. Der signierte iPhone-Build ist erfolgreich. Geräteinstallation und Veröffentlichung werden mit dem zugehörigen Nachweis im aktuellen Prüfstand dokumentiert.

## Fortsetzung am 30.09.2026: Erfahrene tiermedizinische Sparring-Persona

Der Nutzer fragte, ob der Chat bereits als Senior-Sparringspartner über Fachrichtungen hinweg arbeite. Nach Prüfung des bis dahin allgemeinen Prompts wurde eine erfahrene, interdisziplinäre und kritisch mitdenkende Rolle vorgeschlagen. Mit „ok, mach dass und dann bitte wieder update“ wurden Umsetzung und Update bestätigt.

Der Prompt beschreibt jetzt die Arbeitsweise einer erfahrenen klinischen Kollegin: passende Fachperspektiven auswählen, Differenzialdiagnosen gewichten, relevante Widersprüche benennen und praktikable nächste Schritte begründen. Tierart, Kontext und Dringlichkeit werden einbezogen. Normale dialogische Antworten, fallfreie Fragen und die bisherigen Regeln gegen erfundene Befunde, Dosierungen und Quellen bleiben erhalten. Die KI behauptet keine reale Approbation oder Spezialisierung. Die neue Rolle gilt für folgende Anfragen auch in bestehenden Chats; frühere Antworten bleiben unverändert. Details: [Chat-Architektur](../architecture/0005-conversational-chat-and-attachments.md).


## 30.09.2026 – Berichtszielgruppe und Fallberichte im Chat

Der Nutzer bestätigte, „Für wen?“ zu entfernen: Alle Vorlagen außer „Information für Tierhalter“ richten sich an Fachkollegen. Die Zielgruppe wird jetzt automatisch aus der Vorlage abgeleitet; historische Berichte werden nicht verändert.

Zusätzlich fragte der Nutzer, warum ein Fallchat ohne Berichtswissen startet, und beauftragte die direkte Umsetzung einer Berichtseinbindung. Bisher konnte nur das Transkript manuell hinzugefügt werden. Jetzt wird beim ersten Öffnen der neueste Bericht des Vorgangs (ersatzweise desselben Falls) sichtbar vorausgewählt. Im Eingabebereich und über + lassen sich Berichte desselben Falls mit Vorschau und Prüfstatus auswählen oder abwählen. Die Auswahl bleibt über Nachrichten und Neustarts bestehen. Der gesendete Berichtsstand wird unveränderlich gespeichert, fremde Fälle und übergroße Anfragen werden abgewiesen. Details: [Architekturentscheidung 0008](../architecture/0008-report-audience-and-chat-context.md).


## 30.09.2026 – Aktuellen Stand holen und `claude/urgent-fixes` prüfen

Auf ausdrücklichen Auftrag des Nutzers wurde der inzwischen um Android ergänzte `main`-Stand `4561e04` geholt und der Branch `claude/urgent-fixes` (`5ea7e98`, vier Commits) für eine Übernahme geprüft. Der Branch reduziert SQL-Schreibvorgänge, merkt sich erfolgreich geprüfte Offline-Modelldateien innerhalb eines Prozesses und verbessert Android-Aufnahmen bei Konfigurationswechseln sowie die Wiederherstellung nach Prozessende.

Im Review wurden zwei zusätzliche Korrekturen nötig: Die inkrementelle Speicherung muss fremde Änderungen auch an lokal unveränderten Zeilen erkennen; beide Plattformen prüfen deshalb die Datenbankversion innerhalb der Transaktion. Ein neu hinzugefügter Android-Test reproduzierte den Fehler vor der Korrektur. Außerdem stürzte ein iOS-UI-Lauf in SwiftUIs Haptik beim Wiederherstellen des Nachtmodus ab. Die Design-Schalter lösen Auswahlfeedback jetzt direkt beim Antippen über UIKit aus. Architektur, Nachweise und Grenzen stehen in [0011](../architecture/0011-incremental-persistence-and-robustness.md) und [Teststatus](../test-status.md).


## 30.09.2026 – abschließende Tests auf dem entsperrten iPhone

Nutzer: „handy ist entsperrt! los gehts! finale ios abnahme“. Der auf main übernommene Urgent-Stand wurde auf dem physischen iPhone geprüft: 104 Tests im Ausgangslauf; zusätzlich normaler Nutzerspeicherstart und echter Mikrofontest. Insgesamt 106 unterschiedliche Tests bestanden. Für Aufnahme und beide Teilen-Wege wurden echte Appwechsel zu iOS-Einstellungen verifiziert. Drei zunächst fehlgeschlagene Mikrofontest-Versuche und die Korrektur der Zustands-/Wechselprüfung sind im Prüfstand dokumentiert, ebenso die anschließend bestandenen drei Lifecycle-Tests. Die Aufnahme von 0:51 blieb nach Neustart erhalten; der Testfall wurde gelöscht. Zwei Accessibility-IDs ermöglichen den reproduzierbaren Gerätetest.

Die 300-Sekunden-Datei wurde lokal transkribiert und verschlüsselt gespeichert. Der lokale Bericht konnte mangels installiertem optionalem Gemma-Modell nicht gestartet werden. Es wurde nichts automatisch heruntergeladen. Der Nutzer wurde nach vollständigem WhatsApp-Entwurf des vorbereiteten synthetischen Testchats und gewünschter erneuter Offline-Modellinstallation gefragt. Der Abnahmeleitfaden entspricht jetzt Start/Fälle/Chat, automatischer Zielgruppe, Berichtswissen und aktuellen Aufnahmeaktionen. Kein Versand an Kontakte, keine neue Online-Provideranfrage und keine klinische Freigabe.

Der Simulator-Nachtest bestand ebenfalls: drei UI-Tests (synthetischer Fotoimport, Chat- und Bericht-Teilen), die beiden physischen Tests wurden dort erwartungsgemäß übersprungen. Zum Archivzeitpunkt stehen die manuellen Rückmeldungen noch aus; das iPhone bleibt dafür bewusst im getrennten Testbereich. Der normale Fallspeicherstart ist geprüft. Der Quellstand und die Nachweise werden auf main gesichert; die offenen Punkte werden nicht als bestanden gewertet.

Nutzeranschluss: „hat alles funktioniert! wie jetzt die apk testen?“ Die erfolgreiche manuelle iPhone-Rückmeldung ist erfasst; VetMed wurde wieder ohne Testargumente gestartet. Für Android liegt die geprüfte Debug-APK vor (mindestens Android 14). Bei der Geräteabfrage war noch kein Android-Gerät über ADB angeschlossen.


## 30.09.2026 – APK auf dem verbundenen Android testen

Nutzer: „android ist verbunden mit dem pc“. Auf dem Pixel 9a (Android 17) wurde die Debug-APK installiert und der echte Mikrofon-/Drehungs-/Speicherpfad geprüft. Dabei stürzte „Text prüfen“ reproduzierbar ab: JVM-Regex-Flag `(?U)` wird von Android ICU nicht akzeptiert. Die vier Validator-Muster verwenden jetzt explizite Unicode-Klassen; zusätzliche JVM- und native Gerätetests schützen Zahlen, Einheiten, Vergleiche und Verneinungen.

128 lokale Tests und sieben gezielt ausgewählte Gerätetests bestehen, Build erfolgreich, Lint null Fehler/sechs Hinweise. Das Update ist auf dem Pixel installiert. Die Aufnahme von 1:14 blieb erhalten; Texteingabe, Drehung und Prozessneustart funktionierten anschließend. Nur der selbst angelegte synthetische Testfall wurde gelöscht. Die App bleibt normal auf Start; keine Provideranfrage, kein Modell-Download und kein Versand an Kontakte. Der erste Modelltest ist wegen fehlender Gewichte als fehlgeschlagene Voraussetzung archiviert. Detaillierte Versuche, Grenzen und Hashes: [Prüfstand](../test-status.md), [Gerätenachweis](../evidence/android-pixel-device-acceptance-2026-09-30.json).
