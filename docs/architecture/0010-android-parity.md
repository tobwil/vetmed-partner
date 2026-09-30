# 0010: Android-Funktionsparität mit iOS

Datum: 30.09.2026

## Anlass

Nach dem Android-Start ([0009](0009-android-start.md)) fehlten auf Android noch Aufnahme mit lokaler Spracherkennung, das Offline-Modell, Chat mit Anhängen und der PDF-Export. Der Nutzer bittet, das zu vervollständigen. Ziel ist derselbe fachliche Vertrag wie auf iOS: keine Attrappen, kein stiller Wechsel zwischen Online und Offline, klinische Inhalte nur verschlüsselt auf dem Gerät.

## Umsetzung

**Chat mit Anhängen** (Portierung von [0004](0004-sparring-and-quick-checks.md), [0005](0005-conversational-chat-and-attachments.md) und [0008](0008-report-audience-and-chat-context.md)):

- Datenmodell, Anfrageaufbau, Streaming-Decoder und Budgets liegen in `:core`. Schnellchecks ohne Fall bekommen eine eigene Tabelle `quick_check`; die Room-Migration 1→2 lässt vorhandene Fälle unverändert.
- Der Chat nutzt die Responses API mit `store=false`, SSE-Streaming und dem unveränderten Prompt `shared/prompts/sparring-v1.txt`.
- Anhänge werden vor dem Senden lokal vorbereitet:
  - Bilder werden neu als JPEG kodiert, gedreht, auf höchstens 4096 px und 2 MB gebracht und verlieren dabei alle Metadaten.
  - Texte müssen gültiges UTF-8 sein.
  - PDFs werden über die Textebene gelesen (ab API 35), sonst per ML-Kit-OCR auf dem Gerät. Eine Kürzung wird ausdrücklich vermerkt.
  - Extrahierter Text muss vor dem Senden bestätigt werden.
- Original und Upload-Fassung liegen AES-GCM-versiegelt pro Chat. Der Kontext ist im Schlüsselmaterial gebunden, eine verschobene Datei entschlüsselt also nicht.
- Eine laufende Antwort wird vor dem Senden gespeichert und regelmäßig gesichert. Ein Abbruch durch Prozessende wird beim nächsten Start als unterbrochen markiert.
- Antworten werden als sichere Markdown-Teilmenge nativ gerendert: keine Web-Ansicht, keine entfernten Bilder, nur http(s)-Links.

**PDF-Export:**

- `PdfDocument` im A4-Format mit Seitenumbruch über `StaticLayout`. Ein Entwurf ist als „ENTWURF“ markiert.
- Die Datei entsteht erst beim Teilen im Cache-Ordner `exports/`, wird über einen `FileProvider` freigegeben und spätestens nach 24 Stunden gelöscht, beim Löschen des Falls sofort.
- Der Teilvorgang wird erst protokolliert, wenn eine Ziel-App gewählt wurde.

**Aufnahme und lokale Spracherkennung:**

- `AudioRecorder` nimmt 16 kHz Mono-PCM auf und gibt alle 20 Sekunden ein Segment ab. Jedes Segment wird sofort als WAV versiegelt (`audio/{Fall}/{Vorgang}/{Segment}.sealed`). Nur das laufende Segment liegt unverschlüsselt im Scratch-Ordner in `noBackupFilesDir`.
- Scheitert das Versiegeln, bleibt der Klartext für die Wiederherstellung liegen, statt verloren zu gehen. Beim nächsten Start werden solche Reste ihrem Fall zugeordnet und versiegelt. Reste ohne Fall werden gelöscht.
- Die Mikrofonberechtigung wird erst beim ersten Aufnahmeknopf angefragt. Während der Aufnahme bleibt der Bildschirm an.
- Android schaltet das Mikrofon im Hintergrund ohne Foreground-Service stumm. Deshalb pausiert die App beim Verlassen kontrolliert, wie iOS `background()`: Das Segment wird gesichert, die Wiedergabe gestoppt und ein ruhendes Modell entladen.
- Transkribiert wird ausschließlich mit `SpeechRecognizer.createOnDeviceSpeechRecognizer`. Die Datei wird über `EXTRA_AUDIO_SOURCE` als segmentierte Sitzung eingespeist.
- Fehlen die deutschen Ressourcen, meldet die App das. Sie lädt sie nur auf ausdrücklichen Knopfdruck (`triggerModelDownload`); es gibt keinen Cloud-Erkenner als Ausweichweg.
- Unter „Original und Aufnahme“ stehen der Rohtext und die Wiedergabe je Satz, wie auf iOS.

**Optionales Offline-Modell:**

- Gemma 4 E2B im LiteRT-LM-Format aus `litert-community/gemma-4-E2B-it-litert-lm`, Apache-2.0, nicht zugangsbeschränkt.
- Revision `b3ca0d2f…`, Dateigröße (2 588 147 712 Byte) und SHA-256 sind im Code fest hinterlegt. Hugging Face meldet für diese Revision dieselbe Größe und denselben Hash (`X-Linked-Size`, `X-Linked-ETag`).
- Der Download:
  - startet nur auf Knopfdruck in den Einstellungen und läuft nur über HTTPS; Weiterleitungen werden selbst verfolgt;
  - lässt sich per HTTP-Range an derselben Stelle fortsetzen;
  - beginnt von vorn, wenn ein Server den Range ignoriert.
- Die Datei wird erst nach bestandener Hash-Prüfung an ihren Platz verschoben. Vor jedem Laden wird sie erneut vollständig geprüft.
- LiteRT-LM startet zuerst auf der GPU und fällt auf die CPU zurück, wenn der GPU-Delegate nicht startet. Beides bleibt auf dem Gerät.
- Sampling ist deterministisch (Temperatur 0, `topK` 1) und das Denken des Modells aus. Eine Wiederholungsschleife bricht wie auf iOS ab.
- Laden wird verweigert bei weniger als etwa 8 GB Arbeitsspeicher, 32-Bit-Geräten oder starker Erwärmung.
- Bei Speicherdruck, vor einer Aufnahme und beim Verlassen der App wird das ruhende Modell entladen.
- Der Modus wird pro Bericht gewählt. Ohne installiertes Modell scheitert Offline mit klarer Meldung; es wird nichts geladen und nichts online gesendet.
- R8-Regeln halten das Paket `com.google.ai.edge.litertlm` vollständig, weil die Bibliothek aus nativem Code in Kotlin-Klassen zurückruft und selbst keine Regeln mitliefert.

**Größe:**

- Die nativen Bibliotheken von LiteRT-LM (etwa 22 MB für arm64) und ML-Kit-OCR vergrößern die unsignierte Universal-Release-APK auf etwa 103 MB.
- Ein App-Bundle liefert pro Gerät nur eine Architektur.
- Alle nativen Bibliotheken sind auf 16-KB-Seiten ausgerichtet (ELF-Prüfung und `zipalign -P 16`).

## Prüfung und Grenzen

- `:core`: 81 JVM-Tests, darunter:
  - Chat-Vertrag und Budgets
  - Markdown-Teilmenge
  - WAV-Format
  - Modell-Manifest (keine Branches, keine Pfadtricks)
  - fortgesetzter Download nach Verbindungsabbruch
  - Server ohne Range-Unterstützung
  - manipulierte Datei (wird verworfen und nie installiert)
  - nachträglich veränderte Datei (wird beim Laden abgelehnt)
  - Speicherplatzprüfung vor jedem Netzwerkzugriff
  - Wiederholungsschutz und Geräteprüfung
- `:app`: 36 Tests auf Robolectric:
  - Aufnahme: Segmentwechsel, Systemabbruch, fehlgeschlagenes Versiegeln mit Wiederherstellung, Speicherplatz und Doppelstart
  - Chat-Speicher mit Migration und ortsgebundener Anhangsverschlüsselung
  - Bildaufbereitung ohne Metadaten
  - PDF-Seitenumbruch
  - 13 Compose-UI-Tests, darunter:
    - Aufnahme mit synthetischem Mikrofon: versiegelte Segmente, kein Klartext im Scratch-Ordner, Transkript im Editor
    - Sprachressourcen: nur auf Knopfdruck
    - Offline-Bericht: erst Fehlermeldung ohne Download, dann ausdrückliche Installation und ein Bericht ohne Cloud-Anfrage, mit Modell-ID und Revision in der Provenienz
- Lint ohne Befunde. Debug- und R8-Release-Build bauen.
- Screenshots `docs/evidence/android/01–13`.

**Nicht geprüft, weil es in der Build-Umgebung weder Emulator (kein KVM) noch Gerät gab:**

- Mikrofon und `SpeechRecognizer` auf echter Hardware. Die Tests ersetzen beide durch synthetische Quellen, einschließlich der Frage, ob der Erkenner die Datei-Eingabe auf dem jeweiligen Gerät unterstützt.
- LiteRT-LM mit den echten Gewichten. Die UI-Tests nutzen eine synthetische Laufzeit; Download, Prüfung, Pipeline, Provenienz und Entladen sind echter Code.
- Der echte 2,6-GB-Download. Geprüft wurde nur, dass die gepinnte URL per Weiterleitung auf das CDN mit `206 Partial Content` antwortet.
- ML-Kit-OCR, `PdfDocument`, das Teilen-Menü und SQLCipher/Keystore auf Hardware.
- OpenAI-Aufrufe gegen den echten Dienst.

Für die Geräteabnahme liegen `SqlCipherDeviceTests`, `ReportPdfDeviceTests` und `LocalModelDeviceTests` bereit. Letzterer erzeugt mit dem installierten Gemma einen Bericht aus einem synthetischen Transkript und prüft Zahlen und Verneinung. Ohne installiertes Modell wird er übersprungen, statt einen Download auszulösen.

Brave-Recherche gibt es auch auf iOS noch nicht und ist daher kein Paritätsthema.

## Offene Entscheidungen

- Der Keystore-Schlüssel verlangt weiterhin kein entsperrtes Gerät (siehe 0009).
- Download und Aufnahme laufen ohne Foreground-Service. Beim Verlassen der App pausiert die Aufnahme, der Download setzt beim nächsten Versuch fort. Ein Foreground-Service mit Benachrichtigung wäre möglich, zeigt aber dauerhaft an, dass aufgenommen wird. Das ist vor einem Pilot zu entscheiden.
- Die Qualität der Gemma-Berichte auf Android ist nicht belegt. Wie auf iOS gibt es ohne eigene Geräte- und Fachabnahme keine klinische Freigabe.
