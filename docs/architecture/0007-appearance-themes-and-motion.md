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

Mit „Bewegung reduzieren“ entfallen Hintergrunddrift, Pulsringe, Einblendungen und der Kreis-Übergang.

## Prüfung und Grenzen

Alle Barrierefreiheitskennungen und sichtbaren Texte, auf die die UI-Tests zugreifen, bleiben unverändert. Dekorative Symbole sind für VoiceOver ausgeblendet, damit Knopfbezeichnungen weiterhin mit der Fallkennung beginnen.

Dieser Stand wurde ohne macOS/Xcode erstellt. Die Swift-Syntax ist geprüft, ein Build, die UI-Tests und die Sichtprüfung auf dem Gerät stehen aus.
