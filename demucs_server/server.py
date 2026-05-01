"""
WWAV — local Demucs separation server.

Run alongside the iOS app:

    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    python server.py

The iOS app POSTs an audio file to /separate, polls /jobs/{id} for progress,
and downloads the four stems via /jobs/{id}/stem/{name}.

This is a thin wrapper around `demucs.separate` that runs jobs in a thread
pool and exposes a tiny REST surface. Stems land in ./jobs/{job_id}/stems/.
"""
from __future__ import annotations

import asyncio
import os
import shutil
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse

ROOT = Path(__file__).parent.resolve()
JOBS_DIR = ROOT / "jobs"
JOBS_DIR.mkdir(exist_ok=True)

# demucs canonical 4-stem names
STEM_NAMES = ("vocals", "drums", "bass", "other")

# Demucs model — htdemucs is the best general-purpose 4-stem model.
MODEL = os.environ.get("WWAV_DEMUCS_MODEL", "htdemucs")

executor = ThreadPoolExecutor(max_workers=1)  # one separation at a time
app = FastAPI(title="WWAV Demucs Server")


@dataclass
class Job:
    id: str
    state: str = "queued"            # queued | running | done | error
    progress: float = 0.0            # 0..1
    stems: List[str] = field(default_factory=list)
    error: Optional[str] = None
    out_dir: Optional[Path] = None


JOBS: Dict[str, Job] = {}


def _run_demucs(job: Job, source_path: Path) -> None:
    """Blocking. Runs the demucs CLI and parses its stderr for progress."""
    job.state = "running"
    job.progress = 0.02

    out_root = JOBS_DIR / job.id / "stems"
    out_root.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable, "-m", "demucs",
        "-n", MODEL,
        "-o", str(out_root),
        "--filename", "{stem}.{ext}",
        str(source_path),
    ]

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        # demucs writes progress as a tqdm-style line; parse the percentage.
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            # heuristic — last "%"-formatted token in the line
            for token in reversed(line.split()):
                if token.endswith("%"):
                    try:
                        job.progress = max(job.progress, min(0.99, float(token[:-1]) / 100))
                    except ValueError:
                        pass
                    break
        rc = proc.wait()
        if rc != 0:
            raise RuntimeError(f"demucs exited with code {rc}")

        # demucs writes to {out_root}/{model}/{trackname}/{stem}.wav by default,
        # or with --filename pattern: {out_root}/{model}/{trackname}/{stem}.wav
        # Locate the produced stems.
        candidates = list(out_root.rglob("*.wav"))
        produced: Dict[str, Path] = {}
        for p in candidates:
            stem_name = p.stem.lower()
            if stem_name in STEM_NAMES:
                produced[stem_name] = p
        if set(produced.keys()) != set(STEM_NAMES):
            raise RuntimeError(
                f"missing stems: produced={list(produced.keys())} "
                f"expected={list(STEM_NAMES)}"
            )

        # Flatten into job.out_dir for easy serving.
        flat_dir = JOBS_DIR / job.id / "out"
        flat_dir.mkdir(parents=True, exist_ok=True)
        for name in STEM_NAMES:
            dest = flat_dir / f"{name}.wav"
            if dest.exists():
                dest.unlink()
            shutil.copyfile(produced[name], dest)

        job.out_dir = flat_dir
        job.stems = list(STEM_NAMES)
        job.progress = 1.0
        job.state = "done"
    except Exception as exc:
        job.state = "error"
        job.error = str(exc)
        job.progress = 1.0


@app.post("/separate")
async def separate(file: UploadFile = File(...)) -> JSONResponse:
    job_id = uuid.uuid4().hex[:12]
    src_dir = JOBS_DIR / job_id / "src"
    src_dir.mkdir(parents=True, exist_ok=True)
    suffix = Path(file.filename or "input.wav").suffix or ".wav"
    src_path = src_dir / f"input{suffix}"
    with src_path.open("wb") as out:
        shutil.copyfileobj(file.file, out)

    job = Job(id=job_id)
    JOBS[job_id] = job

    loop = asyncio.get_running_loop()
    loop.run_in_executor(executor, _run_demucs, job, src_path)

    return JSONResponse({"job_id": job_id})


@app.get("/jobs/{job_id}")
async def job_status(job_id: str) -> JSONResponse:
    job = JOBS.get(job_id)
    if not job:
        raise HTTPException(404, "unknown job")
    return JSONResponse({
        "state": job.state,
        "progress": job.progress,
        "stems": job.stems,
        "error": job.error,
    })


@app.get("/jobs/{job_id}/stem/{name}")
async def get_stem(job_id: str, name: str) -> FileResponse:
    job = JOBS.get(job_id)
    if not job or job.state != "done" or not job.out_dir:
        raise HTTPException(404, "stem not ready")
    if name not in STEM_NAMES:
        raise HTTPException(400, "unknown stem name")
    path = job.out_dir / f"{name}.wav"
    if not path.exists():
        raise HTTPException(404, "stem missing on disk")
    return FileResponse(path, media_type="audio/wav", filename=f"{name}.wav")


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"ok": True, "model": MODEL})


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=int(os.environ.get("WWAV_PORT", "8765")),
        reload=False,
    )
