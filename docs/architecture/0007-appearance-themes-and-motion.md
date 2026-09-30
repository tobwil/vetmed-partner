# 0007: Tag/Nacht, Farbthemen und Animationen

Datum: 29.09.2026

## Anlass

Der Nutzer wünscht eine deutlich modernere Oberfläche mit Tag/Nacht-Schalter, wählbaren Farbthemen und Animationen.

## Umsetzung

`Views/Theme.swift` bündelt das Erscheinungsbild:

- **Tag/Nacht:** `AppearanceMode` (Automatisch, Tag, Nacht) liegt in `@AppStorage("appearance-mode")` und wird über `overrideUserInterfaceStyle` auf alle Fenster angewendet. Der Sonne/Mond-Schalter auf Start blendet die neue Darstellung mit einem wachsenden Kreis vom Schalter aus ein; Änderungen in den Einstellungen werden überblendet.
- **Farbthemen:** `AccentTheme` (Klinik, Ozean, Lavendel, Koralle, Wald, Graphit) liegt in `@AppStorage("accent-theme")`. Jedes Thema hat für Tag und Nacht eigene Primär- und Verlaufsfarben. Die App setzt daraus `tint` und `\.accentTheme`; auch Sheets übernehmen das.
- **Oberfläche:** ruhig wandernder Mesh-Verlauf als Hintergrund, Karten auf Start mit Kennzahlen (Fälle, zu prüfende Berichte, Chats), Tierarten-Symbole, Verlaufs-Aufnahmetaste mit pulsierenden Ringen, animierter Schrittwechsler, Chatblasen im Themenverlauf mit Tippindikator sowie Liquid-Glass-Bedienelemente von iOS 26.
- **Rückmeldung:** Haptik bei Aufnahme, Schrittwechsel, Freigabe, Kopieren und Themenwahl.

Mit „Bewegung reduzieren“ entfallen Hintergrunddrift, Pulsringe und der Kreis-Übergang. Die Einblendungen verzichten auf den vertikalen Versatz. Eine vollständige Barrierefreiheitsabnahme aller Animationen steht noch aus.

## Prüfung und Grenzen

Alle Barrierefreiheitskennungen und sichtbaren Texte, auf die die UI-Tests zugreifen, bleiben unverändert. Dekorative Symbole sind für VoiceOver ausgeblendet, damit Knopfbezeichnungen weiterhin mit der Fallkennung beginnen.

Der ursprüngliche Branch wurde ohne macOS/Xcode erstellt. Build und UI-Abnahme werden bei der Integration vom 30.09.2026 nachgeholt; Ergebnisse stehen im [Prüfstand](../test-status.md).

## Übernahme am 30.09.2026

Auf ausdrücklichen Nutzerwunsch wird `claude/optimized-ui-themes-animations-4a60zm` bei Commit `02793da08e32aab5f8ad65af2aff070e0843b563` übernommen, für das iPhone gebaut und anschließend auf `main` veröffentlicht. Die Designänderungen bleiben in ihrem ursprünglichen Commit erhalten. Das Xcode-Projekt wird aus `project.yml` reproduzierbar neu erzeugt. Ein zusätzlicher UI-Test prüft Tag/Nacht, die Farbthemenauswahl und ihren Fortbestand nach Neustart.
