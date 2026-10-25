#if !APPSTORE
import Foundation

/// `coucou-video <video ID or link>`: lets Claude see and hear a video, not just its numbers.
/// Downloads it with yt-dlp into the studio's `videos/<id>/`, writes `transcript.txt` (YouTube's
/// captions, or Whisper on this Mac when there are none), `meta.txt` and `sheet.jpg` (12 screenshots
/// in one image) plus the frames. Written into the studio folder; Claude runs it with Bash.
enum VideoTool {
    /// Writes the studio's tools (`coucou-video`, `coucou-render`); returns their folder.
    @discardableResult
    static func install(in studio: URL) -> URL {
        let bin = studio.appendingPathComponent(".coucou/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, text) in [("coucou-video", script), ("coucou-render", renderScript)] {
            let tool = bin.appendingPathComponent(name)
            try? text.write(to: tool, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        return bin
    }

    /// The private Python of the Shorts engine (numpy, Pillow, Playwright, faster-whisper).
    static var python: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CoucouStudio/.venv-shorts/bin/python").path
    }

    /// `coucou-render <episode folder> [engine options]`: runs the episode's engine in the background
    /// (a full video takes 10–18 min) and records it in .coucou/renders/, which Coucou watches to show
    /// the progress and then the video. `--stills …` runs at once (a contact sheet, seconds).
    /// `coucou-render stop <episode folder>` stops it.
    private static let renderScript = #"""
    #!/bin/zsh
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    studio="$(cd "$(dirname "$0")/../.." && pwd)"
    py="$HOME/CoucouStudio/.venv-shorts/bin/python"
    [ -x "$py" ] || { echo "Error: the Shorts engine isn't installed (~/CoucouStudio/.venv-shorts)."; exit 1; }
    mode=run
    [ "$1" = "stop" ] && { mode=stop; shift; }
    ep="$1"; shift
    [ -z "$ep" ] && { echo "Usage: coucou-render <episode folder> [--start S --end E --out file.mp4 | --stills t1 t2 … | --audio-only]"; exit 2; }
    [ -d "$studio/$ep" ] && ep="$studio/$ep"
    ep="$(cd "$ep" 2>/dev/null && pwd)" || { echo "Error: no folder $1"; exit 2; }
    case "$ep" in "$studio"/*) ;; *) echo "Error: the episode must be inside the studio folder."; exit 2;; esac
    cd "$ep"
    engine=render_v2.py; [ -f "$engine" ] || engine=render.py
    [ -f "$engine" ] || { echo "Error: no render_v2.py or render.py in $ep"; exit 2; }
    jobs_dir="$studio/.coucou/renders"; mkdir -p "$jobs_dir" build
    name="$(basename "$ep")"

    if [ "$mode" = stop ]; then
      for f in "$jobs_dir"/"$name"-*.json(N); do
        pid=$("$py" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("pid","") if d.get("state")=="running" else "")' "$f")
        [ -n "$pid" ] && pkill -TERM -P "$pid" 2>/dev/null; [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "Stopped $name."
      done
      exit 0
    fi

    if (( ${@[(Ie)--stills]} )); then
      "$py" "$engine" "$@" 2>&1 | tail -3
      echo "Contact sheet: ${ep#$studio/}/build/stills.jpg (read it to check the layout)"
      exit 0
    fi

    out=""; start=0; end=""
    args=("$@")
    for ((i = 1; i <= ${#args}; i++)); do
      case "${args[i]}" in
        --out) out="${args[i+1]}";;
        --start) start="${args[i+1]}";;
        --end) end="${args[i+1]}";;
      esac
    done
    if [ -z "$out" ]; then
      mkdir -p renders
      out="$ep/renders/${name}_$(date +%Y%m%d-%H%M%S).mp4"
      args+=(--out "$out")
    fi
    case "$out" in /*) ;; *) out="$ep/$out";; esac
    id="$name-$(date +%s)"
    job="$jobs_dir/$id.json"; log="$ep/build/render-$id.log"
    write() { "$py" -c 'import json,sys,time; json.dump({"id":sys.argv[1],"episode":sys.argv[2],"out":sys.argv[3],"log":sys.argv[4],"start":float(sys.argv[5] or 0),"end":float(sys.argv[6] or 0),"state":sys.argv[7],"pid":sys.argv[8],"time":time.time()}, open(sys.argv[9],"w"))' "$id" "${ep#$studio/}" "${out#$studio/}" "$log" "$start" "$end" "$1" "$2" "$job"; }
    write running ""
    (
      "$py" "$engine" "${args[@]}" > "$log" 2>&1
      rc=$?
      if [ $rc -eq 0 ] && [ -s "$out" ]; then write done ""; else write failed ""; fi
    ) </dev/null >/dev/null 2>&1 &!
    write running "$!"
    echo "Render started in the background: ${out#$studio/}"
    echo "A full video takes about 10–18 minutes. Coucou shows the progress in Studio and plays the video there when it's done — tell the owner, and don't wait for it."
    """#

    private static let script = #"""
    #!/bin/zsh
    # coucou-video <video ID or YouTube link> — what's inside a video, for Claude.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    has_vtt() { local f=(*.vtt(N)); (( ${#f} )); }
    in="$1"
    [ -z "$in" ] && { echo "Usage: coucou-video <video ID or YouTube link>"; exit 2; }
    id=$(print -r -- "$in" | sed -E 's#.*(v=|shorts/|youtu\.be/|embed/)##; s#[?&/].*##')
    [ ${#id} -eq 11 ] || { echo "Error: no video ID in '$in'"; exit 2; }
    studio="$(cd "$(dirname "$0")/../.." && pwd)"
    dir="$studio/videos/$id"
    mkdir -p "$dir" && cd "$dir" || exit 1
    command -v yt-dlp >/dev/null || { echo "Error: yt-dlp is missing. Ask the owner to run: brew install yt-dlp"; exit 1; }
    url="https://www.youtube.com/watch?v=$id"

    # Captions first, on their own: a refused language must not stop the video.
    if ! has_vtt; then
      yt-dlp -q --no-warnings --skip-download --write-subs --write-auto-subs --sub-langs "fr-orig,fr" \
        --sub-format vtt -o "subs.%(ext)s" "$url" 2>/dev/null
      has_vtt || yt-dlp -q --no-warnings --skip-download --write-subs --write-auto-subs \
        --sub-langs "en-orig,en" --sub-format vtt -o "subs.%(ext)s" "$url" 2>/dev/null
    fi
    if [ ! -f video.mp4 ]; then
      yt-dlp -q --no-warnings -f "best[height<=720][ext=mp4]/best[height<=720]/best" --write-info-json \
        --remux-video mp4 -o "video.%(ext)s" "$url" 2>&1 | tail -3
    fi
    [ -f video.mp4 ] || { echo "Error: the download failed (YouTube may be limiting requests; try again in a few minutes)."; exit 1; }
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 video.mp4)

    # No captions on YouTube: transcribe on this Mac (Python Whisper, else whisper.cpp), as captions.
    if ! has_vtt && [ ! -s transcript.txt ]; then
      ffmpeg -v error -y -i video.mp4 -ar 16000 -ac 1 audio.wav
      if command -v whisper >/dev/null; then
        whisper audio.wav --model small --output_format vtt --output_dir . --verbose False >/dev/null 2>&1
        [ -f audio.vtt ] && mv audio.vtt whisper.vtt
      fi
      if ! has_vtt && command -v whisper-cli >/dev/null; then
        # A real multilingual ggml model (failed downloads leave tiny HTML files behind).
        model=$(find "$HOME/whisper-models" "$HOME/models" -name 'ggml-*.bin' -size +20M 2>/dev/null | grep -v '\.en\.bin' | head -1)
        [ -n "$model" ] && whisper-cli -m "$model" -l auto -np -ovtt -of whisper -f audio.wav >/dev/null 2>&1
      fi
      rm -f audio.wav
    fi

    # What's said, with timestamps.
    if [ ! -s transcript.txt ]; then
      vtt=$(print -l -- *.vtt(N) | head -1)
      if [ -n "$vtt" ]; then
        python3 -I - "$vtt" > transcript.txt <<'PY'
    import re, sys
    out, last, stamp = [], "", "00:00"
    for line in open(sys.argv[1], encoding="utf-8"):
        line = line.strip()
        m = re.match(r"(\d+):(\d+):(\d+)\.\d+ -->", line) or re.match(r"(\d+):(\d+)\.\d+ -->", line)
        if m:
            g = [int(x) for x in m.groups()]
            s = g[0] * 3600 + g[1] * 60 + g[2] if len(g) == 3 else g[0] * 60 + g[1]
            stamp = f"{s // 60:02d}:{s % 60:02d}"
            continue
        if not line or line.startswith(("WEBVTT", "Kind:", "Language:")) or line.isdigit():
            continue
        text = re.sub(r"<[^>]+>", "", line).strip()
        if text and text != last:
            out.append(f"[{stamp}] {text}")
            last = text
    print("\n".join(out))
    PY
      else
        echo "(No captions on YouTube and no working Whisper on this Mac: nothing transcribed.)" > transcript.txt
      fi
    fi

    # 12 screenshots, and one contact sheet with all of them.
    if [ ! -f sheet.jpg ]; then
      mkdir -p frames
      ffmpeg -v error -y -i video.mp4 -vf "fps=12/$dur,scale=480:-2" frames/f%02d.jpg
      w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 video.mp4)
      h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 video.mp4)
      if [ "$h" -gt "$w" ]; then layout="6x2"; size="300:-2"; else layout="3x4"; size="520:-2"; fi
      ffmpeg -v error -y -i video.mp4 -vf "fps=12/$dur,scale=$size,tile=$layout" -frames:v 1 sheet.jpg
    fi

    if [ ! -f meta.txt ] && [ -f video.info.json ]; then
      python3 -I - video.info.json > meta.txt <<'PY'
    import json, sys
    d = json.load(open(sys.argv[1]))
    print("Title:", d.get("title")); print("Published:", d.get("upload_date")); print("Duration:", d.get("duration"), "s")
    print("Views:", d.get("view_count"), "| Likes:", d.get("like_count"), "| Comments:", d.get("comment_count"))
    print("Tags:", ", ".join(d.get("tags") or [])); print(); print("Description:"); print(d.get("description") or "")
    PY
    fi

    echo "Video $id — $(printf '%.0f' "$dur") s — files in videos/$id/"
    echo "- sheet.jpg: 12 screenshots in order (left to right, top to bottom). Read it to see the video."
    echo "- frames/f01.jpg … f12.jpg: the same screenshots, larger."
    echo "- transcript.txt: what is said, with [mm:ss] timestamps ($(wc -l < transcript.txt | tr -d ' ') lines)."
    echo "- meta.txt: title, description, tags, numbers."
    """#
}
#endif
