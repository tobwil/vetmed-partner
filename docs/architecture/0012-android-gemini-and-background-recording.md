# 0012: Android – Gemini online und Aufnahme im Hintergrund

Datum: 15.10.2026

## Anlass

Auf dem Pixel 9a (Android 17) blieb die Transkription einer 38:30 min langen Aufnahme bei „Transkription 1 von 116“ stehen und endete mit „Abgebrochen“. Eine Geräteprobe mit eigener Test-App zeigte: Der On-Device-Erkenner des Systems (Android System Intelligence, `createOnDeviceSpeechRecognizer`) meldet `onReadyForSpeech` und liefert danach nichts mehr. Das gilt für Datei- und Pipe-Eingabe, mit und ohne segmentierte Sitzung, für Deutsch und Englisch und sogar für Mikrofon-Eingabe. Selbst `checkRecognitionSupport` antwortet nicht. Der Standard-Erkenner (Speech Services by Google) lehnt Dateieingabe sofort mit Fehler 5 ab. Nach 120 s griff der Timeout. Weil `TimeoutCancellationException` eine `CancellationException` ist, zeigte die App fälschlich „Abgebrochen“.

Der Nutzer entscheidet: Falls lokal nicht möglich, wird online mit Gemini (`gemini-3.6-flash`) und eigenem API-Key transkribiert. Die Aufnahme soll außerdem weiterlaufen, wenn die App nicht im Vordergrund ist, und derselbe Gemini-Key soll auch für den Online-Zugang (Berichte, Chat) nutzbar sein. Damit wird [0002](0002-online-default.md) („Transkription bleibt lokal“) für Android optional erweitert.

## Entscheidung

- **Online-Transkription (optional):** Nur nach ausdrücklichem Einschalten in Einstellungen → Spracherkennung → „Online-Transkription (Gemini)“. Je sechs 20-s-Segmente gehen als WAV in einer `generateContent`-Anfrage an Gemini. Die Antwort ist striktes JSON mit genau einem Text pro Segment, damit jeder Text seinem Audiosegment zugeordnet bleibt. 429 und 5xx werden dreimal wiederholt, alles andere scheitert sichtbar. Die Fachwortliste geht als Hinweis mit.
- **Fortschritt bleibt erhalten:** Erkannter Text wird auch bei Fehler oder Abbruch als Transkriptversion gespeichert. Ein erneuter Start transkribiert nur die übrigen Segmente. Ein Timeout des Gerät-Erkenners ist ein Fehler mit Hinweis auf Gemini, kein „Abgebrochen“. Während Aufnahme und Transkription bleibt der Bildschirm an.
- **Online-Anbieter OpenAI oder Gemini:** `OnlineReportConfiguration.provider` wählt den Anbieter für Berichte und Chat. Gemini nutzt denselben verschlüsselten Key wie die Transkription. Berichte verwenden `responseSchema` mit demselben Item-Vertrag (Abschnitt, Text, Quellen-ID, Zitat) und derselben lokalen Prüfung. Der Chat speichert weiterhin den anbieterneutralen Snapshot und übersetzt ihn erst beim Senden in `contents` mit `streamGenerateContent?alt=sse`. Nur ein Ereignis mit `finishReason` beendet eine Antwort, und nur `STOP` mit Text gilt als vollständig. Der Key steht nur im Header `x-goog-api-key`. Es gibt keinen automatischen Anbieterwechsel.
- **Aufnahme im Hintergrund:** Ein Foreground-Service vom Typ `microphone` läuft genau so lange wie eine auf dem Bildschirm gestartete Aufnahme und zeigt einen Hinweis in der Statusleiste. Verlassen der App pausiert nicht mehr. Wird die App endgültig geschlossen, endet die Aufnahme; das angefangene Segment wird beim nächsten Start wie bisher wiederhergestellt.
- **Diagnose:** Fehlgeschlagene Vorgänge schreiben ihre App-Fehlermeldung (ohne Transkript- oder Berichtsinhalt) als Warnung ins Log.

## Datenschutz

Mit Gemini verlassen Audiosegmente bzw. das geprüfte Transkript das Gerät. Die App weist darauf hin, für Patientendaten nur einen Key mit aktivierter Abrechnung zu verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen ([Nutzungsbedingungen](https://ai.google.dev/gemini-api/terms)).

## Offen

- iOS hat weder Gemini noch Hintergrundaufnahme.
- Ein echter Gemini-Bericht und -Chat auf dem Gerät sind noch nicht abgenommen; die Transkription einer 38-min-Aufnahme lief auf dem Pixel durch.
- Online-Berichte aus langen Gesprächstranskripten scheitern an der Vollständigkeitsprüfung jedes Satzes (siehe [Prüfstand](../test-status.md)).
