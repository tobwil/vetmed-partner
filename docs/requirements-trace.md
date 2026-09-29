# Anforderungsnachverfolgung

Der vollständige Zielumfang bleibt der Umsetzungsplan. Ein grüner Test gilt nur für seinen tatsächlich geprüften Umfang.

## Arbeitspakete

- [ ] P0.1a Geliefertes rag2go-ZIP statisch prüfen und konkrete Komponentenmatrix erstellen (Abschnitt 2). — siehe Prüfstand; historische ZIP-Prüfung ist keine neue Abnahme.
- [ ] P0.1b Im tatsächlichen Checkout die Version mit dem ZIP abgleichen, geltende Anweisungen lesen und Extraktion/Abhängigkeiten abschließend prüfen.
- [x] P0.2 Minimalen nativen iOS-Build auf iPhone 17 Pro installieren. — signierter Build mehrfach installiert.
- [ ] P0.3 Vorhandenen Gemma-E2B-/MLX-Pfad mit gepinnter Modellrevision im neuen Target ausführen; Text zu strukturiertem Bericht. Kein vorgezogener iOS-Runtimewechsel.
- [ ] P0.4 Deutsches Offline-ASR mit 30 Sekunden, 2 und 5 Minuten Diktat prüfen.
- [ ] P0.5 Gesamtablauf nach Ressourceninstallation im Flugmodus durchführen.
- [ ] P0.6 Spitzen-RAM, Laufzeit, thermischen Zustand, Abbruch und wiederholte Läufe protokollieren.
- [ ] P0.7 Optional E4B und Gemma-Audio gegen Basispipeline vergleichen; nicht Voraussetzung für Fortsetzung.
- [ ] P1.1 Verschlüsselte lokale Datenhaltung, Fall/Encounter, Versionierung und Wiederherstellung.
- [ ] P1.2 Aufnahme mit Pause/Fortsetzen, Unterbrechungsbehandlung und Audiosegmenten.
- [ ] P1.3 Transkripteditor mit Audiobezug und Fachwortkorrekturen.
- [ ] P1.4 Vorlagen und drei Längen; zuerst Behandlungsbericht und SOAP, danach weitere Vorlagen.
- [ ] P1.5 Gemma-Ausgabevalidierung und Quellenbezüge; manuelle Freigabe.
- [ ] P1.6 Klartext teilen/kopieren, anschließend PDF und Exportbereinigung.
- [ ] P1.7 Modellverwaltung, App-Sperre, Löschung, lokale Fehlerdiagnostik.
- [ ] P2.1 SecureStore und Providervertrag; erster Adapter OpenAI, falls dessen Key verfügbar ist.
- [ ] P2.2 Fachliches Gespräch mit Text und Bildern, Falltrennung, Streaming, Abbruch und Verlauf.
- [ ] P2.3 Laborwerte, PDF-Import/OCR, Originalausschnitt und Wertebestätigung.
- [ ] P2.4 Lokale Audio-Transkription, danach capability-gesteuertes Originalaudio.
- [ ] P2.5 Anthropic-, OpenRouter- und Gemini-Adapter mit synthetischen Contracttests.
- [ ] P2.6 Datenschutzvorschau, Redaktionskopien, Upload-Löschstatus, Limits und Ausfallverhalten.
- [ ] P2.7 Analyse zusammenfassen und als geprüfte Inhalte in einen Bericht übernehmen.
- [ ] P2.8 Konkrete Modell-/Anbieterfreigaben dokumentieren; Gemini-Nutzungsfrage offen ausweisen, bis geklärt.
- [ ] P2.9 Vorhandenen Brave-Adapter übernehmen; eigener Key, fallbezogener QueryBuilder, einmaliger Hinweis, optional einsehbare Suchdetails, Deutsch/Englisch, Budgets und Fehlerpfade.
- [ ] P2.10 Quellenkarten, gezieltes Lesen öffentlicher Originalquellen, stabile Quellen-IDs und zitierte Analyse/Exporte.
- [ ] P2.11 Brave-Liveprüfung mit synthetischen fachlichen Fragen; bestätigen, dass relevante medizinische Falldaten in Suchfragen erhalten bleiben, strukturierte Kundenfelder ausgeschlossen sind und Inhaltslogs keine Falldaten enthalten.
- [ ] P3.1 Compose-App, Datenmodell, SecureStore, Modellverwaltung.
- [ ] P3.2 AudioRecord, Offline-ASR und LiteRT-LM; gleicher Prompt-/Schematestkorpus.
- [ ] P3.3 Berichte, Review, PDF-/Bildimport, Cloudadapter, Brave-Recherche samt Quellenkarten, Export.
- [ ] P3.4 CI-Builds, Emulator-UI-Tests, Migrationstests, synthetische Provider-Contracttests.
- [ ] P3.5 Pixel-9-Testprotokoll vorbereiten und bei Geräteverfügbarkeit vollständig ausführen.
- [ ] P4.1 Wiederherstellung, Speicherknappheit, Unterbrechungen und mehrere Fälle hintereinander testen.
- [ ] P4.2 Fehlermeldungen und Bedienung mit der Tierärztin überarbeiten.
- [ ] P4.3 Installationsanleitung und TestFlight-Build, später signierter Android-Testbuild.
- [ ] P4.4 Modell-/Abhängigkeitslizenzen, Datenschutztexte, Storeangaben und Releasefreigabe.

## Gates

- [ ] Gate A: Offlinepipeline auf echtem iPhone reproduzierbar, Netzwerk-/Abbruch-/Ressourcenprüfung.
- [ ] Gate B: Fünfminütiges Diktat zu geprüftem Bericht, fachlicher Korpus abgenommen.
- [ ] Gate C: Erster Cloudprovider und Brave live geprüft, Quellenherkunft nachvollziehbar.
- [ ] Gate D: Android auf Pixel 9 geprüft.

## Akzeptanzkriterien

- [ ] **Voller Offlinepfad:** Nach Setup keinerlei Fallübertragung; Diktat, Transkript, Bericht und lokale Exporterstellung funktionieren
- [ ] **Fehlende Sprachressource:** Verständliche lokale Fehlermeldung; kein Cloud-Fallback
- [ ] **Stille oder unverständliches Audio:** Kein erfundener klinischer Inhalt; als leer/unklar markieren
- [ ] **Kritische Zahlen/Negationen:** Keine unmarkierte Verfälschung im freigegebenen Testkorpus
- [ ] **Fehlende Befunde:** Kein automatisch ergänztes „unauffällig“
- [ ] **Kürzen:** Wesentliche Befunde, Maßnahmen, Unsicherheiten und vereinbarte Schritte bleiben erhalten
- [ ] **Absturz/Unterbrechung:** Abgeschlossene Segmente und Bearbeitungen wiederherstellbar; ungesicherter Rest klar erkennbar
- [ ] **Labor-OCR:** Originalstelle erreichbar, kritische Werte bestätigt, keine geratenen Referenzintervalle
- [ ] **Cloudvorschau:** Gesendeter Payload entspricht exakt der freigegebenen Auswahl
- [ ] **Offline-Cloudentwurf:** Geht nach Netzrückkehr nicht automatisch raus
- [ ] **Anbieterfehler:** Kein stiller Providerwechsel, keine unbemerkte Doppelantwort
- [ ] **Datenschutz:** Keine Keys, Falltexte oder Anhänge in normalen Logs/Crashreports
- [ ] **Falltrennung:** Anhänge, Recherchezuordnungen und Chatkontext von Fall A erscheinen niemals in Fall B
- [ ] **Brave-Payload:** Relevante medizinische Fallmerkmale erlaubt; keine automatischen Kundenfelder, keine ungeprüften kompletten Chatverläufe oder Binäranhänge
- [ ] **Schlanke Suchbedienung:** Einmaliger Hinweis, Recherche pro Gespräch aktivierbar; keine Bestätigung jeder Suchphrase/Quelle; Suchdetails erreichbar
- [ ] **Kundendaten-Hinweis:** Gezielte Warnung bei erkannten Identifikatoren, Korrektur/Fehlalarm möglich; keine pauschale Sperre medizinischer Angaben
- [ ] **Recherche ausgeschaltet:** Keine Suchanfragen, auch nicht durch Modell oder heuristische Suchauslösung
- [ ] **Quellenherkunft:** Suchauszüge nicht als gelesener Volltext dargestellt; Quellen-IDs zeigen auf echte verwendete Belege
- [ ] **Quellenabruf:** Interne Netzadressen und unzulässige Weiterleitungen blockiert; Dokumentanweisungen ändern keine Berechtigungen
- [ ] **Suchausfall:** Keine erfundene aktuelle Recherche; Offline-/Limitstatus sichtbar, kein anderer Suchanbieter als stiller Ersatz
- [ ] **Teilen:** Richtige Version/Vorschau, keine Rohanhänge ohne Auswahl, Entwurfsstatus erhalten
- [ ] **Löschen:** Fall und lokale abgeleitete Dateien nicht mehr verfügbar; Remote-Löschstatus separat

## Ausdrückliche Nutzerkorrektur

Die zusätzliche App-Authentifizierung einschließlich Face ID entfällt auf Nutzerwunsch. P1.7 gilt deshalb ohne biometrische App-Sperre; Keychain, Daten-/Dateiverschlüsselung und verdeckte App-Vorschau bleiben vorgesehen.

## Neue Reihenfolge nach Nutzersteuerung

Online-Berichte werden als Standard bei eingerichtetem API-Key vorgezogen, Gemma bleibt optional. Einmalige bewusste Aktivierung, Moduswahl im Editor, kein stiller Fallback. P2.1 ist für OpenAI technisch implementiert und mit synthetischem Transport geprüft; Anbieter-Liveprüfung und klinische Freigabe bleiben offen. Die bisherigen Offline-Gates bleiben als Qualitätsziele des optionalen lokalen Pfads erhalten und blockieren die Entwicklung des Online-Berichts nicht.

## Weitere Nutzersteuerung: Schnellcheck und Löschbedienung

Sparring ist zusätzlich ohne Fall möglich. Unabhängige Schnellchecks werden separat verschlüsselt gespeichert und dürfen weder leere Fälle erzeugen noch unbemerkt Fallkontext übernehmen. In der Fallliste erfolgt die Löschgeste von **rechts nach links**; zusätzlich steht „Fall löschen“ unten im geöffneten Fall. Der technische Stand ist in `architecture/0004-sparring-and-quick-checks.md` beschrieben. P2.2 bleibt wegen fehlender Bildverarbeitung und noch ausstehender Liveprüfung offen.
