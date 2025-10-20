# safe_whisper.py
# Transcribe en chunks y guarda progreso incremental (con resume).
# Uso:
#   python safe_whisper.py --input ".\Proceso_de_liquidación-converted.mp3" --lang es --model small --chunk_sec 600 --outdir ".\transcripts"

import argparse, os, math, subprocess, sys, glob, signal
from pathlib import Path

def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        print(p.stdout)
        raise RuntimeError(f"Comando falló: {' '.join(cmd)}")
    return p.stdout

def ensure_chunks(input_path: Path, chunk_dir: Path, chunk_sec: int):
    chunk_dir.mkdir(parents=True, exist_ok=True)
    # Re-encode a WAV mono 16k para evitar problemas de corte
    wav_path = chunk_dir / "_source_16k.wav"
    if not wav_path.exists():
        print("Convirtiendo a WAV mono 16k…")
        run(["ffmpeg", "-y", "-i", str(input_path), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav_path)])
    # Cortar en segmentos de chunk_sec (nombres 000.wav, 001.wav, …)
    print(f"Segmentando en trozos de {chunk_sec}s…")
    run([
        "ffmpeg", "-y", "-i", str(wav_path),
        "-f", "segment", "-segment_time", str(chunk_sec),
        "-c", "copy", str(chunk_dir / "%03d.wav")
    ])
    chunks = sorted(chunk_dir.glob("[0-9][0-9][0-9].wav"))
    return chunks

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Ruta del audio/video")
    ap.add_argument("--lang", default="es", help="Idioma (ej: es)")
    ap.add_argument("--model", default="small", help="Modelo whisper (tiny/base/small/medium/large)")
    ap.add_argument("--device", default=None, help="cpu o cuda (auto si None)")
    ap.add_argument("--chunk_sec", type=int, default=600, help="Duración de cada chunk en segundos")
    ap.add_argument("--outdir", default="transcripts", help="Carpeta de salida")
    args = ap.parse_args()

    input_path = Path(args.input)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    # Carpeta para los chunks
    chunk_dir = outdir / (input_path.stem + "_chunks")
    chunk_dir.mkdir(parents=True, exist_ok=True)

    # Archivo maestro incremental
    master_txt = outdir / f"{input_path.stem}.txt"
    master_srt = outdir / f"{input_path.stem}.srt"  # opcional, lo iremos sumando simple

    # Crear chunks (idempotente)
    chunks = ensure_chunks(input_path, chunk_dir, args.chunk_sec)
    if not chunks:
        print("No se generaron chunks. Revisá ffmpeg/archivo de entrada.")
        sys.exit(1)

    # Calcular horas:minutos:segundos desde índice (para encabezados)
    def sec_to_hms(s):
        h = s // 3600
        m = (s % 3600) // 60
        sec = s % 60
        return f"{int(h):02d}:{int(m):02d}:{int(sec):02d}"

    # Cargar whisper solo una vez
    import whisper
    model = whisper.load_model(args.model, device=args.device if args.device else None)

    # Permitir Ctrl+C sin corromper archivos
    interrupted = {"flag": False}
    def handle_sigint(sig, frame):
        print("\n[AVISO] Interrumpido por el usuario. Lo ya transcripto queda guardado. Podés relanzar para continuar.")
        interrupted["flag"] = True
    signal.signal(signal.SIGINT, handle_sigint)

    # Detectar chunks ya procesados por presencia de archivos .done o .txt parciales
    done_mark = ".done"
    processed = set([Path(p).stem for p in glob.glob(str(outdir / (input_path.stem + "_chunk_*" + ".txt")))])
    processed |= set([Path(p).stem for p in glob.glob(str(outdir / (input_path.stem + "_chunk_*" + ".srt")))])

    for idx, wav in enumerate(chunks):
        if interrupted["flag"]:
            break
        label = f"{idx:03d}"
        chunk_txt = outdir / f"{input_path.stem}_chunk_{label}.txt"
        if chunk_txt.exists():
            print(f"[SKIP] Ya existe {chunk_txt.name}")
            continue

        print(f"[{label}] Transcribiendo {wav.name} …")
        # Transcribir chunk
        # Nota: fp16=False si estás en CPU para evitar problemas
        result = model.transcribe(str(wav), language=args.lang, task="transcribe", fp16=False, condition_on_previous_text=False)

        # Guardado incremental por chunk (TXT + SRT básico)
        text = (result.get("text") or "").strip()
        with open(chunk_txt, "w", encoding="utf-8") as f:
            f.write(text + "\n")

        # Append seguro al maestro (TXT)
        with open(master_txt, "a", encoding="utf-8") as f:
            hms_start = sec_to_hms(idx * args.chunk_sec)
            hms_end = sec_to_hms((idx + 1) * args.chunk_sec)
            f.write(f"\n--- [Chunk {label} | {hms_start} → {hms_end}] ---\n")
            f.write(text + "\n")
            f.flush()

        # SRT “grueso” por chunk (marca de tiempo del bloque completo)
        with open(master_srt, "a", encoding="utf-8") as f:
            f.write(f"{idx+1}\n")
            f.write(f"{sec_to_hms(idx*args.chunk_sec)},000 --> {sec_to_hms((idx+1)*args.chunk_sec)},000\n")
            f.write((text or "") + "\n\n")
            f.flush()

        # Marcar como hecho
        (chunk_dir / (label + done_mark)).write_text("ok", encoding="utf-8")
        print(f"[{label}] Guardado: {chunk_txt.name}  (+ append al maestro)")

    print("\nListo. Resultado maestro:")
    print(f"- TXT: {master_txt}")
    print(f"- SRT: {master_srt}")
    print("Si se corta, solo volvé a ejecutar el mismo comando y retoma desde el último chunk pendiente.")

if __name__ == "__main__":
    main()
