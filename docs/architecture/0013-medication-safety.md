# 0013: Arzneimittelangaben im Sparring absichern

Datum: 30.10.2026

## Anlass

Im Sparring-Chat hat die KI zu einem Präparat falsche Wirkstoffe genannt. Der Prompt verbot schon vorher erfundene Medikamente und Dosen, das hat nicht gereicht. Sprachmodelle verwechseln Handelsnamen und Wirkstoffe aus dem Gedächtnis, besonders bei Tierarzneimitteln, deren Namen sich zwischen Ländern, Herstellern und Darreichungsformen unterscheiden. Eine falsche Wirkstoffangabe kann ein Tier gefährden. Der Nutzer verlangt, dass das nicht passieren darf.

Ein Prompt allein kann das nicht garantieren. Deshalb gibt es drei Schutzebenen, und die App zeigt sichtbar an, wenn eine Angabe nicht belegt ist.

## Entscheidung

### Stufe 1: Belegpflicht im Prompt und sichtbare Warnung (iOS und Android)

- **Prompt** (`shared/prompts/sparring-v1.txt`, neuer Abschnitt „Arzneimittel, Präparate und Wirkstoffe“):
  - Wirkstoffe, Zusammensetzung, Konzentration, Darreichungsform, Zieltierarten, Zulassung und Wartezeiten eines Handelspräparats dürfen nur genannt werden, wenn sie belegt sind. Belege sind: die Frage selbst, ein Anhang (Beipackzettel, Packungsfoto, Fachinformation) oder ein Treffer der Quellensuche mit Quellenangabe.
  - Einem Handelsnamen aus dem Gedächtnis einen Wirkstoff zuzuordnen, ist ausdrücklich verboten, auch nicht als „vermutlich“ oder „meist“.
  - Fehlt ein Beleg, sagt die KI das und fragt nach dem Wirkstoff laut Packung.
  - Fragen zu einem ausdrücklich genannten Wirkstoff bleiben möglich.
- **Quellenlage je Anfrage:** Die feste Zeile „Webrecherche ist nicht aktiviert“ entfällt. Beide Apps hängen stattdessen einen Block „Quellenlage für diese Anfrage“ an, der sagt, ob eine Quellensuche verfügbar ist.
- **Erkennung in der App** (`MedicationSafety` in Kotlin und Swift, gleiche Regeln):
  - Jede fertige Antwort wird auf Arzneimittelinhalte geprüft: Begriffe wie Wirkstoff, Präparat, Dosierung, Tablette, Wartezeit, Fachinformation, Dosisangaben wie mg/kg, µg und IE sowie typische Wirkstoffendungen wie -xicam, -profen, -coxib, -laner, -mectin oder -floxacin.
  - Die Erkennung warnt im Zweifel lieber einmal zu viel.
  - Ohne amtliche Quelle erscheint unter der Antwort ein orangefarbener Hinweis „Arzneimittelangaben ungeprüft“ mit Link zur EU-Tierarzneimitteldatenbank.
  - Derselbe Hinweis steht beim Kopieren und Teilen im exportierten Text.
- **Bewusst nicht:** Die App blockiert Antworten nicht, schreibt sie nicht um und filtert sie nicht. Sie markiert sie. Damit bleibt sichtbar, was das Modell gesagt hat.

### Stufe 2: Belegte Quellensuche, nur amtliche Seiten (optional, nur OpenAI)

- Der Schalter steht unter Einstellungen → Online-Zugang → „Arzneimittelangaben im Chat“ und ist standardmäßig aus.
- Ist er an, erhält die OpenAI-Anfrage das Werkzeug `web_search`, begrenzt per `filters.allowed_domains` auf:
  - `medicines.health.europa.eu`: öffentlicher Teil der EU-Produktdatenbank
  - `ema.europa.eu`
  - `pharmnet-bund.de`
  - `bvl.bund.de`
  - `aspregister.basg.gv.at`
- `include: web_search_call.action.sources` ist gesetzt, und `store=false` bleibt.
- Die zitierten Quellen (`url_citation`) werden aus der Abschlussantwort übernommen. Nur https-Links bleiben, ohne Duplikate, höchstens 20. Sie werden mit der Antwort gespeichert (`AnalysisRun.sources`) und als „Amtliche Quellen“ angezeigt.
- Die Warnung entfällt nur, wenn mindestens eine Quelle auf einer dieser Domains liegt. Andere Links heben sie nicht auf, auch keine Täuschungsdomains wie `ema.europa.eu.example.com`.
- **Gemini bekommt Stufe 2 nicht:** Die Gemini-Suche lässt sich nicht auf Domains begrenzen, und Google verlangt bei Grounding die Anzeige eigener Suchvorschläge als HTML. Eine mit Quellensuche vorbereitete Anfrage wird an Gemini nie ohne Suche gesendet, sondern abgewiesen. Stufe 1 gilt für Gemini ebenso.
- **Kosten und Datenschutz:**
  - Jede Suche kostet zusätzlich.
  - Die Suchanfrage entsteht beim Anbieter aus der Frage; der Chat wird ohnehin an OpenAI gesendet.
  - Amtliche Seiten sind teils schwer durchsuchbar. Findet die Suche nichts, soll die KI das sagen. Die Warnung bleibt dann stehen.

### Stufe 3: Eigene Arzneimitteldatenbank (recherchiert, noch nicht umgesetzt)

Ziel wäre ein lokaler Abgleich ohne Sprachmodell: Präparat erkennen, Wirkstoffe nachschlagen, Widerspruch melden.

Ergebnis der Recherche:

| Quelle | Stand |
|---|---|
| **EU-Produktdatenbank (UPD, EMA)** | Vollständig, amtlich, EU-weit. Die REST-Schnittstelle ist nur für Behörden, Zulassungsinhaber und die Kommission freigeschaltet. Öffentlich ist die Suchseite; der Leitfaden (Kapitel 5) erwähnt öffentliche Dokument-Endpunkte. Eine freie Massendatenabgabe ist nicht belegt. |
| **AMIce (BfArM/PharmNet.Bund)** | Der öffentliche Teil ist seit 13.02.2025 kostenfrei. Ob und wie Tierarzneimittel enthalten sind und ob es eine Datenschnittstelle gibt, ist unklar. Kontakt: amgui@bfarm.de. |
| **Vetidata** | Fachlich passend, kostenpflichtig. Schnittstelle und Lizenz für Apps sind unbekannt und müssen beim Betreiber angefragt werden. |
| **BASG (Österreich)** | Das Arzneispezialitätenregister ist öffentlich durchsuchbar. Eine Schnittstelle ist nicht geprüft. |

**Empfehlung:**
1. Bei der EMA nach öffentlichem API-Zugang zur UPD bzw. nach Datenexporten fragen.
2. Parallel bei Vetidata nach Lizenz und Schnittstelle fragen.
3. Ohne Lizenz keine Daten abgreifen oder abschreiben.

Sobald eine Quelle verfügbar ist, ergänzt ein lokaler Abgleich die Stufen 1 und 2.

## Prüfung

- **Android:**
  - `MedicationSafetyTests` mit 8 Tests: Erkennung (positiv und negativ), Domain-Prüfung einschließlich Täuschungsdomains und http, Warnung und Export, Anfrage mit und ohne Werkzeug, Gemini-Abweisung, Zitat-Auswertung mit unsicheren Links, alte gespeicherte Antworten, Prompt-Inhalt
  - zwei UI-Tests: Warnung erscheint bei Arzneimittelantwort und fehlt bei normaler Antwort; Screenshot `docs/evidence/android/14-arzneimittel-warnung.png`
- **iOS:** `MedicationSafetyTests.swift` mit denselben Fällen. In dieser Umgebung ohne Xcode wurde die Logik unverändert unter Linux mit Swift 6.1 im Swift-6-Modus kompiliert und mit denselben Prüffällen ausgeführt: bestanden. Die SwiftUI-Dateien wurden nur auf Syntax geprüft. XCTest auf dem Mac steht aus.
- **Live-Prüfung mit echtem Modell:**
  - `scripts/eval-medication.sh` mit Katalog `shared/fixtures/medication-eval-de.json`: 3 erfundene und 17 reale Präparate, jeweils mit und ohne Quellensuche.
  - Regeln: Ein erfundenes Präparat bekommt nie eine Zusammensetzung. Reale Wirkstoffe werden nur mit amtlicher Quelle genannt und sind dann vollständig.
  - Die Prüfung braucht einen eigenen Key und ist **noch nicht gelaufen**.

## Grenzen

- Kein Prompt und keine Erkennung garantieren fehlerfreie Antworten.
- Die Warnung erkennt Arzneimittelinhalte über Begriffe und Wirkstoffendungen. Ein Wirkstoff mit ungewöhnlicher Endung ohne weiteres Schlüsselwort bleibt unmarkiert; Präparatnamen allein erkennt sie nicht.
- Die Quellensuche belegt nur, was die amtliche Seite tatsächlich hergibt.
- Die fachliche Verantwortung bleibt bei der Tierärztin oder dem Tierarzt.
