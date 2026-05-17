#!/usr/bin/env python3
import argparse
import contextlib
import io
import json
import os
import sys
from pathlib import Path


def main() -> int:
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo-q4")
    parser.add_argument("--dictionary", default=str(Path.home() / ".klaus-flow" / "dictionary.json"))
    args = parser.parse_args()

    try:
        import imageio_ffmpeg
        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        # imageio's binary is named "ffmpeg-macos-aarch64-..."; mlx_whisper invokes the
        # bare command "ffmpeg" via subprocess. Stage a symlink under a stable name.
        link_dir = Path.home() / ".klaus-flow" / ".ffmpeg-shim"
        link_dir.mkdir(parents=True, exist_ok=True)
        link_path = link_dir / "ffmpeg"
        if not link_path.exists() or link_path.resolve() != Path(ffmpeg_exe).resolve():
            if link_path.exists() or link_path.is_symlink():
                link_path.unlink()
            link_path.symlink_to(ffmpeg_exe)
        os.environ["PATH"] = str(link_dir) + os.pathsep + os.environ.get("PATH", "")
    except Exception:
        pass

    import mlx_whisper

    initial_prompt = None
    dictionary_path = Path(args.dictionary)
    if dictionary_path.exists():
        try:
            payload = json.loads(dictionary_path.read_text())
            replacements = payload.get("replacements", {})
            if replacements:
                initial_prompt = ", ".join(dict.fromkeys(replacements.values()))
        except Exception:
            pass

    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        result = mlx_whisper.transcribe(
            args.audio,
            path_or_hf_repo=args.model,
            verbose=False,
            initial_prompt=initial_prompt,
            condition_on_previous_text=False,
        )
    output = {
        "text": result.get("text", "").strip(),
        "language": result.get("language"),
        "model": args.model,
    }
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
