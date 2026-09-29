# 0006: Aufgabennavigation, formatierter Chat und stabile Übergaben

Datum: 29.09.2026

## Anlass

Der Nutzer wünscht einen normalen Chat, spontane Fragen ohne Fall, eine einfachere Oberfläche, tatsächlich formatierte Antworten und funktionierende Übergaben über Teilen → WhatsApp.

## Umsetzung

Drei Bereiche: Start, Fälle und Chat. Start bietet Diktat/Frage und letzte Vorgänge; Einstellungen liegen am Zahnrad. Diktate führen durch Aufnahme, Textprüfung und Bericht. Berichtsvorlage, Länge und Zielgruppe bleiben anpassbar und werden als Vorgaben gemerkt. Fall-Chats sind aus Diktat und Fall erreichbar. Neue unabhängige Chats haben einen sichtbaren Knopf; ihr Kontext steht dauerhaft über den Nachrichten.

Editoren tragen unveränderliche Fall-/Vorgangs-IDs. Speichern, Aufnahme, Transkription, Berichte, Freigabe und Exportprotokolle verwenden diese IDs statt globaler Auswahl. Das Öffnen eines anderen Chats ändert offene Diktate nicht. Gelöschte Vorgänge können durch verspätete Editoraktionen nicht wiederangelegt werden.

Antworten verwenden native AttributedString-Darstellung für Fett, Kursiv, Links und Inline-Code sowie eigene Blöcke für Überschriften, Listen, Zitate und Code. Es gibt keine WebView, HTML-Ausführung oder automatische externe Bildabrufe. HTTP(S)-Links bleiben bedienbar. Tabellen werden derzeit als Text dargestellt. Kopieren/Teilen erzeugt Klartext mit Zahlen, Negationen, Linkzielen und dem Hinweis auf ungeprüfte bzw. unvollständige KI-Antworten.

Text wird als unveränderliches NSString über UIActivityItemSource mit public.utf8-plain-text angeboten. Das Teilenmenü hält den konkreten Inhalt und den ursprünglichen Bericht fest. Hintergrundwechsel verdecken die App weiterhin und beenden aktive Arbeiten; sie bauen aber nicht mehr die komplette Navigation und Teilenansicht ab. Temporäre Exporte werden beim Öffnen erst nach 24 Stunden entfernt; beim Falllöschen sofort. Fehler beim Teilen erscheinen verständlich. Ein abgeschlossener iOS-Aktivitätscallback ist kein Nachweis der Zustellung an einen Kontakt.

## Prüfung und Grenzen

SQLCipher-Tests prüfen verzögertes Speichern/Freigabe/Export nach Kontextwechsel sowie Aktionen nach Löschung. Formatierungs- und Klartexttests prüfen Hervorhebungen, Zahlen/Negationen, Links und Warnungen. ItemSource-Vertragstests prüfen vollständige Nutzdaten auch für den WhatsApp-Aktivitätstyp; das ersetzt keinen echten WhatsApp-Test.

UI-Tests verwenden ausschließlich synthetische, explizit aktivierte Fixtures im separaten UI-Test-Speicher. Sie prüfen unabhängige Navigation, sichtbare Formatierung sowie die System-Teilenansicht vor und nach Hintergrundwechsel. Die Systemaktion Copy muss als Zelle innerhalb der Teilenansicht angesprochen werden, nicht als gleichnamiger Knopf des darunterliegenden Berichts. Der tatsächliche Zwischenablageinhalt wird geprüft. Ergebnisse und Geräteinstallation werden im Prüfstand dokumentiert.

Echte WhatsApp-Übergabe auf dem Nutzergerät, klinische Qualität und die übrigen Meilenstein-Gates bleiben getrennte Abnahmen.
