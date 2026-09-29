# Herkunft und Wiederverwendung

Prüfung am 29.09.2026. Quelle: https://github.com/tobwil/rag2go

- Ausgelesener Commit: `d06132b90aa86082bd4ed76a17e965889c237820` (`main`).
- README und project.yml: Wissenswerk 2.0.0 / Build 24, Swift 6, MLXLM 3.31.4.
- Keine AGENTS.md im aktuellen Checkout gefunden.
- Das im Plan erwähnte ZIP ist lokal nicht vorhanden. Gleiche Versionsangaben sind **kein** Bytegleichheitsnachweis des ZIPs.
- Der separate Referenzcheckout bleibt unverändert. Keine Umstellung von Wissenswerk, kein Zugriff auf seine App-Daten.

## Übernahmen

`GemmaVisionCompatibility.swift`, `DeviceReadiness.swift` und `PDFLayoutReader.swift` direkt übernommen. `ModelRepository.swift` auf eigene Datenwurzel umgestellt. `DocumentTextExtractor.swift` vom alten ChatImage-Typ entkoppelt. Wiederholungserkennung aus `GroundedAnswerCheck.swift` extrahiert.

`MLXLocalReportEngine.swift` adaptiert den vorhandenen ModelService: sequenzielles Tokenizer-/Gewichteladen, Gemma-Kompatibilitätsregistrierung, 32-MiB-GPU-Cachegrenze, 6000 Eingabetokens, 8192 KV-Tokens und Synchronisierung des GPU-Produzenten vor Cachefreigabe bei Abbruch. Die Berichtsantwort hat 2048 Ausgabetokens statt 1024; dieser Unterschied benötigt neue Gerätemessungen. Lange Quellen werden abschnittsweise verarbeitet und ohne erneute verlustbehaftete Zusammenfassung zusammengefügt.

Modellmanifest enthält ausschließlich E2B, Revision `238767527555cb75a05732a84dff5d6ba0dd6809`. Gewichte werden nicht eingecheckt. Die Schlüssel von Wissenswerk werden nicht gelesen. Kein HTTP-Gastserver, Bonjour oder Automationsstart wurde übernommen.

Die ursprüngliche Modelllizenzprüfung steht unter `docs/upstream/MODEL-LICENSE-REVIEW.md`; offene Punkte bleiben offen. Kein allgemeiner Repository-Lizenztext wurde gefunden. Nutzer stellt sein eigenes Repository ausdrücklich zur App-Umsetzung bereit; Veröffentlichung und Drittanbieterhinweise sind noch abschließend zu prüfen.

Berichtssampling wurde nach realen Format-/Auslassungsfehlern auf Temperatur 0,2 reduziert. Der erfolgreiche Zehnfachlauf und Abbruchtest sind im aktuellen Prüfstand belegt. Dies ist eine bewusste Abweichung vom ursprünglichen Dialog-Sampling, keine Änderung des Modellstacks.

Nach weiteren langen synthetischen Läufen wurde für lokale Berichte Greedy-Decoding (Temperatur 0) eingestellt und der äußere Modellvertrag auf `items` reduziert. Der frühere erfolgreiche Zehnfachlauf verwendete Temperatur 0,2 und gilt nicht als erneute Belastungsabnahme dieser späteren Änderung.
