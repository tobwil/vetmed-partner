# iPhone-Test des lokalen Diktatablaufs

Entwicklungsstand, keine fachliche Freigabe. Für Tests ausschließlich synthetische Fallangaben verwenden. Auf dem gekoppelten iPhone 17 Pro sind Gemma und deutsche Sprachressourcen installiert. Die App öffnet ohne Face ID.

1. Unter **Start → Neues Diktat** einen Vorgang anlegen. Über **Falldaten** Kennung, Tierart und optional Tiername bearbeiten.
2. **Aufnahme starten** startet nach Mikrofonfreigabe. Beispiel: „Hund, zwölf Komma fünf Kilogramm. Seit gestern verminderter Appetit. Kein Erbrechen. Temperatur nicht gemessen. Kontrolle in drei Tagen vereinbart.“ Mit **Pause** unterbrechen und mit **Fortsetzen** weiter aufnehmen.
3. **Fertig · Text prüfen** schließt die Aufnahme ab und transkribiert ausstehende Segmente lokal. Fachwörter, Zahlen und Negationen prüfen. Texteingabe sichert nach einer kurzen Pause; **Text speichern** bleibt zusätzlich verfügbar.
4. Über **Anpassen** Vorlage, Länge und Verarbeitung wählen. Die Zielgruppe ergibt sich automatisch aus der Vorlage: nur „Information für Tierhalter“ richtet sich an Tierhalter, alle übrigen Vorlagen an Fachkollegen. Mit aktiviertem API-Zugang ist Online vorausgewählt; für den lokalen Test ausdrücklich Offline wählen. **Bericht erstellen** startet den Auftrag. Fertige Abschnitte bleiben bei einer späteren Unterbrechung als Zwischenstand sichtbar.
5. Den Bericht öffnen, Text und Quellen prüfen. Bearbeitungen erzeugen eine neue Version ohne übernommene Freigabe. Die konkrete geprüfte Version freigeben und als Text/PDF teilen. Ohne Freigabe trägt der Export die Entwurfskennzeichnung.

## Gerätetest-Matrix

- 30 Sekunden, 2 Minuten und 5 Minuten echte Mikrofonaufnahme: Verständlichkeit, fehlende letzte Worte, Übergänge zwischen Segmenten.
- Aufnahme pausieren/fortsetzen; App in den Hintergrund bringen; Bildschirm sperren; Audioausgabe wechseln. Die Anzeige muss zu einer tatsächlich laufenden oder gestoppten Aufnahme passen.
- Aufnahme nach Rückkehr öffnen. Rohtext, bearbeiteter Text und ältere Berichtsversionen müssen getrennt erhalten bleiben.
- Nach Installation der Ressourcen Flugmodus aktivieren und WLAN ausdrücklich ausschalten. App neu starten und Aufnahme → Transkript → Bericht → PDF ausführen.
- Berichtserstellung abbrechen und erneut starten. Zwischenstände dürfen nicht als vollständig angezeigt werden.
- Zwei Fälle nacheinander bearbeiten. Audio, Quellen und Bericht müssen zum jeweils ausgewählten Fall gehören.
- Fall löschen und anschließend prüfen, dass die zugehörigen Aufnahmen und Versionen nicht mehr erreichbar sind.

## Synthetischer Entwicklungstest

Im Debug-Build steht unter **Einstellungen → Synthetischer Gerätetest** ein Dateitest ohne Mikrofon zur Verfügung. Er benötigt die vom Entwicklungsskript vorbereitete 300-Sekunden-Datei im App-Testverzeichnis. Er prüft den Netzwerkpfad, lokale ASR, Berichtserstellung, verschlüsseltes Speichern/Wiederöffnen und PDF-Erstellung. Er ist kein Ersatz für die Mikrofon- oder Fachprüfung. Der Abschlussstatus wird in der App angezeigt; das Protokoll liegt im eigenen Verzeichnis `SyntheticQA`.

Aktuelle bestandene und fehlgeschlagene Läufe: [test-status.md](test-status.md).

## Online-Bericht einrichten

Unter Einstellungen → API-Key & Modell den eigenen OpenAI-Key eingeben. Modellliste laden, ein geeignetes Textmodell wählen und mit dem synthetischen Test prüfen. Mit „Online aktivieren“ wird Online zum Standard für neue Berichte; der Key bleibt im Schlüsselbund. Im Vorgang kann Offline ausdrücklich ausgewählt werden. „Übertragenen Text vorab ansehen“ zeigt das Transkript. Ein fehlgeschlagener Auftrag wird bei Netzrückkehr nicht automatisch wiederholt.

## Nachtest des sofortigen Aufnahmeabbruchs

Nach Installation der Korrektur vom 29.09.: Neues Diktat starten, mindestens 30 Sekunden einen synthetischen Text sprechen (damit ein Segmentwechsel enthalten ist), Pause drücken und anschließend weitere fünf Sekunden aufnehmen. Die Zeit muss laufen; nach Pause müssen gesicherte Segmente erscheinen. Danach lokal transkribieren und Anfang, Übergang sowie Schluss prüfen. Falls weiterhin ein Abbruch auftritt, den genauen eingeblendeten Aufnahmehinweis und angeschlossene Kopfhörer/Audiogeräte nennen. Für diesen Test ist kein Wechsel des WLAN- oder Flugmodus nötig.

## Chat, Fallberichte und Schnellcheck

**Chat → Neuer Chat** beziehungsweise die Chataktion auf Start öffnet eine Frage ohne Fall. Entwurf eingeben, App neu starten und den Chat wieder öffnen; in Fälle darf kein zusätzlicher Eintrag entstehen. Über **+ → Foto auswählen / Datei hinzufügen** einen synthetischen Anhang hinzufügen, prüfen und wieder entfernen. Auf dem echten Gerät keine privaten Fotos für automatisierte Tests auswählen.

Im Diktat **Zum Fall chatten** öffnen. **Berichte als Wissen** zeigt die gewählten Fallberichte. Beim ersten Öffnen ist der neueste Bericht des Vorgangs vorausgewählt (ersatzweise der neueste Bericht desselben Falls). Bericht ansehen, abwählen, App neu starten und prüfen, dass die Abwahl erhalten bleibt. Andere Fälle dürfen nicht angeboten werden. Die Versandvorschau muss genau die bewusst gewählten Inhalte zeigen.

Mit eingerichtetem Online-Key eine synthetische Frage senden. Antwort läuft schrittweise ein; Abbrechen sichert den empfangenen Zwischenstand. Nach Netzverlust keine automatische Wiederholung erwarten. Dieser Live-Providertest ist getrennt von Tests mit simulierten Antworten zu protokollieren.

In Fälle eine Zeile von rechts nach links wischen. **Löschen** öffnet die Bestätigung; **Behalten** darf nichts entfernen. Im geöffneten Fall steht dieselbe Aktion unter den Vorgängen; im Diktat ganz am Ende. Löschung eines synthetischen Falls und anschließender Neustart dürfen unabhängige Chats nicht entfernen.

## Teilen an WhatsApp

Bei einem ausschließlich synthetischen Bericht und einer synthetischen Chatantwort **Teilen → WhatsApp** wählen. Im Entwurf Anfang, Absätze und letzten Satz auf Vollständigkeit prüfen. Für die Abnahme muss keine Nachricht gesendet werden. Danach abbrechen und zu VetMed zurückkehren; Inhalt und Fallzuordnung müssen erhalten bleiben. Ein erfolgreich geöffnetes iOS-Teilen-Menü oder Kopieren darin allein bestätigt diesen WhatsApp-Pfad noch nicht.

## Automatisierte Abnahme am physischen iPhone

Die UI-Tests starten mit `--ui-testing` und verwenden einen separaten verschlüsselten Fallspeicher und getrennte API-Einstellungen. Die normalen Nutzerdaten werden dadurch nicht zu Testfällen. Der Foto-Picker-Test setzt ein synthetisches Bild voraus und wird beim automatisierten Gerätelauf zunächst explizit ausgelassen.

`testPhysicalMicrophoneRolloverPauseResumeBackgroundAndReopen` nimmt auf dem echten iPhone bewusst das Mikrofon auf. Währenddessen nur synthetische Inhalte sprechen. Der Test prüft mindestens 50 Sekunden Aufnahme, die 20-Sekunden-Segmentwechsel, Pause/Fortsetzen, Hintergrund-Unterbrechung und erhaltene Gesamtdauer nach Prozessneustart; anschließend löscht er seinen Testfall. Auf dem Simulator wird er übersprungen. Er führt weder Transkription noch eine Provideranfrage aus und ersetzt keine Hör-/ASR-Prüfung. Scheitert er vor der Löschung, bleibt der Fall im getrennten Testspeicher zur Diagnose erhalten.

Nach den Tests die App ohne Testargumente starten und das Öffnen des bestehenden Fallspeichers prüfen. Ergebnisse, Auslassungen und Nachweise in [test-status.md](test-status.md) festhalten.
