# ADR 2 – Online-Berichte als Standard, lokales Modell optional

29.09.2026, Nutzersteuerung: Offline-Berichte optional anbieten und mit hinterlegtem API-Key regulär online arbeiten. Diese Entscheidung zieht den Online-Berichtspfad vor die vollständige Langdiktat-Abnahme von Gemma. Aufnahme und deutsche Transkription bleiben lokal. Die übrigen Ziele (Sparring, Anhänge, Brave, Android) bleiben bestehen.

## Umsetzung

Der erste Adapter verwendet OpenAI Responses. Eigener API-Key im Geräte-Keychain-Service, getrennt von Konfiguration und Fallspeicher. Modell-IDs werden aus dem Konto geladen oder ausdrücklich eingegeben; die Modellliste allein behauptet keine unterstützten Fähigkeiten. Ein synthetischer Test prüft das ausgewählte Modell gegen den tatsächlichen Berichtsvertrag. Erst „Online aktivieren“ speichert die bewusste Einstellung und setzt Online als Standard. Offline bleibt pro Bericht auswählbar. Kein automatischer Provider- oder Moduswechsel, kein Versand bei Netzrückkehr.

Der Auftrag übernimmt die gespeicherte Transkriptversion, Vorlage, Länge und Zielgruppe. Der Editor zeigt den Inhalt vor Versand. Fallkennung, strukturierter Tiername, Audio und Anhänge werden nicht automatisch hinzugefügt. Angaben innerhalb des Transkripts sind Teil des sichtbaren Texts und müssen bei Bedarf vorab entfernt werden.

`ReportTextEngine` ist die gemeinsame Schnittstelle. Der lokale Adapter hat weiterhin keine Abhängigkeit zum Cloudadapter. Online entlädt Gemma vor dem Auftrag. Online verarbeitet maximal 24 Satzquellen/12.000 Zeichen pro Abschnitt; höchstens zwölf Requests einschließlich begrenzter Reparaturversuche. Der JSON-Vertrag ist in Responses als striktes Schema gesetzt. Quelle, Zahlen, Einheiten, Negationen, vollständige Abdeckung, Zwischenstände und fachliche Freigabe werden weiterhin lokal geprüft. Ein formal gültiges JSON ist keine klinische Validierung.

Vor jedem POST wird der genaue Payload ohne Authentifizierungsheader im verschlüsselten Vorgang gespeichert. Status und tatsächlich gemeldete Modellkennung werden zugeordnet. Keine Anfrageinhalte, Keys oder Anbieterantworten in normalen Logs. Ephemere HTTPS-Session, festgelegte Anbieteradresse, abgewiesene Redirects, begrenzte Antwortgröße und Laufzeit. Auth-/Limit-/Timeoutfehler lösen keinen automatischen Neuversand aus. Ein Abbruch kann einen beim Anbieter bereits begonnenen Auftrag nicht zuverlässig rückgängig machen.

Der erste Berichtspfad nutzt vollständig abgeschlossene JSON-Antworten; noch kein Streaming. Sparring-Streaming, weitere Provider und deren eigene Modalitäts-/Datenschutzverträge sind nicht damit erledigt. Ohne API-Key wurde kein Livezugang behauptet oder aus einem anderen Projekt übernommen.

## Offizielle Grundlage, am 29.09.2026 abgerufen

- [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs): `text.format`, striktes JSON-Schema, separate Behandlung von Refusal und unvollständigen Antworten.
- [Responses-Migration](https://developers.openai.com/api/docs/guides/migrate-to-responses#additional-differences): `store: false` explizit setzen, keine persistente Konversation erforderlich.
- [Datenkontrollen](https://developers.openai.com/api/docs/guides/your-data): Deaktivierte abrufbare Antwortspeicherung bedeutet nicht automatisch Zero Data Retention; weitere Aufbewahrung hängt von Anbieter-/Kontovertrag ab.
