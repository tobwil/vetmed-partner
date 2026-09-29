#!/usr/bin/env python3
"""Create explicitly synthetic German ASR stress fixtures with locally installed macOS voices.
These measure technical transcription behavior, not real microphone or veterinary quality.
"""
from pathlib import Path
import json
import subprocess
import wave

root = Path(__file__).resolve().parents[1] / '.build' / 'speech-fixtures'
root.mkdir(parents=True, exist_ok=True)
base = ('Synthetischer Testfall. Ein Hund wiegt zwölf Komma fünf Kilogramm. '
        'Seit gestern ist der Appetit vermindert. Kein Erbrechen. '
        'Die Temperatur wurde nicht gemessen. Eine Kontrolle in drei Tagen wurde vereinbart. '
        'Die Beschwerden betreffen das linke Hinterbein. Rechts wurden keine Beschwerden berichtet. '
        'Eine Diagnose ist noch nicht gesichert. Weitere Ergebnisse stehen aus. ')
metadata = []
for seconds, repeats, voice in [(30, 1, 'Anna'), (120, 4, 'Anna'), (300, 10, 'Anna')]:
    text = ''.join(f'Abschnitt {i + 1}. {base}' for i in range(repeats))
    source = root / f'synthetic-{seconds}s.txt'
    aiff = root / f'synthetic-{seconds}s.aiff'
    target = root / f'synthetic-{seconds}s.wav'
    source.write_text(text)
    subprocess.run(['say', '-v', voice, '-r', '175', '-f', str(source), '-o', str(aiff)], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(target)], check=True)
    with wave.open(str(target), 'rb') as f:
        params = f.getparams(); audio = f.readframes(f.getnframes()); spoken = params.nframes / params.framerate
    # Never truncate speech to hit an arbitrary duration; pad short audio with silence.
    padding = max(0, seconds * params.framerate - params.nframes)
    with wave.open(str(target), 'wb') as f:
        f.setparams(params); f.writeframes(audio + b'\x00' * padding * params.sampwidth * params.nchannels)
    aiff.unlink()
    metadata.append({'file': target.name, 'synthetic': True, 'voice': voice, 'spokenSeconds': spoken,
                     'totalSeconds': max(seconds, spoken), 'source': source.name,
                     'expectedPhrases': ['Appetit', 'Erbrechen', 'Temperatur', 'Kontrolle'], 'clinicalReview': 'pending'})
(root / 'manifest.json').write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + '\n')
print(json.dumps(metadata, ensure_ascii=False))
