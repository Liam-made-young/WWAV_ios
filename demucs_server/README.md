# wwav demucs server

Tiny FastAPI wrapper around [Demucs](https://github.com/facebookresearch/demucs)
so the iOS app can get **real** 4-stem separation (vocals / drums / bass / other)
without paying for a third-party API.

## Run

```bash
cd demucs_server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python server.py
```

First run downloads the `htdemucs` model (~80 MB) into `~/.cache/torch`. Apple
Silicon Macs use MPS automatically, so a 3-minute song separates in roughly
30–60 s.

Server listens on `127.0.0.1:8765`.

- **Simulator:** the iOS app talks to `http://127.0.0.1:8765` — works as-is.
- **Real device:** in `WWAV/Audio/StemSeparationService.swift`, change the
  default `baseURL` to your Mac's LAN IP, e.g. `http://192.168.1.42:8765`,
  and make sure your phone is on the same Wi-Fi.

## API

| Method | Path                         | Description                            |
| ------ | ---------------------------- | -------------------------------------- |
| POST   | `/separate`                  | multipart `file=<audio>` → `{job_id}`  |
| GET    | `/jobs/{id}`                 | `{ state, progress, stems?, error? }`  |
| GET    | `/jobs/{id}/stem/{name}`     | WAV bytes — name ∈ vocals/drums/bass/other |
| GET    | `/health`                    | liveness probe                          |

## Swap in a hosted API

`StemSeparationService` is a protocol. To use Moises / LALAL / AudioShake
instead, write a new conformance and inject it into `TrackLibrary` —
no other code needs to change.
