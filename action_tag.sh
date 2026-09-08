#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="${OUTPUT_ROOT:-./tagged_by_user}"
TDL_BIN="${TDL_BIN:-tdl}"
TDL_TIMEOUT="${TDL_TIMEOUT:-600}"
MAX_DCT_JOBS="${MAX_DCT_JOBS:-$(nproc 2>/dev/null || echo 1)}"
STORAGE_FORUM_CHAT="${STORAGE_FORUM_CHAT:-${TDL_STORAGE_CHAT:--1003574423862}}"
UPLOAD_HASHTAG="${UPLOAD_HASHTAG:-}"
UPLOAD_ENABLED=1
UPLOAD_AFTER_TAGGING=1
APPLY_DCT_WATERMARK=1
TEST_MODE=0
JOB_ID="${JOB_ID:-}"
WORKER_ID="${WORKER_ID:-}"
SERVER_URL="${SERVER_URL:-}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
SOURCE_ID="${SOURCE_ID:-}"
REQUEST_ID="${REQUEST_ID:-}"
PARALLEL_LOG_DIR="${PARALLEL_LOG_DIR:-./parallel_logs}"

VIDEO_EXTS=(mkv mp4 mov avi webm m4v ts m2ts)
declare -a TARGET_UIDS=() INPUTS=() VIDEO_FILES=() JOB_SRCS=() JOB_UIDS=() JOB_NUMBERS=()
declare -A TARGET_TOPICS=() SEEN_VIDEO_FILES=()
declare -a DCT_PIDS=() DCT_PID_JOB_NUMBERS=()

RUNTIME_ROOT=""; UPLOAD_QUEUE_ROOT=""; UPLOAD_RESULT_DIR=""; JOB_RESULT_DIR=""
UPLOAD_WORKER_PID=""; DCT_SCRIPT=""
VIDEO_COUNT=0; USER_COUNT=0; TOTAL_PROCESS_JOBS=0; completed_count=0; failed_count=0

log(){ printf '[+] %s\n' "$*"; }
ok(){ printf '[✓] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
err(){ printf '[x] %s\n' "$*" >&2; exit 1; }

usage(){ cat <<'USAGE'
Usage: action_tag.sh -i ID[:TOPIC][,ID[:TOPIC]...] [options] INPUT...
  -o, --output DIR       Output directory
  -i, --id IDS           Telegram user IDs, optionally with topic
  --storage-chat ID      Telegram storage/forum chat
  --hashtag TAG          Hashtag to append to caption
  --no-upload            Disable upload
  --no-dct               Disable DCT
  --test                 Process only the first UID
  -h, --help             Show help
Environment:
  MAX_DCT_JOBS           Maximum simultaneous DCT jobs (default: CPU count)
  TDL_TIMEOUT             Per-upload TDL timeout in seconds (default: 600)
USAGE
}

parse_ids(){
  local raw="$1" item uid topic; local -a parts=()
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    [[ -n "$item" ]] || continue
    if [[ "$item" == *:* ]]; then uid="${item%%:*}"; topic="${item#*:}"; else uid="$item"; topic=""; fi
    [[ "$uid" =~ ^[0-9]+$ ]] || err "Invalid user ID: $uid"
    [[ -z "$topic" || "$topic" =~ ^[0-9]+$ ]] || err "Invalid topic ID for user $uid: $topic"
    TARGET_UIDS+=("$uid"); TARGET_TOPICS["$uid"]="$topic"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || err "Missing value for $1"; OUTPUT_ROOT="$2"; shift 2;;
    -i|--id) [[ $# -ge 2 ]] || err "Missing value for $1"; parse_ids "$2"; shift 2;;
    --storage-chat) [[ $# -ge 2 ]] || err "Missing value for $1"; STORAGE_FORUM_CHAT="$2"; shift 2;;
    --hashtag) [[ $# -ge 2 ]] || err "Missing value for $1"; UPLOAD_HASHTAG="$2"; shift 2;;
    --no-upload) UPLOAD_ENABLED=0; UPLOAD_AFTER_TAGGING=0; shift;;
    --no-dct) APPLY_DCT_WATERMARK=0; shift;;
    --test) TEST_MODE=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; while [[ $# -gt 0 ]]; do INPUTS+=("$1"); shift; done;;
    *) INPUTS+=("$1"); shift;;
  esac
done

[[ ${#TARGET_UIDS[@]} -gt 0 ]] || err "At least one user ID is required (-i)."
[[ ${#INPUTS[@]} -gt 0 ]] || err "At least one input file/directory is required."
[[ "$MAX_DCT_JOBS" =~ ^[1-9][0-9]*$ ]] || err "MAX_DCT_JOBS must be a positive integer."
[[ "$TDL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || err "TDL_TIMEOUT must be a positive integer."

if (( TEST_MODE )); then
  TEST_UID="${TARGET_UIDS[0]}"; TEST_TOPIC="${TARGET_TOPICS[$TEST_UID]:-}"
  TARGET_UIDS=("$TEST_UID"); unset TARGET_TOPICS; declare -A TARGET_TOPICS=()
  [[ -z "$TEST_TOPIC" ]] || TARGET_TOPICS["$TEST_UID"]="$TEST_TOPIC"
fi

if (( UPLOAD_ENABLED )); then
  [[ -n "$SERVER_URL" ]] || err "SERVER_URL is required when upload is enabled."
  [[ -n "$AUTH_TOKEN" ]] || err "AUTH_TOKEN is required when upload is enabled."
  [[ -n "$JOB_ID" ]] || err "JOB_ID is required when upload is enabled."
  [[ -n "$WORKER_ID" ]] || err "WORKER_ID is required when upload is enabled."
fi

report_worker_state(){
  local status="${1:-running}" user="${2:-}" file="${3:-}" stage="${4:-}" progress="${5:-}"
  [[ -n "$SERVER_URL" && -n "$AUTH_TOKEN" && -n "$WORKER_ID" ]] || return 0
  local payload token
  payload="$({
    WORKER_ID="$WORKER_ID" JOB_ID="$JOB_ID" WORKER_USERNAME="${GITHUB_ACTOR:-}" STATUS="$status" RUN_ID="${GITHUB_RUN_ID:-}" \
    CURRENT_USER="$user" CURRENT_FILE="$file" CURRENT_STAGE="$stage" PROGRESS="$progress" SOURCE_ID="$SOURCE_ID" REQUEST_ID="$REQUEST_ID" \
    python3 - <<'PY'
import json,os
p=os.getenv('PROGRESS','').strip()
try: p=max(0.0,min(100.0,float(p))) if p else None
except ValueError: p=None
print(json.dumps({
'worker_id':os.getenv('WORKER_ID',''),'worker_username':os.getenv('WORKER_USERNAME',''),
'status':os.getenv('STATUS','running'),'job_id':os.getenv('JOB_ID') or None,
'run_id':os.getenv('RUN_ID') or None,'current_user':os.getenv('CURRENT_USER') or None,
'current_file':os.getenv('CURRENT_FILE') or None,'current_stage':os.getenv('CURRENT_STAGE') or None,
'progress':p,'source_id':os.getenv('SOURCE_ID') or None,'request_id':os.getenv('REQUEST_ID') or None},ensure_ascii=False))
PY
  })" || return 0
  token="$(printf '%s' "$AUTH_TOKEN" | jq -sRr @uri)" || return 0
  curl -sS --max-time 5 -X POST "${SERVER_URL%/}/worker?token=${token}" -H 'Content-Type: application/json' --data-binary "$payload" >/dev/null 2>&1 || true
}
report_dct_start(){ report_worker_state running "$1" "$2" DCT 0; }
report_dct_progress(){ report_worker_state running "$1" "$2" DCT "$3"; }
report_upload_start(){ report_worker_state running "$1" "$2" UPLOAD 0; }
report_upload_progress(){ report_worker_state running "$1" "$2" UPLOAD "$3"; }
report_worker_idle(){ report_worker_state idle '' '' '' ''; }

UPLOAD_HASHTAG="${UPLOAD_HASHTAG// /_}"
[[ -z "$UPLOAD_HASHTAG" || "$UPLOAD_HASHTAG" == \#* ]] || UPLOAD_HASHTAG="#${UPLOAD_HASHTAG}"

require_cmd(){ command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"; }
for cmd in ffmpeg ffprobe python3 timeout jq sha256sum find sort mktemp mkfifo date nproc awk; do require_cmd "$cmd"; done
if (( UPLOAD_ENABLED )); then require_cmd curl; require_cmd "$TDL_BIN"; fi

HAS_DCT_WATERMARK=0
if (( APPLY_DCT_WATERMARK )); then
  if python3 -c 'import cv2,imwatermark' >/dev/null 2>&1; then HAS_DCT_WATERMARK=1; else warn 'DCT dependencies missing; DCT will be skipped.'; fi
fi
ffmpeg -hide_banner -h encoder=libx264 >/dev/null 2>&1 || err 'FFmpeg does not provide libx264.'

mkdir -p "$OUTPUT_ROOT" "$PARALLEL_LOG_DIR"
RUNTIME_ROOT="$(mktemp -d "/tmp/action_tag_${WORKER_ID:-unknown}_XXXXXX")"
UPLOAD_QUEUE_ROOT="$RUNTIME_ROOT/upload_queue"; UPLOAD_RESULT_DIR="$RUNTIME_ROOT/upload_results"; JOB_RESULT_DIR="$RUNTIME_ROOT/job_results"
mkdir -p "$UPLOAD_QUEUE_ROOT" "$UPLOAD_RESULT_DIR" "$JOB_RESULT_DIR"

cleanup(){
  local rc=$? pid
  [[ -z "${UPLOAD_WORKER_PID:-}" ]] || { kill "$UPLOAD_WORKER_PID" >/dev/null 2>&1 || true; wait "$UPLOAD_WORKER_PID" >/dev/null 2>&1 || true; }
  for pid in "${DCT_PIDS[@]:-}"; do [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true; done
  for pid in "${DCT_PIDS[@]:-}"; do [[ -z "$pid" ]] || wait "$pid" >/dev/null 2>&1 || true; done
  report_worker_idle
  [[ -z "${RUNTIME_ROOT:-}" || ! -d "$RUNTIME_ROOT" ]] || rm -rf "$RUNTIME_ROOT"
  return "$rc"
}
trap cleanup EXIT INT TERM

normalize_path(){
  local p="$1" d b
  if [[ -d "$p" ]]; then (cd "$p" && pwd -P); else d="$(dirname "$p")"; b="$(basename "$p")"; (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b"); fi
}
is_video_file(){
  local p="$1" ext="${1##*.}" x; ext="${ext,,}"
  for x in "${VIDEO_EXTS[@]}"; do [[ "$ext" == "$x" ]] && return 0; done
  return 1
}
add_video(){
  local p="$1" real
  [[ -f "$p" ]] && is_video_file "$p" || return 0
  real="$(normalize_path "$p")"
  [[ -n "${SEEN_VIDEO_FILES[$real]+x}" ]] && return 0
  SEEN_VIDEO_FILES["$real"]=1; VIDEO_FILES+=("$real")
}
collect_input(){
  local input="$1" f
  if [[ -d "$input" ]]; then
    while IFS= read -r -d '' f; do add_video "$f"; done < <(find "$input" -type f -print0 | sort -z)
  elif [[ -f "$input" ]]; then add_video "$input"; else warn "Input not found: $input"; fi
}
for input in "${INPUTS[@]}"; do collect_input "$input"; done
VIDEO_COUNT=${#VIDEO_FILES[@]}; USER_COUNT=${#TARGET_UIDS[@]}
(( VIDEO_COUNT > 0 )) || err 'No supported video files were found.'

TDL_STORAGE_CHAT="${STORAGE_FORUM_CHAT#-100}"; export TDL_STORAGE_CHAT

if (( HAS_DCT_WATERMARK )); then
  DCT_SCRIPT="$RUNTIME_ROOT/dct_watermark.py"
  cat > "$DCT_SCRIPT" <<'PY'
import os,sys,json,urllib.parse,urllib.request,subprocess
import cv2,numpy as np
from imwatermark import WatermarkEncoder

def report(stage,pct):
    s=os.getenv('SERVER_URL','').strip(); t=os.getenv('AUTH_TOKEN','').strip(); w=os.getenv('WORKER_ID','').strip()
    if not s or not t or not w:return
    try:p=max(0.0,min(100.0,float(pct)))
    except (TypeError,ValueError):p=0.0
    d={'worker_id':w,'worker_username':os.getenv('GITHUB_ACTOR',''),'status':'running',
       'job_id':os.getenv('JOB_ID') or None,'run_id':os.getenv('GITHUB_RUN_ID') or None,
       'current_user':os.getenv('PROGRESS_USER') or None,'current_file':os.getenv('PROGRESS_FILE') or None,
       'current_stage':stage,'progress':p,'source_id':os.getenv('SOURCE_ID') or None,'request_id':os.getenv('REQUEST_ID') or None}
    try:
        u=s.rstrip('/')+'/worker?token='+urllib.parse.quote(t,safe='')
        r=urllib.request.Request(u,data=json.dumps(d).encode(),headers={'Content-Type':'application/json'},method='POST')
        urllib.request.urlopen(r,timeout=3).close()
    except Exception:pass

def main():
    if len(sys.argv)!=4:return 2
    src,out=sys.argv[1],sys.argv[2]
    try:uid=int(sys.argv[3])
    except ValueError:return 2
    os.environ['PROGRESS_USER']=str(uid); os.environ.setdefault('PROGRESS_FILE',os.path.basename(src))
    cap=cv2.VideoCapture(src)
    if not cap.isOpened(): print('ERROR: Cannot open video',file=sys.stderr); return 1
    fps=cap.get(cv2.CAP_PROP_FPS) or 25.0; w=int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); h=int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)); total=int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if w<=0 or h<=0 or w%2 or h%2: print(f'ERROR: invalid dimensions {w}x{h}',file=sys.stderr); cap.release(); return 1
    enc=WatermarkEncoder(); data=uid.to_bytes(8,'big',signed=False)
    try: enc.set_watermark('bytes',data); method='dwtDct'
    except TypeError: enc.set_watermark(data,model='DWT_DCT'); method=None
    cmd=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo','-pix_fmt','bgr24','-s',f'{w}x{h}','-r',f'{fps:.6f}','-i','pipe:0','-i',src,'-map','0:v:0','-map','1:a:0?','-c:v','libx264','-preset','fast','-crf','27','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-map_metadata','1','-movflags','+faststart',out]
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stderr=subprocess.PIPE); n=0; last=-1.0; report('DCT',0)
    try:
        while True:
            ok,frame=cap.read()
            if not ok:break
            if n%30==0: frame=enc.encode(frame,method) if method else enc.encode(frame)
            p.stdin.write(np.ascontiguousarray(frame).tobytes()); n+=1
            if total>0 and n%20==0:
                pct=n*100.0/total
                if pct>=last+1: report('DCT',pct); last=pct
                print(f'DCT Progress: {n}/{total} ({pct:.1f}%)',flush=True)
        p.stdin.close(); e=p.stderr.read().decode('utf-8','replace'); rc=p.wait()
        if rc: print(e,file=sys.stderr); return rc
    except BrokenPipeError:
        try:p.kill()
        except Exception:pass
        p.wait(); print('ERROR: FFmpeg pipe closed unexpectedly',file=sys.stderr); return 1
    except Exception as e:
        try:p.kill()
        except Exception:pass
        p.wait(); print(f'ERROR while processing video: {e}',file=sys.stderr); return 1
    finally:cap.release()
    report('DCT',100); print(f'DCT COMPLETE: {n} frames',flush=True); return 0

if __name__=='__main__':sys.exit(main())
PY
  chmod +x "$DCT_SCRIPT"
fi

build_jobs(){
  local src uid n=0
  JOB_SRCS=(); JOB_UIDS=(); JOB_NUMBERS=()
  for src in "${VIDEO_FILES[@]}"; do for uid in "${TARGET_UIDS[@]}"; do n=$((n+1)); JOB_SRCS+=("$src"); JOB_UIDS+=("$uid"); JOB_NUMBERS+=("$n"); done; done
}
build_jobs; TOTAL_PROCESS_JOBS=${#JOB_SRCS[@]}
(( TOTAL_PROCESS_JOBS > 0 )) || err 'No internal processing jobs were generated.'
processing_result_path(){ printf '%s/job_%s.processing\n' "$JOB_RESULT_DIR" "$1"; }
upload_result_path(){ printf '%s/job_%s.upload\n' "$JOB_RESULT_DIR" "$1"; }
mark_processing_result(){ printf '%s\n' "$2" > "$(processing_result_path "$1")"; }
mark_upload_result(){ printf '%s\n' "$2" > "$(upload_result_path "$1")"; local id="${3:-}"; [[ -z "$id" ]] || printf '%s\n' "$2" > "$UPLOAD_RESULT_DIR/$id.result"; }
read_result(){ [[ -f "$1" ]] && head -n1 "$1" || echo missing; }

upload_api(){
  local method="$1" url="$2" data="${3:-}" response code body token auth_url
  token="$(printf '%s' "$AUTH_TOKEN" | jq -sRr @uri)"
  [[ "$url" == *'?'* ]] && auth_url="${url}&token=${token}" || auth_url="${url}?token=${token}"
  if [[ "$method" == GET ]]; then response="$(curl -sS --fail-with-body --max-time 30 -w $'\n%{http_code}' "$auth_url")" || { code="${response##*$'\n'}"; body="${response%$'\n'*}"; warn "Upload API HTTP ${code:-unknown}: ${body:-request failed}"; return 1; }; else response="$(curl -sS --fail-with-body --max-time 30 -X "$method" -H 'Content-Type: application/json' -d "$data" -w $'\n%{http_code}' "$auth_url")" || { code="${response##*$'\n'}"; body="${response%$'\n'*}"; warn "Upload API HTTP ${code:-unknown}: ${body:-request failed}"; return 1; }; fi
  code="${response##*$'\n'}"; body="${response%$'\n'*}"; [[ "$code" =~ ^2[0-9][0-9]$ ]] || { warn "Upload API HTTP $code: $body"; return 1; }; printf '%s\n' "$body"
}

enqueue_upload_job(){
  local id="$1" num="$2" uid="$3" file="$4" r st
  r="$(jq -cn --arg upload_id "$id" --arg worker_id "$WORKER_ID" --arg job_id "$JOB_ID" --arg job_num "$num" --arg user_id "$uid" --arg file "$file" --arg source_id "$SOURCE_ID" --arg request_id "$REQUEST_ID" '{upload_id:$upload_id,worker_id:$worker_id,job_id:$job_id,job_num:($job_num|tonumber),user_id:$user_id,file:$file,source_id:($source_id//""),request_id:($request_id//"")}')" || return 1
  r="$(upload_api POST "$SERVER_URL/upload/enqueue" "$r")" || return 1
  st="$(jq -r '.status // empty' <<< "$r")"
  case "$st" in waiting|active|success|failed|queued)return 0;; *) warn "Unexpected enqueue response: $r"; return 1;; esac
}

check_upload_status(){
  local id="$1" eid r
  eid="$(printf '%s' "$id" | jq -sRr @uri)"
  r="$(upload_api GET "$SERVER_URL/upload/status?upload_id=$eid")" || return 1
  UPLOAD_STATUS="$(jq -r '.status // empty' <<< "$r")"; UPLOAD_LEASE_TOKEN="$(jq -r '.lease_token // empty' <<< "$r")"; return 0
}

complete_upload_job(){
  local id="$1" lease="$2" result="$3" p
  p="$(jq -cn --arg upload_id "$id" --arg lease_token "$lease" --arg result "$result" '{upload_id:$upload_id,lease_token:$lease_token,result:$result}')"
  upload_api POST "$SERVER_URL/upload/complete" "$p" >/dev/null
}

extract_upload_progress(){
  local line="$1" p
  [[ "$line" =~ ([0-9]{1,3}(\.[0-9]+)?)[[:space:]]*% ]] || return 1
  p="${BASH_REMATCH[1]}"
  awk -v p="$p" 'BEGIN{exit !(p>=0&&p<=100)}' && printf '%s\n' "$p"
}

upload_one(){
  local file="$1" topic="$2" uid="$3" key="$4" pipe pid line p rc caption='FileName'
  [[ -z "$UPLOAD_HASHTAG" ]] || caption="FileName + \" $UPLOAD_HASHTAG\""
  local -a cmd=("$TDL_BIN")
  [[ -z "${TDL_STORAGE:-}" ]] || cmd+=(--storage "$TDL_STORAGE")
  [[ -z "${TDL_NS:-}" ]] || cmd+=(--ns "$TDL_NS")
  cmd+=(up -l 1 -p "$file" -c "$TDL_STORAGE_CHAT" --caption "$caption")
  [[ -z "$topic" ]] || cmd+=(--topic "$topic")
  log "TDL upload: ${file##*/}"; report_upload_start "$uid" "$file"
  pipe="$RUNTIME_ROOT/$key.fifo"; mkfifo "$pipe"
  timeout "$TDL_TIMEOUT" "${cmd[@]}" >"$pipe" 2>&1 & pid=$!
  while IFS= read -r line; do
    printf '%s\n' "$line"
    if p="$(extract_upload_progress "$line")"; then report_upload_progress "$uid" "$file" "$p"; fi
  done < "$pipe"
  if wait "$pid"; then rc=0; else rc=$?; fi
  rm -f "$pipe"
  (( rc == 0 )) && report_upload_progress "$uid" "$file" 100 || { [[ "$rc" -eq 124 ]] && warn "TDL timeout after ${TDL_TIMEOUT}s | ${file##*/}" || warn "TDL exited with code $rc | ${file##*/}"; return "$rc"; }
}

upload_worker(){
  local done="$RUNTIME_ROOT/producer.done" ready file id topic num uid status lease tries status_tries
  while :; do
    ready="$(find "$UPLOAD_QUEUE_ROOT" -maxdepth 1 -type f -name '*.ready' -print | sort | head -n1)"
    if [[ -z "$ready" ]]; then [[ -f "$done" ]] && break; sleep .5; continue; fi
    id="$(jq -r '.upload_id' "$ready")"; file="$(jq -r '.file' "$ready")"; topic="$(jq -r '.topic_id // empty' "$ready")"; num="$(jq -r '.job_num' "$ready")"; uid="$(jq -r '.user_id // empty' "$ready")"
    if [[ -z "$uid" ]]; then write_upload_failure "$num" "$id"; rm -f "$ready"; continue; fi
    tries=0
    until enqueue_upload_job "$id" "$num" "$uid" "$file"; do tries=$((tries+1)); [[ "$tries" -ge 10 ]] && { warn "Giving up on enqueue: $id"; write_upload_failure "$num" "$id"; rm -f "$ready"; break; }; sleep $((tries<5?tries:5)); done
    [[ -f "$ready" ]] || continue
    status_tries=0
    while :; do
      if ! check_upload_status "$id"; then status_tries=$((status_tries+1)); [[ "$status_tries" -ge 20 ]] && { write_upload_failure "$num" "$id"; rm -f "$ready"; break; }; sleep 2; continue; fi
      status="$UPLOAD_STATUS"; lease="$UPLOAD_LEASE_TOKEN"; status_tries=0
      case "$status" in
        success) report_upload_progress "$uid" "$file" 100; write_upload_success "$num" "$id"; rm -f "$ready"; break;;
        failed) warn "Server reported upload failed: $id"; write_upload_failure "$num" "$id"; rm -f "$ready"; break;;
        active) [[ -n "$lease" ]] || { sleep 1; continue; }
          if upload_one "$file" "$topic" "$uid" "$id"; then
            if complete_upload_job "$id" "$lease" success; then write_upload_success "$num" "$id"; else warn "TDL upload succeeded but completion API failed: $id"; write_upload_failure "$num" "$id"; fi
          else
            complete_upload_job "$id" "$lease" failed || true; write_upload_failure "$num" "$id"
          fi
          rm -f "$ready"; break;;
        waiting|queued) sleep 1;;
        *) warn "Unknown upload status '$status' for $id"; sleep 2;;
      esac
    done
  done
}

process_user_video(){
  local src="$1" uid="$2" num="$3" dir base stem dst tmp topic upload_id queue_file start end sec min caption
  dir="$OUTPUT_ROOT/$uid"; mkdir -p "$dir"; base="$(basename "$src")"; stem="${base%.*}"; dst="$dir/${stem}.mp4"; tmp="$dst.dct.mp4"; topic="${TARGET_TOPICS[$uid]:-}"; start="$(date +%s)"
  log "Internal job $num/$TOTAL_PROCESS_JOBS | User=$uid | Video=$base"; report_dct_start "$uid" "$base"
  if (( APPLY_DCT_WATERMARK && HAS_DCT_WATERMARK )); then
    rm -f "$tmp"; export PROGRESS_USER="$uid" PROGRESS_FILE="$base"
    if ! python3 "$DCT_SCRIPT" "$src" "$tmp" "$uid" >"$PARALLEL_LOG_DIR/job_${num}.dct.log" 2>&1; then warn "DCT failed | job=$num | user=$uid | video=$base"; mark_processing_result "$num" failed; return 1; fi
    [[ -s "$tmp" ]] || { warn "DCT output missing/empty | job=$num"; mark_processing_result "$num" failed; return 1; }
    mv -f "$tmp" "$dst"
  else
    cp -f "$src" "$dst"; report_dct_progress "$uid" "$base" 100
  fi
  if (( UPLOAD_ENABLED && UPLOAD_AFTER_TAGGING )); then
    upload_id="${JOB_ID}_${WORKER_ID}_${num}_$(date +%s%N)"; queue_file="$UPLOAD_QUEUE_ROOT/${upload_id}.ready"
    jq -cn --arg upload_id "$upload_id" --arg file "$dst" --arg topic_id "$topic" --arg user_id "$uid" --arg job_num "$num" --arg source_id "$SOURCE_ID" --arg request_id "$REQUEST_ID" '{upload_id:$upload_id,file:$file,topic_id:$topic_id,user_id:$user_id,job_num:($job_num|tonumber),source_id:($source_id//""),request_id:($request_id//"")}' > "$queue_file"
    mark_processing_result "$num" success; ok "DCT ready / upload queued | job=$num | user=$uid | file=$base"
  else
    mark_processing_result "$num" success; ok "Processing complete | job=$num | user=$uid | file=$base"
  fi
  end="$(date +%s)"; sec=$((end-start)); min=$((sec/60)); sec=$((sec%60)); log "Internal job finished | job=$num | ${min}m ${sec}s"
}

write_upload_success(){ mark_upload_result "$1" success "$2"; }
write_upload_failure(){ mark_upload_result "$1" failed "$2"; }

run_job(){ local src="$1" uid="$2" num="$3"; if ! process_user_video "$src" "$uid" "$num"; then mark_processing_result "$num" failed; fi; }
wait_one_dct(){
  local pid="${DCT_PIDS[0]:-}" num="${DCT_PID_JOB_NUMBERS[0]:-}" rc
  [[ -n "$pid" ]] || return 0
  if wait "$pid"; then :; else rc=$?; warn "DCT worker exited with code $rc | job=$num"; [[ -f "$(processing_result_path "$num")" ]] || mark_processing_result "$num" failed; fi
  DCT_PIDS=("${DCT_PIDS[@]:1}"); DCT_PID_JOB_NUMBERS=("${DCT_PID_JOB_NUMBERS[@]:1}")
}

log "Worker: $WORKER_ID"; log "Job: $JOB_ID"; log "Source ID: ${SOURCE_ID:-<none>}"; log "Request ID: ${REQUEST_ID:-<none>}"; log "Users: $USER_COUNT"; log "Videos: $VIDEO_COUNT"; log "Internal jobs: $TOTAL_PROCESS_JOBS"; log "Max parallel DCT jobs: $MAX_DCT_JOBS"; log "DCT: $([[ $APPLY_DCT_WATERMARK -eq 1 && $HAS_DCT_WATERMARK -eq 1 ]] && echo enabled || echo disabled)"; log "Upload: $([[ $UPLOAD_ENABLED -eq 1 ]] && echo enabled || echo disabled)"
report_worker_state running '' '' STARTING 0
(( UPLOAD_ENABLED )) && { upload_worker & UPLOAD_WORKER_PID=$!; }

for i in "${!JOB_SRCS[@]}"; do
  while (( ${#DCT_PIDS[@]} >= MAX_DCT_JOBS )); do wait_one_dct; done
  run_job "${JOB_SRCS[$i]}" "${JOB_UIDS[$i]}" "${JOB_NUMBERS[$i]}" &
  DCT_PIDS+=("$!"); DCT_PID_JOB_NUMBERS+=("${JOB_NUMBERS[$i]}")
done
while (( ${#DCT_PIDS[@]} > 0 )); do wait_one_dct; done

if (( UPLOAD_ENABLED )); then touch "$RUNTIME_ROOT/producer.done"; if wait "$UPLOAD_WORKER_PID"; then :; else rc=$?; warn "Upload worker exited with code $rc"; fi; UPLOAD_WORKER_PID=""; fi

completed_count=0; failed_count=0
for num in "${JOB_NUMBERS[@]}"; do
  pr="$(read_result "$(processing_result_path "$num")")"
  if [[ "$pr" != success ]]; then failed_count=$((failed_count+1)); continue; fi
  if (( UPLOAD_ENABLED && UPLOAD_AFTER_TAGGING )); then [[ "$(read_result "$(upload_result_path "$num")")" == success ]] && completed_count=$((completed_count+1)) || failed_count=$((failed_count+1)); else completed_count=$((completed_count+1)); fi
done

report_worker_idle
if (( failed_count )); then warn "Processing finished with failures | success=$completed_count | failed=$failed_count | total=$TOTAL_PROCESS_JOBS"; exit 1; else ok "All processing jobs finished | success=$completed_count | failed=$failed_count | total=$TOTAL_PROCESS_JOBS"; fi
