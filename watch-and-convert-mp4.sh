#!/usr/bin/env bash
#
# input/ に新たに .mp4 ファイルが置かれたら、
# 10MB未満を目標に 720p 60fps にエンコードしたファイルを output/ に書き出し、
# 処理が終わったら元ファイル (input/*.mp4) を削除します。
#
# 縦動画 (高さ > 幅) が入力された場合は、自動的に 720x1280 に変換します。
#
# 依存:
#   - inotifywait (inotify-tools パッケージ)
#   - ffmpeg, ffprobe
#
# 使い方:
#   1) input/ と output/ ディレクトリがあることを確認
#   2) chmod +x watch-and-convert-mp4.sh
#   3) ./watch-and-convert-mp4.sh
#

set -euo pipefail

# ------ ここからユーザ設定 ------
TARGET_MAX_SIZE_MB=10      # 上限サイズ (この値未満を目標)
SIZE_MARGIN_KB=256         # 「未満」を確実にするための安全マージン
MAX_TRIALS=4               # ビットレート再調整の最大試行回数
PRESET="medium"            # x264のプリセット
AUDIO_BITRATE=128          # kbps
MIN_AUDIO_BITRATE=24       # kbps (ターゲットが小さい場合に自動調整)
MIN_VIDEO_BITRATE=30       # kbps (極端な圧縮時の下限)
TARGET_SHORT=720           # 短辺のターゲット解像度 (720p)
TARGET_LONG=1280           # 長辺のターゲット解像度 (720p)
FRAMERATE="60"
# ------ ここまでユーザ設定 ------

INPUT_DIR="input"
OUTPUT_DIR="output"

# 事前にフォルダが存在するか確認
if [[ ! -d "${INPUT_DIR}" ]]; then
  echo "Error: '${INPUT_DIR}' フォルダが存在しません。" >&2
  exit 1
fi
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Error: '${OUTPUT_DIR}' フォルダが存在しません。" >&2
  exit 1
fi

# ---- 入力動画の向きを判定し、適切なscaleフィルターを返す関数 ----
get_scale_filter () {
  local in_filepath="$1"

  local width height
  width="$(ffprobe -v error -select_streams v:0 \
           -show_entries stream=width -of csv=p=0 "${in_filepath}")"
  height="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=height -of csv=p=0 "${in_filepath}")"

  if [[ -z "${width}" || -z "${height}" ]]; then
    echo "scale=${TARGET_LONG}:${TARGET_SHORT}"
    return
  fi

  if (( height > width )); then
    # 縦動画: 幅=720, 高さ=1280
    echo "scale=${TARGET_SHORT}:${TARGET_LONG}"
  else
    # 横動画 (正方形含む): 幅=1280, 高さ=720
    echo "scale=${TARGET_LONG}:${TARGET_SHORT}"
  fi
}

# ---- 2passエンコード + ファイルサイズ再調整を行う関数 ----
encode_to_target_size () {
  local in_filepath="$1"
  local out_filepath="$2"

  # 一時ディレクトリを作成してパスログを安全に管理
  local tmpdir
  tmpdir="$(mktemp -d)"
  # 関数終了時に一時ディレクトリを確実に削除
  trap 'rm -rf "${tmpdir}"' RETURN

  local basename_noext
  basename_noext="$(basename "${in_filepath}" .mp4)"
  local passlog="${tmpdir}/${basename_noext}_2pass"

  local target_max_bytes=$(( TARGET_MAX_SIZE_MB * 1024 * 1024 ))
  local target_size_bytes=$(( target_max_bytes - SIZE_MARGIN_KB * 1024 ))
  if (( target_size_bytes <= 0 )); then
    echo "  --> エラー: TARGET_MAX_SIZE_MB / SIZE_MARGIN_KB の設定値が不正です。" >&2
    return 1
  fi

  # 動画の長さを取得
  local duration
  duration="$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
             -of csv=p=0 "${in_filepath}")"

  if [[ -z "${duration}" ]]; then
    echo "  --> エラー: 動画の長さを取得できませんでした。" >&2
    return 1
  fi

  # 入力動画の向きに応じたscaleフィルターを決定
  local scale_filter
  scale_filter="$(get_scale_filter "${in_filepath}")"
  echo "  --> scaleフィルター: ${scale_filter}"

  # 目標サイズから平均総ビットレート(kbps)を算出し、音声を含めて動的に配分
  local target_total_kbps
  target_total_kbps=$(awk -v size_bits=$((target_size_bytes * 8)) -v dur="${duration}" \
    'BEGIN { printf "%.0f", (size_bits / dur) / 1000 }')

  local dynamic_audio_bitrate="${AUDIO_BITRATE}"
  if (( target_total_kbps <= AUDIO_BITRATE + MIN_VIDEO_BITRATE )); then
    dynamic_audio_bitrate=$(
      awk -v total="${target_total_kbps}" -v min_aud="${MIN_AUDIO_BITRATE}" \
        'BEGIN {
           cand = int(total * 0.20);
           if (cand < min_aud) cand = min_aud;
           printf "%d", cand;
         }'
    )
  fi

  local video_bitrate_initial
  video_bitrate_initial=$(
    awk -v total="${target_total_kbps}" \
        -v aud="${dynamic_audio_bitrate}" \
        -v min_v="${MIN_VIDEO_BITRATE}" \
      'BEGIN {
         vbps = (total - aud) * 0.97;  # 余裕を持たせる
         if (vbps < min_v) vbps = min_v;
         printf "%.0f", vbps;
       }'
  )

  local max_video_bitrate=$(( video_bitrate_initial * 4 ))
  if (( max_video_bitrate < video_bitrate_initial + 200 )); then
    max_video_bitrate=$(( video_bitrate_initial + 200 ))
  fi

  # 音声サイズの見積もり (bytes) = duration * dynamic_audio_bitrate * 1000 / 8
  # コンテナオーバーヘッドとして約 1.01 を乗じる
  local audio_size_est
  audio_size_est=$(awk -v dur="${duration}" -v ab="${dynamic_audio_bitrate}" \
    'BEGIN { printf "%.0f", (dur * ab * 1000 / 8) * 1.01 }')

  # 早期終了の境界値 (9.5MB 〜 10.0MB未満)
  local early_stop_min_bytes=$(( 95 * target_max_bytes / 100 ))  # 9.5MB
  local early_stop_max_bytes=$(( target_max_bytes - 1 ))          # 10MB未満

  local best_under_size=0
  local best_under_bitrate=""
  local best_under_file="${tmpdir}/best_under.mp4"

  local history_v=()
  local history_s=()

  echo "  --> 動画長さ: ${duration}s"
  echo "  --> 上限サイズ: ${TARGET_MAX_SIZE_MB} MB (探索目標: $((target_size_bytes / 1024 / 1024)) MB台)"
  echo "  --> 目標総ビットレート: ${target_total_kbps} kbps"
  echo "  --> 音声ビットレート: ${dynamic_audio_bitrate} kbps"
  echo "  --> 初期ビットレート推定: ${video_bitrate_initial} kbps"

  # 2passエンコード (1回の試行)
  do_2pass () {
    local bitrate_kbps="$1"

    # 1pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${bitrate_kbps}k" \
      -pass 1 -passlogfile "${passlog}" \
      -vf "${scale_filter}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" \
      -an -f mp4 /dev/null 2>/dev/null

    # 2pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${bitrate_kbps}k" \
      -pass 2 -passlogfile "${passlog}" \
      -vf "${scale_filter}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" \
      -c:a aac -b:a "${dynamic_audio_bitrate}k" \
      "${out_filepath}" 2>/dev/null
  }

  local trial=1
  local cur_video_bitrate="${video_bitrate_initial}"

  while (( trial <= MAX_TRIALS )); do
    echo "  -> [${trial}/${MAX_TRIALS}] 試行ビットレート: ${cur_video_bitrate} kbps"

    do_2pass "${cur_video_bitrate}"

    if [[ ! -f "${out_filepath}" ]]; then
      echo "  --> エンコード失敗、ファイルが生成されていません。" >&2
      return 1
    fi

    local filesize
    filesize=$(stat -c%s "${out_filepath}" 2>/dev/null)
    if [[ -z "${filesize}" ]]; then
      echo "  --> エンコード失敗、ファイルサイズが取得できません。" >&2
      return 1
    fi

    local diff=$(( filesize - target_max_bytes ))
    echo "    出力ファイルサイズ: $((filesize / 1024 / 1024)) MB (実測: ${filesize} bytes, ${TARGET_MAX_SIZE_MB}MB上限との差分: ${diff} bytes)"

    # 履歴に追加
    history_v+=("${cur_video_bitrate}")
    history_s+=("${filesize}")

    # 10MB未満で、これまでで最大のサイズならキャッシュ
    if (( filesize < target_max_bytes && filesize > best_under_size )); then
      best_under_size="${filesize}"
      best_under_bitrate="${cur_video_bitrate}"
      cp "${out_filepath}" "${best_under_file}"
    fi

    # 早期終了判定
    if (( filesize >= early_stop_min_bytes && filesize <= early_stop_max_bytes )); then
      echo "  --> 目標サイズ範囲内（9.5MB〜10.0MB未満）に収まったため、探索を早期終了します。"
      break
    fi

    # 次のビットレートを算出する（最後の試行なら計算不要）
    if (( trial < MAX_TRIALS )); then
      local next_v
      if (( trial == 1 )); then
        # 1点目の実測値と見積もり音声サイズから線形予測
        next_v=$(awk -v v1="${cur_video_bitrate}" \
                     -v s1="${filesize}" \
                     -v target="${target_size_bytes}" \
                     -v audio="${audio_size_est}" \
          'BEGIN {
             denom = s1 - audio;
             if (denom <= 0) denom = 1;
             val = v1 * (target - audio) / denom;
             printf "%.0f", val;
          }')
        
        # 1回目が上限を超えていた場合、安全のために少し小さめの値にする（安全係数 0.95）
        if (( filesize >= target_max_bytes )); then
          next_v=$(awk -v v="${next_v}" 'BEGIN { printf "%.0f", v * 0.95 }')
        fi
      else
        # 2点以上の実測値から線形補間/外挿
        local idx_prev=$(( trial - 2 ))
        local idx_curr=$(( trial - 1 ))
        local v_prev="${history_v[idx_prev]}"
        local s_prev="${history_s[idx_prev]}"
        local v_curr="${history_v[idx_curr]}"
        local s_curr="${history_s[idx_curr]}"

        # 変化量が極小（エンコード品質上限に達したなど）の場合は探索を終了
        local diff_v=$(( v_curr - v_prev ))
        if (( diff_v < 0 )); then diff_v=$(( -diff_v )); fi
        local diff_s=$(( s_curr - s_prev ))
        if (( diff_s < 0 )); then diff_s=$(( -diff_s )); fi

        if (( diff_v < 5 || diff_s < 10240 )); then # 5kbps未満、または10KB未満の変化
          echo "  --> ビットレート変化量またはファイルサイズ変化量が極小のため、これ以上の調整は不要と判断し探索を終了します。"
          break
        fi

        next_v=$(awk -v v_p="${v_prev}" -v s_p="${s_prev}" \
                     -v v_c="${v_curr}" -v s_c="${s_curr}" \
                     -v target="${target_size_bytes}" \
          'BEGIN {
             denom = s_c - s_p;
             if (denom == 0) denom = 1;
             val = v_c + (target - s_c) * (v_c - v_p) / denom;
             printf "%.0f", val;
          }')

        # 直前が上限を超えていた場合は安全のために少し小さめの値にする（安全係数 0.98）
        if (( s_curr >= target_max_bytes && next_v < v_curr )); then
          next_v=$(awk -v v="${next_v}" 'BEGIN { printf "%.0f", v * 0.98 }')
        fi
      fi

      # 範囲制限を適用
      next_v=$(awk -v val="${next_v}" -v min_v="${MIN_VIDEO_BITRATE}" -v max_v="${max_video_bitrate}" \
        'BEGIN {
           if (val < min_v) val = min_v;
           if (val > max_v) val = max_v;
           printf "%.0f", val;
        }')

      # ビットレートが変わらない場合は無限ループ防止のために終了
      if [[ "${next_v}" == "${cur_video_bitrate}" ]]; then
        echo "  --> 計算された次期ビットレートが現在と同一のため、探索を終了します。"
        break
      fi

      cur_video_bitrate="${next_v}"
    fi

    trial=$(( trial + 1 ))
  done

  # 探索結果の適用
  if (( best_under_size > 0 )); then
    # 10MB未満のエンコード結果が存在する場合、キャッシュファイルをコピーして完了
    mv "${best_under_file}" "${out_filepath}"
    echo "  --> 最終推奨ビットレート: ${best_under_bitrate} kbps (サイズ: $((best_under_size / 1024 / 1024)) MB)"
    echo "  --> エンコード完了: ${out_filepath}"
    return 0
  else
    # すべての試行で10MBを超えてしまった場合、フォールバック処理
    echo "  --> [警告] すべての試行で10MBの上限を超えました。最小ビットレートで強制再エンコードします。"

    local fallback_video_bitrate="${MIN_VIDEO_BITRATE}"
    local fallback_audio_bitrate="${MIN_AUDIO_BITRATE}"

    echo "  --> 強制エンコード設定: 映像 ${fallback_video_bitrate} kbps / 音声 ${fallback_audio_bitrate} kbps"

    # 1pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${fallback_video_bitrate}k" \
      -pass 1 -passlogfile "${passlog}" \
      -vf "${scale_filter}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" \
      -an -f mp4 /dev/null 2>/dev/null

    # 2pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${fallback_video_bitrate}k" \
      -pass 2 -passlogfile "${passlog}" \
      -vf "${scale_filter}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" \
      -c:a aac -b:a "${fallback_audio_bitrate}k" \
      "${out_filepath}" 2>/dev/null

    local final_size
    final_size=$(stat -c%s "${out_filepath}" 2>/dev/null || echo 0)
    if (( final_size >= target_max_bytes )); then
      echo "  --> [エラー] 最小設定でも10MB未満に収まりませんでした。ファイルサイズ: ${final_size} bytes" >&2
      return 1
    fi

    echo "  --> 強制エンコード完了: ${out_filepath} (サイズ: $((final_size / 1024 / 1024)) MB)"
    return 0
  fi
}

# ---- inotify を使って input/ を監視 ----
echo "=== start watching '${INPUT_DIR}' for new .mp4 files ==="

# close_write は「ファイルの書き込みが完了した」というイベント
inotifywait -m -e close_write --format '%w%f' "${INPUT_DIR}" | while read -r NEWFILE
do
  # .mp4 以外はスキップ
  if [[ "${NEWFILE}" =~ \.mp4$ ]]; then
    filename_only="$(basename "${NEWFILE}")"
    OUT_PATH="${OUTPUT_DIR}/${filename_only}"

    echo
    echo "=== 新しいファイル検知: ${NEWFILE} ==="
    if [[ -f "${OUT_PATH}" ]]; then
      echo "  --> すでに同名のファイルが output/ に存在します。上書きします。"
    fi

    # エンコードを実行
    if encode_to_target_size "${NEWFILE}" "${OUT_PATH}"; then
      # 正常終了なら元ファイルを削除
      echo "  --> 元ファイルを削除します: ${NEWFILE}"
      rm -f "${NEWFILE}"
    else
      echo "  --> エンコードに失敗したため、元ファイルは削除しません。"
    fi

    echo "=== 処理終了 ==="
  fi
done
