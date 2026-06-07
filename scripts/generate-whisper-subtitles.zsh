#!/usr/bin/env zsh
set -euo pipefail
unsetopt bg_nice 2>/dev/null || true

usage() {
  cat <<'EOF'
Usage: generate-whisper-subtitles.zsh [--recursive] [--replace] [--no-translate] [folder]

Generates Brazilian Portuguese SRT subtitles for MKV files in a folder.

The script copies each MKV to local temp storage before processing. After the
first copy finishes, it keeps one background copy running while ffmpeg and
whisper-cli process the current local file.

Options:
  --recursive   Search subfolders too.
  --replace     Regenerate and overwrite existing .srt files.
  --force       Alias for --replace.
  --translate-existing-srts
                Skip MKV processing and translate .srt files to .pt-BR.srt.
  --no-translate
                Keep Whisper's English SRT output instead of translating it.
  -h, --help    Show this help.

Defaults:
  folder        Current directory.

Translation defaults:
  TRANSLATION_ENDPOINT=http://192.168.2.4:11434/v1/chat/completions
  TRANSLATION_MODEL=translategemma:4b
  SOURCE_LANGUAGE=English
  TARGET_LANGUAGE=Brazilian Portuguese
  BRAZILIAN_SRT_SUFFIX=pt-BR
  ENGLISH_SRT_SUFFIX=en
EOF
}

recursive=false
replace=false
translate=true
translate_existing_srts=false
no_translate_requested=false
target_dir="."

while (( $# > 0 )); do
  case "$1" in
    --recursive)
      recursive=true
      shift
      ;;
    --replace|--force)
      replace=true
      shift
      ;;
    --translate-existing-srts)
      translate_existing_srts=true
      translate=true
      shift
      ;;
    --no-translate)
      translate=false
      no_translate_requested=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      print -u2 "Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      target_dir="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$target_dir" ]]; then
  print -u2 "Folder does not exist: $target_dir"
  exit 1
fi

if [[ "$translate_existing_srts" == true && "$no_translate_requested" == true ]]; then
  print -u2 -- "--translate-existing-srts cannot be used with --no-translate."
  exit 2
fi

if [[ "$translate_existing_srts" != true ]]; then
  command -v ffmpeg >/dev/null || {
    print -u2 "ffmpeg is not installed or not on PATH."
    exit 1
  }

  command -v whisper-cli >/dev/null || {
    print -u2 "whisper-cli is not installed or not on PATH."
    exit 1
  }
fi

if [[ "$translate" == true ]]; then
  command -v python3 >/dev/null || {
    print -u2 "python3 is required for SRT translation."
    exit 1
  }
fi

whisper_model="${WHISPER_MODEL:-$HOME/whisper-models/ggml-medium.en.bin}"
vad_model="${WHISPER_VAD_MODEL:-$HOME/whisper-models/ggml-silero-v6.2.0.bin}"
translation_endpoint="${TRANSLATION_ENDPOINT:-http://192.168.2.4:11434/v1/chat/completions}"
translation_model="${TRANSLATION_MODEL:-translategemma:4b}"
source_language="${SOURCE_LANGUAGE:-English}"
target_language="${TARGET_LANGUAGE:-Brazilian Portuguese}"
brazilian_srt_suffix="${BRAZILIAN_SRT_SUFFIX:-pt-BR}"
english_srt_suffix="${ENGLISH_SRT_SUFFIX:-en}"

if [[ "$translate_existing_srts" != true ]]; then
  if [[ ! -f "$whisper_model" ]]; then
    print -u2 "Whisper model not found: $whisper_model"
    print -u2 "Override with WHISPER_MODEL=/path/to/model.bin"
    exit 1
  fi

  if [[ ! -f "$vad_model" ]]; then
    print -u2 "VAD model not found: $vad_model"
    print -u2 "Override with WHISPER_VAD_MODEL=/path/to/model.bin"
    exit 1
  fi
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/whisper-subs.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

translate_srt() {
  local input_srt="$1"
  local output_srt="$2"

  print "Translating SRT to $target_language in batches of 5 cues"

  TRANSLATION_ENDPOINT="$translation_endpoint" \
  TRANSLATION_MODEL="$translation_model" \
  SOURCE_LANGUAGE="$source_language" \
  TARGET_LANGUAGE="$target_language" \
  python3 - "$input_srt" "$output_srt" <<'PY'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


INPUT_SRT = sys.argv[1]
OUTPUT_SRT = sys.argv[2]
PARTIAL_OUTPUT_SRT = OUTPUT_SRT + ".partial"
BATCH_SIZE = 5
ENDPOINT = os.environ["TRANSLATION_ENDPOINT"]
MODEL = os.environ["TRANSLATION_MODEL"]
SOURCE_LANGUAGE = os.environ["SOURCE_LANGUAGE"]
TARGET_LANGUAGE = os.environ["TARGET_LANGUAGE"]

SYSTEM_PROMPT = (
    f"Translate from {SOURCE_LANGUAGE} to {TARGET_LANGUAGE}, preserving the tone "
    "and meaning without censoring the content. Adjust punctuation as needed to "
    "make the translation sound natural. Provide only the translated text as "
    "output, with no additional comments."
)


def parse_srt(path):
    text = open(path, "r", encoding="utf-8-sig").read()
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return []

    cues = []
    for block in re.split(r"\n{2,}", text):
        lines = block.split("\n")
        if len(lines) < 3:
            raise ValueError(f"Malformed SRT block: {block!r}")
        cues.append(
            {
                "index": lines[0],
                "timestamp": lines[1],
                "text": "\n".join(lines[2:]),
            }
        )
    return cues


def request_translations(texts):
    payload = {
        "model": MODEL,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Translate exactly {len(texts)} subtitle cues. "
                    "Return only a valid JSON object with this exact shape: "
                    '{"translations":["translated cue 1","translated cue 2"]}. '
                    "The translations array must contain exactly one translated "
                    "string for each input item, in the same order. "
                    "Do not merge, split, omit, renumber, explain, or wrap the JSON "
                    "in markdown.\n\n"
                    + json.dumps(texts, ensure_ascii=False)
                ),
            },
        ],
    }

    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=600) as response:
        response_body = response.read().decode("utf-8")

    data = json.loads(response_body)
    content = data["choices"][0]["message"]["content"].strip()

    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\s*", "", content)
        content = re.sub(r"\s*```$", "", content).strip()

    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        object_start = content.find("{")
        object_end = content.rfind("}")
        array_start = content.find("[")
        array_end = content.rfind("]")
        if object_start != -1 and object_end > object_start:
            parsed = json.loads(content[object_start : object_end + 1])
        elif array_start != -1 and array_end > array_start:
            parsed = json.loads(content[array_start : array_end + 1])
        else:
            raise

    if isinstance(parsed, dict):
        translations = parsed.get("translations")
    else:
        translations = parsed

    if not isinstance(translations, list) or len(translations) != len(texts):
        raise ValueError(
            f"Expected {len(texts)} translations, got "
            f"{len(translations) if isinstance(translations, list) else type(translations).__name__}"
        )

    return [str(item).strip() for item in translations]


def translate_with_retries(texts, first_cue_number):
    last_error = None
    for attempt in range(1, 4):
        try:
            return request_translations(texts)
        except (json.JSONDecodeError, KeyError, urllib.error.URLError, TimeoutError, ValueError) as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(attempt * 2)

    if len(texts) > 1:
        print(
            f"  Batch starting at cue {first_cue_number} failed; retrying one cue at a time",
            flush=True,
        )
        translations = []
        for offset, text in enumerate(texts):
            translations.extend(translate_with_retries([text], first_cue_number + offset))
        return translations

    raise RuntimeError(
        f"Translation failed for cue {first_cue_number} after 3 attempts: {last_error}"
    ) from last_error


def write_srt(path, cues_to_write):
    with open(path, "w", encoding="utf-8") as output:
        for cue in cues_to_write:
            output.write(f"{cue['index']}\n")
            output.write(f"{cue['timestamp']}\n")
            output.write(f"{cue['text']}\n\n")


cues = parse_srt(INPUT_SRT)
translated_cues = []

for start in range(0, len(cues), BATCH_SIZE):
    batch = cues[start : start + BATCH_SIZE]
    texts = [cue["text"] for cue in batch]
    print(f"  Translating cues {start + 1}-{start + len(batch)} of {len(cues)}", flush=True)
    translations = translate_with_retries(texts, start + 1)
    for cue, translated_text in zip(batch, translations):
        translated_cues.append(
            {
                "index": cue["index"],
                "timestamp": cue["timestamp"],
                "text": translated_text,
            }
        )
    write_srt(PARTIAL_OUTPUT_SRT, translated_cues)

os.replace(PARTIAL_OUTPUT_SRT, OUTPUT_SRT)
PY
}

brazilian_subtitle_file() {
  local source_srt="$1"
  print -r -- "${source_srt:r}.${brazilian_srt_suffix}.srt"
}

generated_subtitle_file() {
  local media_file="$1"

  if [[ "$translate" == true ]]; then
    print -r -- "${media_file:r}.${brazilian_srt_suffix}.srt"
  else
    print -r -- "${media_file:r}.${english_srt_suffix}.srt"
  fi
}

existing_subtitle_for_media() {
  local media_file="$1"
  local media_base="${media_file:r}"
  typeset -a existing_subtitles

  existing_subtitles=("${media_base}".srt(N.) "${media_base}".*.srt(N.))

  if (( ${#existing_subtitles[@]} > 0 )); then
    print -r -- "$existing_subtitles[1]"
    return 0
  fi

  return 1
}

translate_existing_srt_files() {
  typeset -a source_srt_files
  typeset -a pending_srt_files
  typeset -a pending_brazilian_srt_files

  if [[ "$recursive" == true ]]; then
    source_srt_files=("$target_dir"/**/*.srt(N.))
  else
    source_srt_files=("$target_dir"/*.srt(N.))
  fi

  if (( ${#source_srt_files[@]} == 0 )); then
    print "No SRT files found in: $target_dir"
    exit 0
  fi

  for source_srt in "${source_srt_files[@]}"; do
    if [[ "${source_srt:r:e}" == "$brazilian_srt_suffix" ]]; then
      print "Skipping translated subtitle source: $source_srt"
      continue
    fi

    brazilian_srt="$(brazilian_subtitle_file "$source_srt")"

    if [[ -f "$brazilian_srt" && "$replace" != true ]]; then
      print "Skipping existing Brazilian subtitle: $brazilian_srt"
      continue
    fi

    pending_srt_files+=("$source_srt")
    pending_brazilian_srt_files+=("$brazilian_srt")
  done

  if (( ${#pending_srt_files[@]} == 0 )); then
    print "No SRT files need Brazilian Portuguese translation."
    exit 0
  fi

  for index in {1..${#pending_srt_files[@]}}; do
    print ""
    print "Translating existing SRT ($index/${#pending_srt_files[@]}): $pending_srt_files[$index]"
    translate_srt "$pending_srt_files[$index]" "$pending_brazilian_srt_files[$index]"
    print "Wrote: $pending_brazilian_srt_files[$index]"
  done

  print ""
  print "Done."
}

find_pending_mkv_files() {
  typeset -a media_files

  if [[ "$recursive" == true ]]; then
    media_files=("$target_dir"/**/*.(mkv|MKV)(N.))
  else
    media_files=("$target_dir"/*.(mkv|MKV)(N.))
  fi

  if (( ${#media_files[@]} == 0 )); then
    print "No MKV files found in: $target_dir"
    exit 0
  fi

  pending_media_files=()
  pending_subtitle_files=()

  for media_file in "${media_files[@]}"; do
    subtitle_file="$(generated_subtitle_file "$media_file")"

    if [[ "$replace" != true ]] && existing_subtitle="$(existing_subtitle_for_media "$media_file")"; then
      print "Skipping existing subtitle for $media_file: $existing_subtitle"
      continue
    fi

    pending_media_files+=("$media_file")
    pending_subtitle_files+=("$subtitle_file")
  done

  if (( ${#pending_media_files[@]} == 0 )); then
    print "No MKV files need subtitles."
    exit 0
  fi
}

local_media_path() {
  local index="$1"
  local source="$2"
  print -r -- "$media_tmp_dir/${index}-${source:t}"
}

copy_media() {
  local index="$1"
  local source="$2"
  local destination="$3"

  print "Copying locally ($index/${#pending_media_files[@]}): $source"
  cp -p "$source" "$destination"
  print "Copied locally: $destination"
}

process_media() {
  local index="$1"
  local source="$2"
  local local_media="$3"
  local subtitle_file="$4"
  local work_dir="$tmp_dir/work-$index"
  local audio_file="$work_dir/audio.wav"
  local output_prefix="$work_dir/output"
  local english_srt="$output_prefix.srt"
  local translated_srt="$work_dir/translated.srt"

  mkdir -p "$work_dir"

  print ""
  print "Processing ($index/${#pending_media_files[@]}): $source"

  ffmpeg -y \
    -i "$local_media" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le \
    "$audio_file"

  whisper-cli \
    -m "$whisper_model" \
    -f "$audio_file" \
    -l en \
    -osrt \
    -of "$output_prefix" \
    -mc 0 \
    --vad \
    -vm "$vad_model" \
    -vt 0.55 \
    -vsd 250 \
    -vp 50 \
    -ml 42 \
    -sow \
    -sns

  if [[ ! -f "$english_srt" ]]; then
    print -u2 "whisper-cli finished but did not create: $english_srt"
    exit 1
  fi

  if [[ "$translate" == true ]]; then
    translate_srt "$english_srt" "$translated_srt"
    mv -f "$translated_srt" "$subtitle_file"
  else
    mv -f "$english_srt" "$subtitle_file"
  fi

  rm -f "$local_media"
  rm -rf "$work_dir"
  print "Wrote: $subtitle_file"
}

if [[ "$translate_existing_srts" == true ]]; then
  translate_existing_srt_files
  exit 0
fi

typeset -a pending_media_files
typeset -a pending_subtitle_files
find_pending_mkv_files

media_tmp_dir="$tmp_dir/media"
mkdir -p "$media_tmp_dir"

first_local_media="$(local_media_path 1 "$pending_media_files[1]")"
copy_media 1 "$pending_media_files[1]" "$first_local_media"

current_local_media="$first_local_media"
next_copy_pid=0

for index in {1..${#pending_media_files[@]}}; do
  next_index=$(( index + 1 ))

  if (( next_index <= ${#pending_media_files[@]} )); then
    next_local_media="$(local_media_path "$next_index" "$pending_media_files[$next_index]")"
    copy_media "$next_index" "$pending_media_files[$next_index]" "$next_local_media" &
    next_copy_pid=$!
  else
    next_local_media=""
    next_copy_pid=0
  fi

  process_media \
    "$index" \
    "$pending_media_files[$index]" \
    "$current_local_media" \
    "$pending_subtitle_files[$index]"

  if (( next_copy_pid != 0 )); then
    wait "$next_copy_pid"
    current_local_media="$next_local_media"
  fi
done

print ""
print "Done."
