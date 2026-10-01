# Drittanbieter, Modelle und Herkunft

Der eigene Code von VetMed steht unter der [MIT-Lizenz](LICENSE). Diese Lizenz gilt **nicht** für die folgenden Bibliotheken und Modelle; für sie gelten ihre eigenen Bedingungen. Wer VetMed weitergibt oder als App veröffentlicht, muss deren Lizenzhinweise mitliefern.

*English: VetMed's own code is MIT-licensed. Third-party libraries and model weights keep their own licenses, listed below.*

## iOS

Die vollständigen Lizenztexte aller direkten und transitiven Swift-Pakete liegen in [`apps/ios/VetMed/Resources/ThirdPartyNotices.txt`](apps/ios/VetMed/Resources/ThirdPartyNotices.txt) und sind in der App einsehbar. Die Paketversionen sind in [`apps/ios/project.yml`](apps/ios/project.yml) gepinnt:

| Paket | Version | Zweck |
| --- | --- | --- |
| GRDB.swift (SQLCipher-Variante) | 7.11.1 | Datenbankzugriff |
| SQLCipher.swift | 4.19.0 | Verschlüsselte Datenbank |
| mlx-swift-lm | 3.31.4 | Lokales Modell auf dem iPhone |
| swift-huggingface | 0.10.1 | Modelldownload |
| swift-transformers | 1.3.4 | Tokenizer |

Verbindlich sind die Texte in `ThirdPartyNotices.txt`, nicht diese Übersicht.

## Android

Versionen stehen in [`apps/android/gradle/libs.versions.toml`](apps/android/gradle/libs.versions.toml).

| Bibliothek | Version | Lizenz | In der App enthalten |
| --- | --- | --- | --- |
| Kotlin-Standardbibliothek, kotlinx.serialization, kotlinx.coroutines | 2.4.20 / 1.11.0 / 1.11.0 | Apache-2.0 | ja |
| AndroidX: Core, Activity, Lifecycle, Navigation, Compose (BOM 2026.09.00), Material 3, Material Icons | siehe Datei | Apache-2.0 | ja |
| AndroidX Room und SQLite | 2.8.5 / 2.7.1 | Apache-2.0 | ja |
| SQLCipher for Android (Community Edition, Zetetic) | 4.19.1 | BSD-artige SQLCipher-Lizenz | ja |
| LiteRT-LM (Google AI Edge) | 0.17.1 | Apache-2.0 | ja |
| **ML Kit Text Recognition (Google)** | 16.0.1 | **proprietär**: [ML Kit Terms](https://developers.google.com/ml-kit/terms), Binärbibliothek ohne Quellcode | ja |
| JUnit | 4.13.2 | EPL-1.0 | nur Tests |
| Robolectric | 4.17 | MIT | nur Tests |
| Roborazzi | 1.76.0 | Apache-2.0 | nur Tests |
| AndroidX Test, Compose UI Test | siehe Datei | Apache-2.0 | nur Tests |

**ML Kit ist der einzige nicht quelloffene Baustein.** Er erkennt Text in gescannten PDFs mit dem in der App enthaltenen Erkennungsmodell auf dem Gerät. Wer eine vollständig freie Android-Variante braucht (zum Beispiel für F-Droid), muss diese Texterkennung ersetzen oder abschalten. PDFs mit Textebene funktionieren ab Android 15 auch ohne ML Kit.

## Modelle (nicht im Repository)

Modellgewichte werden **nicht** mitgeliefert. Die App lädt sie nur auf ausdrücklichen Wunsch und prüft sie gegen fest hinterlegte Revisionen und SHA-256-Werte.

| Plattform | Modell | Quelle und Revision | Lizenz |
| --- | --- | --- | --- |
| iOS | Gemma 4 E2B, 4 Bit, MLX | `mlx-community/gemma-4-e2b-it-4bit` @ `238767527555cb75a05732a84dff5d6ba0dd6809` | Gemma 4: Apache-2.0 (Google). Offener Detailpunkt zur Metadatenangabe der Konvertierung, siehe [Modelllizenzprüfung](docs/upstream/MODEL-LICENSE-REVIEW.md). |
| Android | Gemma 4 E2B, LiteRT-LM | `litert-community/gemma-4-E2B-it-litert-lm` @ `b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1` | Apache-2.0 |

Online-Berichte nutzen die OpenAI-API mit dem eigenen Schlüssel der Nutzerin oder des Nutzers. Dafür gelten die Bedingungen des jeweiligen OpenAI-Kontos.

## Herkunft von Code

Einige iOS-Dateien stammen aus dem Projekt [tobwil/rag2go](https://github.com/tobwil/rag2go) desselben Rechteinhabers. Sie werden hier unter der MIT-Lizenz veröffentlicht:

- `GemmaVisionCompatibility.swift`, `DeviceReadiness.swift` und `PDFLayoutReader.swift`: unverändert übernommen
- `ModelRepository.swift`, `DocumentTextExtractor.swift`, `OutputRepetition.swift` und `MLXLocalReportEngine.swift`: angepasst

Details stehen im [Herkunftsaudit](docs/rag2go-audit.md).
