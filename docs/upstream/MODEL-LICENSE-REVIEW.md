# Gemma 4: offene Lizenz und konkreter Release-Nachweis

Stand 16.09.2026. Technische Bestandsaufnahme, keine individuelle Rechtsberatung. Die allgemeinen rechtlichen Freigaben wurden vom Inhaber bestätigt; der hier ausdrücklich benannte Detailpunkt ist darin nicht nachweislich aufgelöst.

## Ist das nicht Open Source?

**Ja: Google veröffentlicht Gemma 4 unter Apache 2.0**, einer offenen Lizenz, die auch kommerzielle Nutzung, Änderungen und Weitergabe unter ihren Bedingungen erlaubt. Es ist keine zusätzliche kostenpflichtige Modelllizenz allein für unsere kommerzielle App erforderlich. „Offen“ bedeutet aber nicht „ohne Lizenzpflichten“: Lizenzkopie, einschlägige Urheber-/Attributions- und gegebenenfalls NOTICE-Hinweise erhalten, Änderungen kennzeichnen. Eine allgemeine Marken- oder Zertifizierungsfreigabe ist damit nicht verbunden. [Google: Apache 2.0](https://ai.google.dev/gemma/apache_2)

Die frühere Überschrift „Lizenz-Blocker“ war zu pauschal: Es gibt keinen hier nachgewiesenen grundsätzlichen Ausschluss einer App-Store- oder B2B-Nutzung. Der offene Punkt betrifft die **konkrete Community-Konvertierung**, nicht die grundsätzliche Offenheit von Gemma 4. Die Lizenz sagt außerdem nichts über vollständige Trainingsdatenoffenlegung oder Modellqualität aus. Bedingungen älterer Gemma-Versionen dürfen nicht ungeprüft auf Gemma 4 übertragen werden.

## Exakt verwendete Dateien

| Quelle | Gepinnte Revision | Tatsächliche Angabe |
| --- | --- | --- |
| mlx-community/gemma-4-e2b-it-4bit | 238767527555cb75a05732a84dff5d6ba0dd6809 | YAML `license: gemma` |
| google/gemma-4-E2B-it | 70af34e20bd4b7a91f0de6b22675850c43922a03 | YAML `license: apache-2.0`; Link zu Google Gemma-4-Lizenz |

Die MLX-Modellkarte nennt genau diese Google-Quellrevision, die Variante 4bit und `mlx_vlm.convert`. Die Repo-Dateiliste enthält keine eigene LICENSE-/NOTICE-Datei. Ein veraltetes Metadatenlabel ist plausibel, aber bislang **nicht vom Konvertierungsanbieter bestätigt**. Die Apache-Rechte der Google-Quelle werden nicht allein durch ein anderes YAML-Label widerlegt. Umgekehrt erfinden wir keine bestätigte Erklärung des Konvertierungsanbieters.

## Belege

- https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/raw/238767527555cb75a05732a84dff5d6ba0dd6809/README.md
- https://huggingface.co/api/models/mlx-community/gemma-4-e2b-it-4bit/revision/238767527555cb75a05732a84dff5d6ba0dd6809
- https://huggingface.co/google/gemma-4-E2B-it/raw/70af34e20bd4b7a91f0de6b22675850c43922a03/README.md
- https://ai.google.dev/gemma/apache_2

## Bereits umgesetzt und verbleibender Abschluss

- Vollständige Apache-2.0-Kopie und Herkunfts-/Konvertierungshinweis offline in `RAG2Go/Gemma4-LICENSE.txt` beigefügt; Lizenztexte über die App erreichbar. Gewichte, Revision und Hashes unverändert.
- Direkte und transitive Softwareabhängigkeiten separat inventarisiert; Lizenztexte in `ThirdPartyNotices.txt`. Die App-Lizenz allein ersetzt nicht die Modell-/Paketbedingungen.
- KIsruptiv gleicht die bestätigte Rechtsfreigabe noch mit **dieser konkreten Metadatenabweichung und dem NOTICE-Inventar** ab beziehungsweise holt die Klarstellung beim Konvertierungsanbieter ein. Keine Nachricht/Vertragserklärung wurde automatisch in fremdem Namen versendet.
- Falls stattdessen eine neue oder eigene Konvertierung gewählt wird: bewusste Entscheidung, neue Revision/Hashes und erneute Geräte-/Qualitätsprüfung. Kein stiller Gewichtstausch.

`modelAndSoftwareLicences` bleibt bis zu diesem dokumentierten Detailabschluss offen. Das ist eine Projekt-Freigaberegel, keine Behauptung, Apache 2.0 verbiete kommerziellen Vertrieb.
