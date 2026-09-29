# Text-Sparring und unabhängige Schnellchecks

29.09.2026. Nutzersteuerung: Sparring muss auch ohne Fall für einen kurzfristigen Check möglich sein. Fälle sollen per Wischen von **rechts nach links** oder unten im geöffneten Fall gelöscht werden können.

**Fortgeschrieben durch [ADR 0005](0005-conversational-chat-and-attachments.md):** Normaler Chat, automatischer Verlauf und Bild-/Dokumentanhänge ersetzen die unten beschriebene erste Text-UI.

## Speicherung und Bedienung

`QuickCheck` ist ein eigenständiges Gespräch ohne klinische Fall-ID. Die neue SQLCipher-Tabelle `quick_check` speichert Entwurf und Analyseläufe verschlüsselt. Ein Schnellcheck erzeugt keinen leeren Fall. Fallbezogenes Sparring liegt weiterhin im jeweiligen Encounter. Die vollständige Datenbanktransaktion umfasst beide Bereiche; Falllöschung lässt Schnellchecks erhalten und umgekehrt. Bei der Wiederherstellung werden aktive Anfragen zu unvollständigen Zwischenständen, niemals automatisch erneut versendet.

Frage, Aufgabentyp und bearbeitbare Kopie des ausgewählten Falltexts werden lokal gespeichert. Der Benutzer kann während einer laufenden Antwort die nächste Frage bearbeiten. Änderungen betreffen nur einen späteren Auftrag. Frühere vollständige Frage-Antwort-Paare werden nur über ausdrückliche Auswahl mitgeschickt; unvollständige oder fremde Gesprächsinhalte werden vom Requestbuilder abgewiesen. Strukturierte Fallkennung und Tiername kommen nicht automatisch in den Payload. Persönliche Angaben im Freitext erfordern derzeit manuelle Bereinigung; automatische Redaktionshilfen bleiben offen.

Die Fallliste hat eine Zeile je Fall mit nativer nach links aufwischbarer Löschaktion. Die Fallansicht und der Diktateditor enthalten die Löschaktion unten. Die Bestätigung bietet „Behalten“ und „Fall endgültig löschen“. Während der Löschtransaktion kann ein ausstehender Entwurf den gelöschten Datensatz nicht erneut speichern.

## Online-Vertrag

Der erste Adapter verwendet OpenAI Responses mit dem bereits eingerichteten eigenen Key und Modell. `stream: true`, `store: false`, `background: false`, kein `previous_response_id`, keine serverseitige Conversation, keine Tools und keine Dateiuploads. Die Vorschau zeigt denselben JSON-Body, der vor dem POST unveränderlich im verschlüsselten lokalen Speicher gesichert wird. Der Key steht nur im Auth-Header.

SSE wird inkrementell mit Grenzen für gesamte Übertragung (4 MiB), einzelne Zeile/Ereignis (512 KiB), Antworttext (256 KiB), Anfrage (96 KiB) und ausgewählten Verlauf verarbeitet. Die Ausgabe ist auf 8192 Tokens begrenzt. Der lokale Speicher erlaubt zunächst 100 Analysen je Gespräch und 250 insgesamt; ein späterer paginierter Speicher kann diese konservativen Grenzen erweitern. Grenzen führen zu einer sichtbaren Fehlermeldung, nicht zu stiller Kürzung. MLX wird vor einer Onlineanalyse entladen.

HTTP verwendet eine kurzlebige Session ohne Cache/Cookies, ohne Weiterleitungen, begrenzte Zeitlimits und keine Warteschlange bis zur nächsten Netzverbindung. Fehler führen nicht zu Retry oder Providerwechsel. Der Stream wird mit Rückstau verarbeitet: Die nächste Nachricht wird erst übernommen, wenn die vorherige Verarbeitung abgeschlossen ist. Ein Zwischenstand wird spätestens beim nächsten Event nach einer Sekunde oder 8 KiB zusätzlichem Text sowie am Abschluss gespeichert. Ein harter Prozessabbruch kann den noch nicht gesicherten letzten Anteil verlieren; nach Neustart wird er ausdrücklich als unvollständig angezeigt.

Nur ein passendes `response.completed` mit Status `completed` und vollständigem Text beendet die Analyse erfolgreich. Der endgültige Text muss mit dem empfangenen Stream übereinstimmen. Verbindungsende, Abbruch, Tokenlimit, doppelte Sequenzen, ungeeignete Ereignisse oder Ablehnung erzeugen keine scheinbar vollständige Antwort. Tatsächliche Modellkennung und Tokenverbrauch werden übernommen, sofern vorhanden; Preise werden als unbekannt angezeigt. Eine erfolgreiche Antwort ist weiterhin fachlich ungeprüft und wird nie automatisch zum Befund oder Bericht.

## Nachweise und offene Teile

Vierzehn synthetische Contract-/Speichertests prüfen Auswahl und Falltrennung, fallfreien Schnellcheck, atomare Speicherung/Löschung, SSE-Framing/UTF-8/Größenlimits, inkrementellen Text/Abschluss/Usage, Ablehnung, doppelte Ereignisse, fehlgeschlagenes Speichern vor Versand, Verbindungsabbruch ohne Retry und Abbruch vor dem POST. UI-Tests prüfen einen Schnellcheck nach Neustart ohne zusätzlichen Fall, Wischen von rechts nach links sowie die Löschaktion unten mit Abbruch der Bestätigung. Ergebnisse werden in `test-status.md` nachgeführt.

Keine neue OpenAI-Liveprüfung mit einem echten Key durchgeführt. Bilder, PDF/Labor, Audioimport, automatische Redaktion, weitere Provider, Brave-Recherche, überprüfbare Quellenkarten und Übernahme geprüfter Vorschläge in Berichte bleiben offen. Der vollständige Plan ist mit diesem Textdialog nicht abgeschlossen.

Offizielle API-Grundlagen: [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses), [Streaming Events](https://developers.openai.com/api/reference/resources/responses/streaming-events#response.completed), [Datenkontrollen](https://developers.openai.com/api/docs/guides/your-data).
