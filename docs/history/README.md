# Projektarchiv und erster GitHub-Stand

Dieses Verzeichnis verbindet das Projektgespräch mit dem tatsächlich implementierten Stand. Die App heißt **VetMed**, das GitHub-Repository **vetmed-partner**. Es handelt sich um einen Entwicklungsstand mit dokumentierten offenen Abnahmen.

## Einstieg

| Dokument | Inhalt |
|---|---|
| [Projektchronik](project-history.md) | Ausgangsauftrag, Entscheidungen, Nutzerkorrekturen, Umsetzungsschritte und Commit-Zuordnung |
| [Gesprächsarchiv](conversation-2026-09-29.md) | 109 sichtbare Nachrichten, Rückfragen, Antworten und Nutzerziele dieser Projektaufgabe bis zum GitHub-Auftrag |
| [Gespräch als JSON](conversation-2026-09-29.json) | Derselbe Verlauf mit Zeitstempeln und Nachrichtentypen |
| [Technische Übergabe](handoff.md) | Einstieg in den Code, Build/Test, letzter Gerätestand und nächste Arbeiten |
| [Originalplan](../implementation-plan.md) | Vollständig übernommener Umsetzungsplan vom 26.09.2026, Version 1.3 |
| [Anforderungsnachverfolgung](../requirements-trace.md) | Voller Zielumfang und ausdrücklich noch offene Gates |
| [Prüfstand](../test-status.md) | Was geprüft wurde, was fehlgeschlagen ist und was noch nicht nachgewiesen ist |
| [Architekturentscheidungen](../architecture/) | Sechs Entscheidungen zu Pipeline, Online-Modus, Aufnahme, Chat und Navigation/Teilen |
| [Nachweise](../evidence/) | Synthetische Testergebnisse, Geräteprotokolle und Bildschirmfotos |

## Umfang und Herkunft

Das Gesprächsarchiv beginnt mit der Übergabe des Plans und der rag2go-Referenz am 29.09.2026, 20:32 Uhr (Europe/Berlin), und endet mit dem Veröffentlichungsauftrag um 23:51 Uhr. Es enthält den sichtbaren Verlauf dieser Projektaufgabe einschließlich Fortschrittsmeldungen. Die ursprüngliche Planung außerhalb dieser Aufgabe liegt als vollständiges Plandokument vor; sie wird nicht als vorhandenes Originaltranskript ausgegeben.

Nutzerziele und Antworten aus Formularen sind als solche gekennzeichnet. Automatische Fortsetzungen wurden entfernt. Lokale Projekt-/Planpfade sind angepasst. Interne Anweisungen, Modellüberlegungen und rohe Werkzeugausgaben gehören nicht zum Gesprächsexport. Die technischen Ergebnisse sind stattdessen im Code, in den Git-Commits und den Nachweisen nachvollziehbar.

Die ursprünglichen Entwicklungs-Commits bleiben erhalten. Der bereits auf GitHub vorhandene README-Initialcommit wird über einen Merge eingebunden; die Historie wird nicht durch einen einzelnen Dateiupload ersetzt.

Enthalten sind Quellcode, Projektkonfiguration, Abhängigkeitsauflösung, Schemas, Prompts, synthetische Fixtures, Dokumentation und ausgewählte Nachweise. Modellgewichte, Buildprodukte, temporäre Sitzungsdateien, API-Keys, App-Datenbanken und echte Fall-/Patientendaten werden nicht veröffentlicht. Die vorliegende Geräteinstallation und die in den Nachweisen genannten Tests sind keine abgeschlossene klinische oder Store-Freigabe.
