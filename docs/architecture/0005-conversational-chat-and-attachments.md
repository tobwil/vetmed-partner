# Normaler Chat mit Bildern und Befunden

29.09.2026. Nutzersteuerung: Sparring soll sich wie ein normaler Chat bedienen lassen – Frage eingeben, Bilder/Dateien hinzufügen, Antwort erhalten. Diese Entscheidung ersetzt die formularorientierte Bedienung und manuelle Verlaufsauswahl aus ADR 0004.

## Bedienung

Eine Nachrichtenansicht mit Eingabe unten, Plus-Menü und Senden/Abbrechen ersetzt Aufgabentypen, Kontexteditor, Verlaufsauswahl und obligatorische Vorschau. Vollständige frühere Frage-Antwort-Paare desselben Chats werden automatisch übernommen. Andere Fälle und unvollständige Antworten bleiben ausgeschlossen. Ein neuer Chat ist über das Menü erreichbar; Schnellchecks brauchen weiterhin keinen Fall. Falltranskripte können ausdrücklich hinzugefügt werden. Die Antwortanweisungen passen Länge und Gliederung an die Frage an, ohne ein starres Berichtsschema.

Entwürfe speichern automatisch. Die Eingabe wird erst geleert, wenn der neue Auftrag im Chat erscheint; fehlender API-Zugang oder eine abgewiesene Anfrage erhalten den Entwurf. API-Konfiguration, Modell, Verbrauch und Anfragedetails liegen im optionalen Detailbereich. Bilder werden als kleine Vorschaubilder dargestellt, nicht mehrfach in voller Auflösung im Verlauf dekodiert. Die Falllöschung bleibt rechts nach links und unten im Fall.

## Anhänge und Speicherung

JPG, PNG und HEIC werden lokal über ImageIO vorbereitet: Orientierung anwenden, längste Kante höchstens 4096 Pixel, JPEG-Qualität 0,88, Standort-/Kamerametadaten nicht übernehmen. Maximal 20 MiB / 64 Megapixel Original und 2 MiB Versandbild; zu große Versandbilder werden mit einer verständlichen Aufforderung zu einem geeigneten Ausschnitt abgewiesen. Die Bildvorschau zeigt tatsächliche Versandmaße. Das Original bleibt erhalten. Im Bild eingebrannte Angaben werden nicht automatisch entfernt.

PDFs (höchstens 50 Seiten) und UTF-8-Texte werden lokal ausgelesen, gescannte PDF-Seiten nötigenfalls lokal per Vision erkannt. Höchstens 100.000 Textzeichen; Zahlen/Einheiten werden nicht normalisiert, Tabellen nicht fachlich interpretiert. Vor Versand ist eine ausdrückliche Prüfung des Textes möglich und erforderlich; das PDF-Original lässt sich daneben öffnen. Gesendet wird der geprüfte Text, nicht das PDF. Original und überprüfte Fassung bleiben getrennt. Strukturierte Laborübernahme mit Quellenkoordinaten ist damit noch nicht implementiert.

Original und Versandbild liegen als getrennte AES-GCM-Dateien mit Fall-/Chat-/Anhangs-ID und Variante als authentifiziertem Kontext vor. Metadaten liegen in SQLCipher; Binärbilder werden nicht in die Gesprächsdatenbank eingebettet. Import liest begrenzte Blöcke und prüft Dateigröße, verfügbaren RAM (mindestens 512 MiB vor Import, 256 MiB vor Bildversand) und Gerätespeicher. MLX wird vor Import/Versand entladen. Foto-Zwischenkopien tragen iOS-Dateischutz und werden nach Import bzw. beim Wiederanlauf entfernt. Fehlgeschlagene Metadatenspeicherung entfernt neue Dateien; Wiederanlauf bereinigt verwaiste verschlüsselte Anhänge. Fall-/Chatlöschung entfernt zugehörige Dateien. Entfernen eines Chips nimmt einen Anhang nur aus dem Entwurf; lokal bleibt er unter „Vorhandene Anhänge“ verfügbar.

## Anfragevertrag

Textanfragen behalten den bisherigen exakten JSON-Snapshot. Bildanfragen speichern ein kanonisches JSON-Manifest mit lokalen Bildreferenzen sowie SHA-256, Byteanzahl und Maßen der Versandbilder. Erst beim Senden werden diese Referenzen durch `input_image` mit Base64-JPEG ersetzt; Größe und Hash jedes Bildes müssen übereinstimmen. Der verschlüsselte Snapshot enthält somit keine mehrfachen Base64-Kopien. Unbekannte, fehlende oder veränderte Referenzen verhindern den Versand.

Bilder aus früheren vollständigen Nachrichten desselben Chats bleiben im Kontext. Grenzen: acht Bilder / 16 MiB komprimierte Bilder insgesamt pro Anfrage, 96 KiB Textmanifest, 24 MiB tatsächlicher JSON-Body. Es gibt keine stille Verlaufskürzung. Bei Überschreitung fordert die App zu einem neuen Chat auf. Das gewählte Modell muss Bilder unterstützen; ein Providerfehler wechselt weder Modell noch entfernt er unbemerkt die Bilder. Streaming, Persistenz vor Versand, kein automatischer Retry und fachlicher Prüfstatus aus ADR 0004 bleiben bestehen.

Die API-Verbindung ist über synthetische Verträge geprüft; echte Bild-/Chatantworten mit dem Nutzer-Key und klinische Qualität sind separat abzunehmen. Keine Kamera-Direktaufnahme, Audio-Dateianhänge, weitere Provider oder Webrecherche in dieser Änderung.

Offizielle Schnittstelle: [OpenAI Images and vision](https://developers.openai.com/api/docs/guides/images-vision).
