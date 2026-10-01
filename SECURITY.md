# Sicherheit

VetMed verarbeitet tierärztliche Falldaten. Sicherheitslücken nehmen wir ernst.

*English: Please report vulnerabilities privately via GitHub's "Report a vulnerability" (Security tab), not as a public issue.*

## Lücke melden

1. Im Repository auf **Security** → **Report a vulnerability** gehen. Die Meldung ist dort nur für die Maintainer sichtbar.
2. Beschreiben:
   - was betroffen ist
   - wie es sich nachstellen lässt
   - welche Plattform und welche Version betroffen sind
3. **Keine echten Patientendaten und keine echten API-Keys** mitschicken.

Bitte melde Sicherheitslücken nicht als öffentliches Issue und veröffentliche Details erst, wenn ein Fix bereitsteht.

## Was besonders interessiert

- Verschlüsselung der Fall-Datenbank (SQLCipher) und der Dateien (AES-GCM), Schlüsselablage in Schlüsselbund bzw. Android Keystore
- Wege, auf denen Fallinhalte ungewollt das Gerät verlassen: Backups, Logs, Vorschauen, Netzwerk
- Verarbeitung von Anhängen (Bilder, PDFs, Text) und Exporten
- Download und Prüfung der Modellgewichte
- Umgang mit dem OpenAI-API-Key

## Grenzen

VetMed ist ein Entwicklungsstand ohne klinische Freigabe und ohne Sicherheitszertifizierung. Es gibt keine garantierten Reaktionszeiten. Unterstützt wird jeweils nur der aktuelle Stand von `main`.
