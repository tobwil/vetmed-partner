# Berichtszielgruppe und Berichte als Chatwissen

Nutzerentscheidung vom 30.09.2026: „Für wen?“ entfernen; Fallberichte im Fallchat nutzbar machen und die Auswahl sichtbar anbieten.

## Berichtserstellung

`ReportTemplate.audience` bestimmt die Zielgruppe: ausschließlich `owner_information` richtet sich an Tierhalter; Behandlung, SOAP, Verlauf/Kontrolle und Überweisung an tierärztliche Fachkollegen. `VetAppModel.generate` leitet den Wert selbst ab und akzeptiert keine unabhängige Zielgruppenwahl mehr. Die bisherige UserDefaults-Auswahl wird nicht mehr gelesen. Gespeicherte Berichte behalten ihre historische Zielgruppe und bleiben dekodierbar. Vorlage, Länge und Online-/Offline-Modus bleiben einstellbar.

## Fallchat

Oberhalb des Eingabefelds zeigt „Fallberichte als Wissen“ die aktuelle Auswahl. Beim ersten Öffnen mit noch nicht initialisierter Berichtsauswahl wird die neueste nicht ersetzte Berichtsversion des aktuellen Vorgangs ausgewählt. Gibt es dort keinen Bericht, wird der neueste Bericht desselben Falls vorausgewählt. Fehlen Berichte vollständig, bleibt die Auswahl leer. Eine bewusst gespeicherte Auswahl wird später nicht automatisch ersetzt oder ergänzt.

Die Auswahlansicht und das Plus-Menü erlauben mehrere Berichte aus sämtlichen Vorgängen desselben Falls. Titel, Vorgangs-/Versionsdatum, Prüfstatus, Kennzeichnung älterer Revisionen und Textvorschau sind sichtbar. Ungeprüfte Entwürfe werden auch gegenüber dem Modell ausdrücklich als ungeprüft gekennzeichnet. `ReportVersion.text` berücksichtigt manuelle Änderungen. Prüfhinweise werden mitgesendet. Es wird kein unvollständiger Pipeline-Checkpoint als fertiger Bericht übernommen.

`SparringDraft.reportIDs` ist optional für Bestandsdaten: `nil` erlaubt die einmalige Vorauswahl in der Chatansicht, `[]` ist eine ausdrückliche Abwahl. IDs werden mit dem Entwurf verschlüsselt gespeichert und beim Leeren des Eingabefelds nach Versand behalten. Freie Chats ohne Fall haben keine Berichtsauswahl.

`ChatReportSelection.resolve` prüft Fall- und Vorgangszuordnung sowie fehlende/doppelte Berichtsversionen. `SparringSnapshot.reports` enthält den tatsächlich verwendeten vollständigen Stand mit Datum, Text, Warnungen und Prüfstatus. Der vollständige JSON-Request wird wie bisher vor dem Versand gesichert. Spätere Änderungen beeinflussen gespeicherte Anfragen nicht.

Für Folgefragen werden die aktuell ausgewählten Berichte einmal angefügt. Alte Berichtsdokumente werden nicht aus früheren Requests erneut angehängt; deren gespeicherte Snapshots bleiben erhalten. Frühere Nutzer- und Assistentennachrichten bleiben im Gespräch und können weiterhin inhaltliche Bezüge zu einem abgewählten Bericht enthalten. Dies wird in der Auswahl erläutert. Abwählen löscht weder Chatgeschichte noch bereits beim Anbieter verarbeitete Inhalte.

Bis zu 20 Berichte können ausgewählt werden; das bestehende Limit von 96 KiB für den gesamten Request bleibt maßgeblich. Übergröße führt zu einem erklärten Fehler, niemals zu stiller Kürzung. Der API-Zugang und ein ausdrücklicher Sendevorgang bleiben erforderlich.

## Prüfung

Fünf zusätzliche Vertragstests prüfen ausgewählte bearbeitete Berichte mehrerer Vorgänge, unveränderliche Snapshots, Ausschluss fremder/fehlender/doppelter Quellen, Abwahl in Folgefragen, ältere Revisionen, Bestandsdaten und das Größenlimit. Ein UI-Test prüft Vorauswahl, Textvorschau, Abwahl, Neustart und erneute Auswahl. Der bestehende Navigationstest prüft zusätzlich Fallwechsel und unabhängige Chats. Live-Anbieterantworten und fachliche Qualität sind damit nicht geprüft.
