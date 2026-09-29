# iPhone-Test des lokalen Diktatablaufs

Entwicklungsstand, keine fachliche Freigabe. Für Tests ausschließlich synthetische Fallangaben verwenden. Auf dem gekoppelten iPhone 17 Pro sind Gemma und deutsche Sprachressourcen installiert. Die App öffnet ohne Face ID.

1. Unter **Berichte → Neues Diktat** einen Vorgang anlegen. Über die Fallzeile Kennung, Tierart und optional Tiername bearbeiten.
2. **Aufnehmen** startet nach Mikrofonfreigabe. Beispiel: „Hund, zwölf Komma fünf Kilogramm. Seit gestern verminderter Appetit. Kein Erbrechen. Temperatur nicht gemessen. Kontrolle in drei Tagen vereinbart.“ Mit **Pause / Stopp** abschließen. Gesicherte Segmente werden angezeigt.
3. **Lokal transkribieren** wählen. Rohtext und Audio sind unter „Original & Audio“ erreichbar. Fachwörter, Zahlen und Negationen prüfen. Texteingabe sichert nach einer kurzen Pause; „Transkript speichern“ bleibt zusätzlich verfügbar. Korrekturen aus der eigenen Fachwortliste erfordern einen bewussten Tastendruck.
4. Vorlage, Länge und Zielgruppe wählen. Mit eingerichtetem API-Zugang ist **Online** vorausgewählt; für den lokalen Test ausdrücklich **Offline** wählen, dann **Bericht lokal erstellen**. Fertige Abschnitte bleiben bei einer späteren Unterbrechung als Zwischenstand sichtbar. Ein unvollständiger Bericht kann nicht als vollständiger Bericht freigegeben werden.
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
