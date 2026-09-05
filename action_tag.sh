#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="${OUTPUT_ROOT:-./tagged_by_user}"
TDL_BIN="${TDL_BIN:-tdl}"
STORAGE_FORUM_CHAT="${STORAGE_FORUM_CHAT:-${TDL_STORAGE_CHAT:--1003574423862}}"
UPLOAD_HASHTAG="${UPLOAD_HASHTAG:-}"

UPLOAD_AFTER_TAGGING=1
APPLY_DCT_WATERMARK=1
TEST_MODE=0

JOB_ID="${JOB_ID:-}"
WORKER_ID="${WORKER_ID:-}"
SERVER_URL="${SERVER_URL:-}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

PARALLEL_LOG_DIR="${PARALLEL_LOG_DIR:-./parallel_logs}"

VIDEO_EXTS=(mkv mp4 mov avi webm m4v ts m2ts)

declare -a TARGET_UIDS=()
declare -A TARGET_TOPICS=()

declare -a INPUTS=()
declare -a VIDEO_FILES=()
declare -A SEEN_VIDEO_FILES=()

declare -a JOB_SRCS=()
declare -a JOB_UIDS=()
declare -a JOB_NUMBERS=()

UPLOAD_ENABLED=1

RUNTIME_ROOT=""
UPLOAD_QUEUE_ROOT=""
UPLOAD_RESULT_DIR=""
UPLOAD_WORKER_PID=""
DCT_SCRIPT=""

VIDEO_COUNT=0
USER_COUNT=0
INTERNAL_JOB_COUNT=0
TOTAL_PROCESS_JOBS=0

completed_count=0
failed_count=0


# ============================================================
# Logging
# ============================================================

action_tag_die() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[+] %s\n' "$*"
}

ok() {
    printf '[✓] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

err() {
    action_tag_die "$*"
}


# ============================================================
# Usage
# ============================================================

usage() {
    cat <<'EOF'
Usage:
  action_tag.sh -i ID[:TOPIC][,ID[:TOPIC]...] [options] INPUT...

Options:
  -o, --output DIR
      Output directory.

  -i, --id IDS
      Telegram user IDs.
      Can optionally include topic:
      ID:TOPIC,ID:TOPIC

  --storage-chat ID
      Telegram storage/forum chat.

  --hashtag TAG
      Hashtag to append to caption.

  --no-upload
      Disable upload.

  --no-dct
      Disable DCT watermark.

  --test
      Test mode.
      Only the FIRST UID will be processed.
      Other supplied UIDs will be ignored.

  -h, --help
      Show this help.

Examples:

  action_tag.sh \
      -i 123456789:42 \
      -o ./tagged_by_user \
      ./videos

  action_tag.sh \
      -i 123456789,987654321 \
      --hashtag test \
      ./video.mp4

  action_tag.sh \
      -i 123456789,987654321 \
      --test \
      ./video.mp4
EOF
}


# ============================================================
# Parse IDs
# ============================================================

parse_ids() {

    local raw="$1"

    local item
    local uid
    local topic

    local -a parts=()


    IFS=',' read -r -a parts <<< "$raw"


    for item in "${parts[@]}"; do

        [[ -n "$item" ]] || continue


        if [[ "$item" == *:* ]]; then

            uid="${item%%:*}"
            topic="${item#*:}"

        else

            uid="$item"
            topic=""

        fi


        [[ "$uid" =~ ^[0-9]+$ ]] \
            || err "Invalid user ID: $uid"


        TARGET_UIDS+=("$uid")
        TARGET_TOPICS["$uid"]="$topic"

    done

}


# ============================================================
# Arguments
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        -o|--output)

            [[ $# -ge 2 ]] \
                || err "Missing value for $1"

            OUTPUT_ROOT="$2"

            shift 2
            ;;


        -i|--id)

            [[ $# -ge 2 ]] \
                || err "Missing value for $1"

            parse_ids "$2"

            shift 2
            ;;


        --storage-chat)

            [[ $# -ge 2 ]] \
                || err "Missing value for $1"

            STORAGE_FORUM_CHAT="$2"

            shift 2
            ;;


        --hashtag)

            [[ $# -ge 2 ]] \
                || err "Missing value for $1"

            UPLOAD_HASHTAG="$2"

            shift 2
            ;;


        --no-upload)

            UPLOAD_ENABLED=0
            UPLOAD_AFTER_TAGGING=0

            shift
            ;;


        --no-dct)

            APPLY_DCT_WATERMARK=0

            shift
            ;;


        --test)

            TEST_MODE=1

            shift
            ;;


        -h|--help)

            usage

            exit 0
            ;;


        --)

            shift

            while [[ $# -gt 0 ]]; do

                INPUTS+=("$1")

                shift

            done

            ;;


        *)

            INPUTS+=("$1")

            shift

            ;;

    esac

done


# ============================================================
# Validation
# ============================================================

[[ ${#TARGET_UIDS[@]} -gt 0 ]] \
    || err "At least one user ID is required (-i)."

[[ ${#INPUTS[@]} -gt 0 ]] \
    || err "At least one input file/directory is required."


# ============================================================
# TEST MODE
#
# NORMAL:
#   Process ALL supplied UIDs.
#
# TEST:
#   Process ONLY the first UID.
# ============================================================

if [[ "$TEST_MODE" -eq 1 ]]; then

    if [[ "${#TARGET_UIDS[@]}" -gt 1 ]]; then

        warn \
            "TEST MODE: ${#TARGET_UIDS[@]} UIDs supplied; " \
            "only the first UID will be processed."

    fi


    TEST_UID="${TARGET_UIDS[0]}"
    TEST_TOPIC="${TARGET_TOPICS[$TEST_UID]:-}"


    TARGET_UIDS=(
        "$TEST_UID"
    )


    unset TARGET_TOPICS

    declare -A TARGET_TOPICS=()


    if [[ -n "$TEST_TOPIC" ]]; then

        TARGET_TOPICS["$TEST_UID"]="$TEST_TOPIC"

    fi

fi


# ============================================================
# Upload validation
# ============================================================

if [[ "$UPLOAD_ENABLED" -eq 1 ]]; then

    [[ -n "$SERVER_URL" ]] \
        || err "SERVER_URL is required when upload is enabled."

    [[ -n "$AUTH_TOKEN" ]] \
        || err "AUTH_TOKEN is required when upload is enabled."

    [[ -n "$JOB_ID" ]] \
        || err "JOB_ID is required when upload is enabled."

    [[ -n "$WORKER_ID" ]] \
        || err "WORKER_ID is required when upload is enabled."

fi


# ============================================================
# Hashtag normalization
# ============================================================

UPLOAD_HASHTAG="${UPLOAD_HASHTAG// /_}"


if [[ -n "$UPLOAD_HASHTAG" &&
      "$UPLOAD_HASHTAG" != \#* ]]; then

    UPLOAD_HASHTAG="#${UPLOAD_HASHTAG}"

fi


# ============================================================
# Required commands
# ============================================================

require_cmd() {

    command -v "$1" >/dev/null 2>&1 \
        || err "Required command not found: $1"

}


for cmd in \
    ffmpeg \
    ffprobe \
    python3 \
    timeout \
    jq \
    sha256sum \
    find \
    sort \
    mktemp
do

    require_cmd "$cmd"

done


if [[ "$UPLOAD_ENABLED" -eq 1 ]]; then

    require_cmd curl
    require_cmd "$TDL_BIN"

fi


# ============================================================
# DCT dependency
# ============================================================

HAS_DCT_WATERMARK=0


if [[ "$APPLY_DCT_WATERMARK" -eq 1 ]]; then

    if python3 -c 'import cv2, imwatermark' \
        >/dev/null 2>&1
    then

        HAS_DCT_WATERMARK=1

    else

        warn \
            "DCT dependencies missing; DCT will be skipped."

    fi

fi


# ============================================================
# Check libx264
# ============================================================

if ! ffmpeg \
    -hide_banner \
    -h encoder=libx264 \
    >/dev/null 2>&1
then

    err "FFmpeg does not provide libx264."

fi


# ============================================================
# Directories
# ============================================================

mkdir -p "$OUTPUT_ROOT"
mkdir -p "$PARALLEL_LOG_DIR"


# ============================================================
# Runtime
# ============================================================

RUNTIME_ROOT="$(
    mktemp -d \
        "/tmp/action_tag_${WORKER_ID:-unknown}_XXXXXX"
)"

UPLOAD_QUEUE_ROOT="$RUNTIME_ROOT/upload_queue"
UPLOAD_RESULT_DIR="$RUNTIME_ROOT/results"

mkdir -p "$UPLOAD_QUEUE_ROOT"
mkdir -p "$UPLOAD_RESULT_DIR"


# ============================================================
# Cleanup
# ============================================================

cleanup() {

    local rc=$?


    if [[ -n "${UPLOAD_WORKER_PID:-}" ]]; then

        if kill -0 "$UPLOAD_WORKER_PID" \
            >/dev/null 2>&1
        then

            kill "$UPLOAD_WORKER_PID" \
                >/dev/null 2>&1 \
                || true

            wait "$UPLOAD_WORKER_PID" \
                >/dev/null 2>&1 \
                || true

        fi

    fi


    if [[ -n "${RUNTIME_ROOT:-}" &&
          -d "$RUNTIME_ROOT" ]]; then

        rm -rf "$RUNTIME_ROOT"

    fi


    return "$rc"
}


trap cleanup EXIT INT TERM


# ============================================================
# Path helpers
# ============================================================

normalize_path() {

    local p="$1"


    if [[ -d "$p" ]]; then

        (
            cd "$p"
            pwd -P
        )

    else

        local d
        local b

        d="$(dirname "$p")"
        b="$(basename "$p")"

        (
            cd "$d"

            printf '%s/%s\n' \
                "$(pwd -P)" \
                "$b"
        )

    fi

}


is_video_file() {

    local p="$1"
    local ext

    ext="${p##*.}"
    ext="${ext,,}"


    local x

    for x in "${VIDEO_EXTS[@]}"; do

        if [[ "$ext" == "$x" ]]; then

            return 0

        fi

    done


    return 1

}


add_video() {

    local p="$1"
    local real


    [[ -f "$p" ]] \
        || return 0


    is_video_file "$p" \
        || return 0


    real="$(normalize_path "$p")"


    [[ -n "${SEEN_VIDEO_FILES[$real]+x}" ]] \
        && return 0


    SEEN_VIDEO_FILES["$real"]=1

    VIDEO_FILES+=("$real")

}


collect_input() {

    local input="$1"


    if [[ -d "$input" ]]; then

        while IFS= read -r -d '' f; do

            add_video "$f"

        done < <(

            find "$input" \
                -type f \
                -print0 |
            sort -z

        )


    elif [[ -f "$input" ]]; then

        add_video "$input"


    else

        warn "Input not found: $input"

    fi

}


for input in "${INPUTS[@]}"; do

    collect_input "$input"

done


VIDEO_COUNT=${#VIDEO_FILES[@]}
USER_COUNT=${#TARGET_UIDS[@]}


# ============================================================
# Internal job count
#
# NORMAL:
#   VIDEO_COUNT x USER_COUNT
#
# TEST:
#   TARGET_UIDS has already been reduced to ONE UID.
#
# Therefore:
#
#   normal: 3 videos x 3 users = 9 jobs
#   test:   3 videos x 1 user   = 3 jobs
# ============================================================

INTERNAL_JOB_COUNT=$(
    ((VIDEO_COUNT * USER_COUNT))
)

TOTAL_PROCESS_JOBS="$INTERNAL_JOB_COUNT"


[[ "$VIDEO_COUNT" -gt 0 ]] \
    || err "No video files found."


# ============================================================
# Telegram storage
# ============================================================

TDL_STORAGE_CHAT="${STORAGE_FORUM_CHAT#-100}"

export TDL_STORAGE_CHAT


# ============================================================
# DCT Python script
#
# OpenCV:
#   decode frames
#   apply watermark
#
# FFmpeg:
#   ONLY video encode
#
# Video:
#   libx264
#   CRF 27
#   preset fast
#
# Audio:
#   AAC 192k
#
# Original audio:
#   source video
# ============================================================

if [[ "$HAS_DCT_WATERMARK" -eq 1 ]]; then

    DCT_SCRIPT="$RUNTIME_ROOT/dct_watermark.py"


    cat > "$DCT_SCRIPT" <<'PY'
import sys
import subprocess

import cv2
import numpy as np

from imwatermark import WatermarkEncoder


def main():

    if len(sys.argv) != 4:

        print(
            "Usage: dct_watermark.py INPUT OUTPUT UID",
            file=sys.stderr
        )

        return 2


    input_path = sys.argv[1]
    output_path = sys.argv[2]
    uid = int(sys.argv[3])


    # --------------------------------------------------------
    # Open input video
    # --------------------------------------------------------

    cap = cv2.VideoCapture(input_path)


    if not cap.isOpened():

        print(
            f"ERROR: Cannot open video: {input_path}",
            file=sys.stderr
        )

        return 1


    fps = cap.get(cv2.CAP_PROP_FPS)


    if not fps or fps <= 0:

        fps = 25.0


    width = int(
        cap.get(cv2.CAP_PROP_FRAME_WIDTH)
    )


    height = int(
        cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    )


    total_frames = int(
        cap.get(cv2.CAP_PROP_FRAME_COUNT)
    )


    if width <= 0 or height <= 0:

        print(
            "ERROR: Invalid video dimensions",
            file=sys.stderr
        )

        cap.release()

        return 1


    # --------------------------------------------------------
    # yuv420p requires even dimensions
    # --------------------------------------------------------

    if width % 2 != 0 or height % 2 != 0:

        print(
            f"ERROR: Odd video dimensions are not supported: "
            f"{width}x{height}",
            file=sys.stderr
        )

        cap.release()

        return 1


    print(
        f"DCT INPUT: "
        f"{width}x{height} @ {fps:.3f} FPS | "
        f"Frames: {total_frames}",
        flush=True
    )


    # --------------------------------------------------------
    # Watermark
    # --------------------------------------------------------

    encoder = WatermarkEncoder()


    data = uid.to_bytes(
        8,
        byteorder="big",
        signed=False
    )


    encode_method = None


    try:

        encoder.set_watermark(
            "bytes",
            data
        )

        encode_method = "dwtDct"


    except TypeError:

        encoder.set_watermark(
            data,
            model="DWT_DCT"
        )


    # --------------------------------------------------------
    # FFmpeg
    #
    # ONLY ONE VIDEO ENCODE
    # --------------------------------------------------------

    ffmpeg_cmd = [

        "ffmpeg",

        "-hide_banner",
        "-loglevel", "error",
        "-y",

        # Processed video
        "-f", "rawvideo",
        "-pix_fmt", "bgr24",
        "-s", f"{width}x{height}",
        "-r", f"{fps:.6f}",

        "-i", "pipe:0",

        # Original source
        "-i", input_path,

        # Video + original audio
        "-map", "0:v:0",
        "-map", "1:a:0?",

        # ONE video encode
        "-c:v", "libx264",
        "-preset", "fast",
        "-crf", "27",

        "-pix_fmt", "yuv420p",

        # Audio
        "-c:a", "aac",
        "-b:a", "192k",

        # Metadata
        "-map_metadata", "1",

        # MP4 fast start
        "-movflags", "+faststart",

        output_path,
    ]


    print(
        "Starting FFmpeg: "
        "libx264 CRF 27 preset fast "
        "+ AAC 192k",
        flush=True
    )


    process = subprocess.Popen(

        ffmpeg_cmd,

        stdin=subprocess.PIPE,

        stderr=subprocess.PIPE,

    )


    frame_number = 0


    try:

        while True:

            ok, frame = cap.read()


            if not ok:

                break


            # ------------------------------------------------
            # Apply DCT every 30th frame
            # ------------------------------------------------

            if frame_number % 30 == 0:

                if encode_method:

                    frame = encoder.encode(
                        frame,
                        encode_method
                    )

                else:

                    frame = encoder.encode(frame)


            # ------------------------------------------------
            # Ensure contiguous BGR24
            # ------------------------------------------------

            frame = np.ascontiguousarray(frame)


            process.stdin.write(
                frame.tobytes()
            )


            frame_number += 1


            if frame_number % 200 == 0:

                if total_frames > 0:

                    percent = (
                        frame_number *
                        100.0 /
                        total_frames
                    )


                    print(
                        f"DCT Progress: "
                        f"{frame_number}/"
                        f"{total_frames} "
                        f"({percent:.1f}%)",
                        flush=True
                    )

                else:

                    print(
                        f"DCT Progress: "
                        f"{frame_number} frames",
                        flush=True
                    )


        # ----------------------------------------------------
        # Finish FFmpeg input
        # ----------------------------------------------------

        process.stdin.close()


        stderr_output = (
            process.stderr
            .read()
            .decode(
                "utf-8",
                errors="replace"
            )
        )


        return_code = process.wait()


        if return_code != 0:

            print(
                "FFmpeg ERROR:",
                file=sys.stderr
            )

            print(
                stderr_output,
                file=sys.stderr
            )

            return return_code


    except BrokenPipeError:

        try:

            process.kill()

        except Exception:

            pass


        process.wait()


        stderr_output = (
            process.stderr
            .read()
            .decode(
                "utf-8",
                errors="replace"
            )
        )


        print(
            "ERROR: FFmpeg pipe closed unexpectedly",
            file=sys.stderr
        )


        print(
            stderr_output,
            file=sys.stderr
        )


        return 1


    except Exception as exc:

        try:

            process.kill()

        except Exception:

            pass


        process.wait()


        print(
            f"ERROR while processing video: {exc}",
            file=sys.stderr
        )


        return 1


    finally:

        cap.release()


    print(
        f"DCT COMPLETE: {frame_number} frames",
        flush=True
    )


    return 0


if __name__ == "__main__":

    sys.exit(main())
PY


    chmod +x "$DCT_SCRIPT"

fi


# ============================================================
# Build internal jobs
#
# NORMAL:
#   Every video x every UID
#
# TEST:
#   TARGET_UIDS contains only the first UID.
# ============================================================

build_jobs() {

    local src
    local uid
    local job_num=0


    JOB_SRCS=()
    JOB_UIDS=()
    JOB_NUMBERS=()


    for src in "${VIDEO_FILES[@]}"; do

        for uid in "${TARGET_UIDS[@]}"; do

            job_num=$((job_num + 1))


            JOB_SRCS+=(
                "$src"
            )


            JOB_UIDS+=(
                "$uid"
            )


            JOB_NUMBERS+=(
                "$job_num"
            )

        done

    done

}


build_jobs


# ============================================================
# Upload API helper
#
# file_server.py authenticates with:
#
#   ?token=...
#
# NOT:
#
#   Authorization: Bearer ...
# ============================================================

upload_api() {

    local method="$1"
    local url="$2"
    local data="${3:-}"

    local response=""
    local http_code=""
    local body=""

    local token_encoded
    local auth_url


    token_encoded="$(
        printf '%s' "$AUTH_TOKEN" |
        jq -sRr @uri
    )"


    if [[ "$url" == *"?"* ]]; then

        auth_url="${url}&token=${token_encoded}"

    else

        auth_url="${url}?token=${token_encoded}"

    fi


    # --------------------------------------------------------
    # GET
    # --------------------------------------------------------

    if [[ "$method" == "GET" ]]; then

        response="$(
            curl -sS \
                --fail-with-body \
                --max-time 30 \
                -w $'\n%{http_code}' \
                "$auth_url"
        )" || {

            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"


            warn \
                "Upload API HTTP " \
                "${http_code:-unknown}: " \
                "${body:-request failed}"


            return 1

        }


    # --------------------------------------------------------
    # POST
    # --------------------------------------------------------

    else

        response="$(
            curl -sS \
                --fail-with-body \
                --max-time 30 \
                -X "$method" \
                -H "Content-Type: application/json" \
                -d "$data" \
                -w $'\n%{http_code}' \
                "$auth_url"
        )" || {

            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"


            warn \
                "Upload API HTTP " \
                "${http_code:-unknown}: " \
                "${body:-request failed}"


            return 1

        }

    fi


    # --------------------------------------------------------
    # Parse response
    # --------------------------------------------------------

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"


    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then

        warn \
            "Upload API HTTP $http_code: $body"

        return 1

    fi


    printf '%s\n' "$body"

}


# ============================================================
# Enqueue upload
# ============================================================

enqueue_upload_job() {

    local upload_id="$1"
    local job_num="$2"

    local payload
    local response
    local status


    payload="$(
        jq -cn \
            --arg upload_id "$upload_id" \
            --arg worker_id "$WORKER_ID" \
            --arg job_id "$JOB_ID" \
            --arg job_num "$job_num" \
            '{
                upload_id: $upload_id,
                worker_id: $worker_id,
                job_id: $job_id,
                job_num: $job_num
            }'
    )"


    response="$(
        upload_api \
            POST \
            "$SERVER_URL/upload/enqueue" \
            "$payload"
    )" || return 1


    status="$(
        jq -r '.status // empty' <<< "$response"
    )"


    case "$status" in

        waiting|active|success|failed|queued)

            return 0
            ;;


        *)

            warn \
                "Unexpected enqueue response: $response"

            return 1

            ;;

    esac

}


# ============================================================
# Check upload status
# ============================================================

check_upload_status() {

    local upload_id="$1"

    local encoded_id
    local response


    encoded_id="$(
        printf '%s' "$upload_id" |
        jq -sRr @uri
    )"


    response="$(
        upload_api \
            GET \
            "$SERVER_URL/upload/status?upload_id=$encoded_id"
    )" || return 1


    UPLOAD_STATUS="$(
        jq -r '.status // empty' <<< "$response"
    )"


    UPLOAD_LEASE_TOKEN="$(
        jq -r '.lease_token // empty' <<< "$response"
    )"


    UPLOAD_POSITION="$(
        jq -r '.position // 0' <<< "$response"
    )"


    UPLOAD_ACCOUNT_ID="$(
        jq -r '.account_id // empty' <<< "$response"
    )"


    return 0

}


# ============================================================
# Complete upload
# ============================================================

complete_upload_job() {

    local upload_id="$1"
    local lease_token="$2"
    local result="$3"

    local payload


    payload="$(
        jq -cn \
            --arg upload_id "$upload_id" \
            --arg lease_token "$lease_token" \
            --arg result "$result" \
            '{
                upload_id: $upload_id,
                lease_token: $lease_token,
                result: $result
            }'
    )"


    upload_api \
        POST \
        "$SERVER_URL/upload/complete" \
        "$payload" \
        >/dev/null

}


# ============================================================
# TDL upload
#
# Exactly ONE TDL upload process.
# ============================================================

upload_one() {

    local current_file="$1"
    local topic_id="$2"

    local caption_template="FileName"


    if [[ -n "$UPLOAD_HASHTAG" ]]; then

        caption_template="FileName + \" $UPLOAD_HASHTAG\""

    fi


    local -a cmd=(
        "$TDL_BIN"
    )


    if [[ -n "${TDL_STORAGE:-}" ]]; then

        cmd+=(
            --storage
            "$TDL_STORAGE"
        )

    fi


    if [[ -n "${TDL_NS:-}" ]]; then

        cmd+=(
            --ns
            "$TDL_NS"
        )

    fi


    cmd+=(
        up
        -l 1
        -p "$current_file"
        -c "$TDL_STORAGE_CHAT"
        --caption "$caption_template"
    )


    if [[ -n "$topic_id" ]]; then

        cmd+=(
            --topic
            "$topic_id"
        )

    fi


    log \
        "TDL upload: ${current_file##*/}"


    timeout 600 "${cmd[@]}"

}


# ============================================================
# Upload worker
#
# Only ONE local TDL upload process at a time.
#
# Central server controls:
#   account mutex
#   queue order
#   lease
#   stale lease recovery
# ============================================================

upload_worker() {

    local producer_done_file="$RUNTIME_ROOT/producer.done"

    local ready_file=""
    local current_file=""
    local upload_id=""
    local topic_id=""
    local job_num=""

    local status=""
    local lease_token=""

    local result_file=""


    while true; do

        ready_file=""


        # ----------------------------------------------------
        # Find next ready upload
        # ----------------------------------------------------

        while IFS= read -r -d '' f; do

            ready_file="$f"

            break

        done < <(

            find "$UPLOAD_QUEUE_ROOT" \
                -maxdepth 1 \
                -type f \
                -name '*.ready' \
                -print0 |
            sort -z

        )


        # ----------------------------------------------------
        # Nothing ready
        # ----------------------------------------------------

        if [[ -z "$ready_file" ]]; then

            if [[ -f "$producer_done_file" ]]; then

                break

            fi


            sleep 0.5

            continue

        fi


        # ----------------------------------------------------
        # Read job
        # ----------------------------------------------------

        upload_id="$(
            jq -r '.upload_id' "$ready_file"
        )"


        current_file="$(
            jq -r '.file' "$ready_file"
        )"


        topic_id="$(
            jq -r '.topic_id // empty' "$ready_file"
        )"


        job_num="$(
            jq -r '.job_num' "$ready_file"
        )"


        # ----------------------------------------------------
        # Enqueue centrally
        # ----------------------------------------------------

        if ! enqueue_upload_job \
            "$upload_id" \
            "$job_num"
        then

            warn \
                "Could not enqueue upload $upload_id"

            sleep 2

            continue

        fi


        # ----------------------------------------------------
        # Wait for central lease
        # ----------------------------------------------------

        while true; do

            if ! check_upload_status "$upload_id"; then

                sleep 2

                continue

            fi


            status="$UPLOAD_STATUS"
            lease_token="$UPLOAD_LEASE_TOKEN"


            case "$status" in

                # ------------------------------------------------
                # Already completed
                # ------------------------------------------------

                success)

                    rm -f "$ready_file"

                    rm -f "${current_file}.dct.mp4"


                    result_file="$UPLOAD_RESULT_DIR/$upload_id.result"


                    printf 'success\n' \
                        > "$result_file"


                    break

                    ;;


                # ------------------------------------------------
                # Failed
                # ------------------------------------------------

                failed)

                    result_file="$UPLOAD_RESULT_DIR/$upload_id.result"


                    printf 'failed\n' \
                        > "$result_file"


                    break

                    ;;


                # ------------------------------------------------
                # We have the lease
                # ------------------------------------------------

                active)

                    if [[ -z "$lease_token" ]]; then

                        sleep 1

                        continue

                    fi


                    # ------------------------------------------------
                    # ONLY HERE TDL is executed.
                    # ------------------------------------------------

                    if upload_one \
                        "$current_file" \
                        "$topic_id"
                    then

                        if complete_upload_job \
                            "$upload_id" \
                            "$lease_token" \
                            success
                        then

                            rm -f "$ready_file"

                            rm -f "${current_file}.dct.mp4"


                            printf 'success\n' \
                                > "$UPLOAD_RESULT_DIR/$upload_id.result"

                        else

                            warn \
                                "Upload succeeded but completion API failed: " \
                                "$upload_id"


                            printf 'failed\n' \
                                > "$UPLOAD_RESULT_DIR/$upload_id.result"

                        fi


                    else

                        warn \
                            "TDL upload failed: $upload_id"


                        complete_upload_job \
                            "$upload_id" \
                            "$lease_token" \
                            failed \
                            || true


                        printf 'failed\n' \
                            > "$UPLOAD_RESULT_DIR/$upload_id.result"

                    fi


                    break

                    ;;


                # ------------------------------------------------
                # Waiting for central account mutex
                # ------------------------------------------------

                waiting|queued)

                    sleep 1

                    ;;


                # ------------------------------------------------
                # Unknown state
                # ------------------------------------------------

                *)

                    warn \
                        "Unknown upload status '$status' " \
                        "for $upload_id"

                    sleep 2

                    ;;

            esac

        done

    done

}


# ============================================================
# Process one video for one user
# ============================================================

process_user_video() {

    local src="$1"
    local uid="$2"
    local job_num="$3"

    local user_dir

    local base
    local stem
    local ext

    local dst
    local tmp_dct
    local current_file

    local topic_id

    local start_time
    local end_time

    local duration
    local minutes
    local seconds

    local upload_id
    local queue_file


    user_dir="$OUTPUT_ROOT/$uid"

    mkdir -p "$user_dir"


    base="$(basename "$src")"

    stem="${base%.*}"

    ext="${base##*.}"
    ext="${ext,,}"


    if [[ "$ext" == "$base" ]]; then

        ext="mp4"

    fi


    # --------------------------------------------------------
    # Final output is always MP4
    # --------------------------------------------------------

    dst="$user_dir/${stem}.mp4"

    tmp_dct="$dst.dct.mp4"

    current_file="$dst"


    topic_id="${TARGET_TOPICS[$uid]:-}"


    start_time="$(date +%s)"


    log \
        "Internal job $job_num/$TOTAL_PROCESS_JOBS | " \
        "User=$uid | Video=$base"


    # --------------------------------------------------------
    # DCT
    # --------------------------------------------------------

    if [[ "$APPLY_DCT_WATERMARK" -eq 1 &&
          "$HAS_DCT_WATERMARK" -eq 1 ]]; then


        rm -f "$tmp_dct"


        if ! python3 \
            "$DCT_SCRIPT" \
            "$src" \
            "$tmp_dct" \
            "$uid" \
            > "$PARALLEL_LOG_DIR/job_${job_num}.dct.log" \
            2>&1
        then

            warn \
                "DCT failed | " \
                "job=$job_num | " \
                "user=$uid | " \
                "video=$base"

            return 1

        fi


        if [[ ! -s "$tmp_dct" ]]; then

            warn \
                "DCT output is missing/empty | " \
                "job=$job_num"

            return 1

        fi


        mv -f \
            "$tmp_dct" \
            "$current_file"


    else

        # ----------------------------------------------------
        # No DCT
        # ----------------------------------------------------

        cp -f \
            "$src" \
            "$current_file"

    fi


    # --------------------------------------------------------
    # Upload queue
    #
    # DCT finishes -> ready file is created immediately.
    #
    # Upload worker operates independently.
    # --------------------------------------------------------

    if [[ "$UPLOAD_ENABLED" -eq 1 &&
          "$UPLOAD_AFTER_TAGGING" -eq 1 ]]; then


        upload_id="${JOB_ID}_${WORKER_ID}_${job_num}_$(date +%s%N)"


        queue_file="$UPLOAD_QUEUE_ROOT/${upload_id}.ready"


        jq -cn \
            --arg upload_id "$upload_id" \
            --arg file "$current_file" \
            --arg topic_id "$topic_id" \
            --arg job_num "$job_num" \
            '{
                upload_id: $upload_id,
                file: $file,
                topic_id: $topic_id,
                job_num: ($job_num | tonumber)
            }' \
            > "$queue_file"


        ok \
            "DCT ready / upload queued | " \
            "job=$job_num | " \
            "user=$uid | " \
            "file=${current_file##*/}"


    else

        ok \
            "Processing complete | " \
            "job=$job_num | " \
            "user=$uid | " \
            "file=${current_file##*/}"

    fi


    # --------------------------------------------------------
    # Timing
    # --------------------------------------------------------

    end_time="$(date +%s)"

    duration=$((end_time - start_time))

    minutes=$((duration / 60))
    seconds=$((duration % 60))


    log \
        "Internal job finished | " \
        "job=$job_num | " \
        "${minutes}m ${seconds}s"


    return 0

}


# ============================================================
# Start upload worker
# ============================================================

if [[ "$UPLOAD_ENABLED" -eq 1 ]]; then

    upload_worker &

    UPLOAD_WORKER_PID=$!

fi


# ============================================================
# Startup info
# ============================================================

log "Worker: $WORKER_ID"
log "Job: $JOB_ID"
log "Users: $USER_COUNT"
log "Videos: $VIDEO_COUNT"
log "Internal jobs: $TOTAL_PROCESS_JOBS"


if [[ "$TEST_MODE" -eq 1 ]]; then

    log "TEST MODE: enabled"
    log "TEST UID: ${TARGET_UIDS[0]}"

else

    log "TEST MODE: disabled"

fi


if [[ "$APPLY_DCT_WATERMARK" -eq 1 &&
      "$HAS_DCT_WATERMARK" -eq 1 ]]; then

    log "DCT: enabled"

else

    log "DCT: disabled"

fi


log \
    "Video encode: libx264 / CRF 27 / preset fast"


log \
    "Audio encode: AAC / 192k"


if [[ "$UPLOAD_ENABLED" -eq 1 ]]; then

    log "Upload: enabled"

else

    log "Upload: disabled"

fi


# ============================================================
# Producer
#
# DCT jobs continue immediately.
# Upload worker runs independently in background.
# ============================================================

for i in "${!JOB_SRCS[@]}"; do

    if process_user_video \
        "${JOB_SRCS[$i]}" \
        "${JOB_UIDS[$i]}" \
        "${JOB_NUMBERS[$i]}"
    then

        completed_count=$((completed_count + 1))

    else

        failed_count=$((failed_count + 1))

    fi

done


# ============================================================
# Tell upload worker that producer is finished
# ============================================================

if [[ "$UPLOAD_ENABLED" -eq 1 ]]; then

    touch "$RUNTIME_ROOT/producer.done"


    wait "$UPLOAD_WORKER_PID" \
        || true


    UPLOAD_WORKER_PID=""

fi


# ============================================================
# Final
# ============================================================

ok \
    "All processing jobs finished | " \
    "success=$completed_count | " \
    "failed=$failed_count | " \
    "total=$TOTAL_PROCESS_JOBS"


exit 0
