#!/usr/bin/env bash
#
# input/ に新たに .mp4 ファイルが置かれたら、
# 10MB未満を目標に FullHD 60fps にエンコードしたファイルを output/ に書き出し、
# 処理が終わったら元ファイル (input/*.mp4) を削除します。
#
# 依存:
#   - inotifywait (inotify-tools パッケージ)
#   - ffmpeg, ffprobe
#
# 使い方:
#   1) input/ と output/ ディレクトリがあることを確認
#   2) chmod +x watch_and_convert.sh
#   3) ./watch_and_convert.sh
#

# ------ ここからユーザ設定 ------
TARGET_MAX_SIZE_MB=10      # 上限サイズ (この値未満を目標)
SIZE_MARGIN_KB=128         # 「未満」を確実にするための安全マージン
MAX_LOOP_UPPER=12          # ビットレート再調整の最大試行回数(上限)
PRESET="medium"            # x264のプリセット
AUDIO_BITRATE=128          # kbps
MIN_AUDIO_BITRATE=24       # kbps (ターゲットが小さい場合に自動調整)
MIN_VIDEO_BITRATE=30       # kbps (極端な圧縮時の下限)
SCALE="1920:1080"          # FullHD
FRAMERATE="60"
# ------ ここまでユーザ設定 ------

INPUT_DIR="input"
OUTPUT_DIR="output"

# 事前にフォルダが存在するか確認
if [ ! -d "${INPUT_DIR}" ]; then
  echo "Error: '${INPUT_DIR}' フォルダが存在しません。"
  exit 1
fi
if [ ! -d "${OUTPUT_DIR}" ]; then
  echo "Error: '${OUTPUT_DIR}' フォルダが存在しません。"
  exit 1
fi

# ---- 2passエンコード + ファイルサイズ再調整を行う関数 ----
encode_to_target_size () {
  local in_filepath="$1"
  local out_filepath="$2"

  # 拡張子抜きのベースファイル名を取得 (passlog名に使う)
  local basename_noext
  basename_noext="$(basename "${in_filepath}" .mp4)"

  local target_max_bytes=$(( TARGET_MAX_SIZE_MB * 1024 * 1024 ))
  local target_size_bytes=$(( target_max_bytes - SIZE_MARGIN_KB * 1024 ))
  if [ "${target_size_bytes}" -le 0 ]; then
    echo "  --> エラー: TARGET_MAX_SIZE_MB / SIZE_MARGIN_KB の設定値が不正です。"
    return 1
  fi

  local duration
  duration="$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
             -of csv=p=0 "${in_filepath}")"

  if [ -z "${duration}" ]; then
    echo "  --> エラー: 動画の長さを取得できませんでした。"
    return 1
  fi

  # 目標サイズから平均総ビットレート(kbps)を算出し、音声を含めて動的に配分
  local target_total_kbps
  target_total_kbps=$(awk -v size_bits=$((target_size_bytes * 8)) -v dur="${duration}" \
    'BEGIN { printf "%.0f", (size_bits / dur) / 1000 }')

  local dynamic_audio_bitrate="${AUDIO_BITRATE}"
  if [ "${target_total_kbps}" -le $((AUDIO_BITRATE + MIN_VIDEO_BITRATE)) ]; then
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

  local min_video_bitrate
  min_video_bitrate=$(awk -v init="${video_bitrate_initial}" -v min_v="${MIN_VIDEO_BITRATE}" \
    'BEGIN {
      cand = int(init * 0.20);
      if (cand < min_v) cand = min_v;
      printf "%d", cand;
    }')

  local max_video_bitrate=$((video_bitrate_initial * 4))
  if [ "${max_video_bitrate}" -lt $((video_bitrate_initial + 200)) ]; then
    max_video_bitrate=$((video_bitrate_initial + 200))
  fi

  local max_loop
  max_loop=$(awk -v min="${min_video_bitrate}" -v max="${max_video_bitrate}" -v upper="${MAX_LOOP_UPPER}" \
    'BEGIN {
      range = max - min + 1;
      loops = int(log(range) / log(2)) + 3;
      if (loops < 6) loops = 6;
      if (loops > upper) loops = upper;
      printf "%d", loops;
    }')

  local current_loop=1
  local best_bitrate="${video_bitrate_initial}"
  local best_under_size=-1
  local best_over_size=999999999999
  local best_over_bitrate="${video_bitrate_initial}"

  echo "  --> 動画長さ: ${duration}s"
  echo "  --> 上限サイズ: ${TARGET_MAX_SIZE_MB} MB (探索目標: $((target_size_bytes/1024/1024)) MB台)"
  echo "  --> 目標総ビットレート: ${target_total_kbps} kbps"
  echo "  --> 音声ビットレート: ${dynamic_audio_bitrate} kbps"
  echo "  --> 初期ビットレート推定: ${video_bitrate_initial} kbps"

  # 2passエンコード用の内部関数 (1回の試行)
  do_2pass () {
    local bitrate_kbps="$1"
    local passlog="${basename_noext}_2pass.log"

    # 1pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${bitrate_kbps}k" \
      -pass 1 -passlogfile "${passlog}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" -s "${SCALE}" \
      -an -f mp4 /dev/null 2>/dev/null

    # 2pass
    ffmpeg -y -i "${in_filepath}" \
      -c:v libx264 -preset "${PRESET}" -b:v "${bitrate_kbps}k" \
      -pass 2 -passlogfile "${passlog}" \
      -pix_fmt yuv420p -r "${FRAMERATE}" -s "${SCALE}" \
      -c:a aac -b:a "${dynamic_audio_bitrate}k" \
      "${out_filepath}" 2>/dev/null

    rm -f "${passlog}"*
  }

  # ビットレート調整の二分探索ループ
  while [ "${current_loop}" -le "${max_loop}" ]
  do
    local cur_video_bitrate
    cur_video_bitrate=$(
      awk -v min="${min_video_bitrate}" \
          -v max="${max_video_bitrate}" \
        'BEGIN { printf "%.0f", (min + max) / 2 }'
    )
    echo "  -> [${current_loop}/${max_loop}] 試行ビットレート: ${cur_video_bitrate} kbps"

    do_2pass "${cur_video_bitrate}"

    if [ ! -f "${out_filepath}" ]; then
      echo "  --> エンコード失敗、ファイルが生成されていません。"
      return 1
    fi

    local filesize
    filesize=$(stat -c%s "${out_filepath}" 2>/dev/null)
    if [ -z "${filesize}" ]; then
      echo "  --> エンコード失敗、ファイルサイズが取得できません。"
      return 1
    fi

    local diff=$(( filesize - target_max_bytes ))
    echo "    出力ファイルサイズ: $((filesize/1024/1024)) MB (10MB上限との差分: ${diff} bytes)"

    if [ "${filesize}" -lt "${target_max_bytes}" ] && [ "${filesize}" -gt "${best_under_size}" ]; then
      best_under_size="${filesize}"
      best_bitrate="${cur_video_bitrate}"
    fi

    if [ "${filesize}" -ge "${target_max_bytes}" ] && [ "${filesize}" -lt "${best_over_size}" ]; then
      best_over_size="${filesize}"
      best_over_bitrate="${cur_video_bitrate}"
    fi

    if [ "${diff}" -ge 0 ]; then
      # 10MB以上 → ビットレートを下げる
      max_video_bitrate=$((cur_video_bitrate - 1))
    else
      # 10MB未満 → 品質を上げるためビットレートを上げる
      min_video_bitrate=$((cur_video_bitrate + 1))
    fi

    # 二分探索が収束したら終了
    if [ "${min_video_bitrate}" -gt "${max_video_bitrate}" ]; then
      echo "  --> ビットレート探索範囲が収束しました。"
      break
    fi

    current_loop=$((current_loop + 1))
  done

  if [ "${best_under_size}" -lt 0 ]; then
    # すべて10MB以上だった場合は、超過が最小の候補を採用
    best_bitrate="${best_over_bitrate}"
  fi

  do_2pass "${best_bitrate}"

  echo "  --> 最終推奨ビットレート: ${best_bitrate} kbps"
  echo "  --> エンコード完了: ${out_filepath}"

  # 正常終了
  return 0
}

# ---- inotify を使って input/ を監視 ----
echo "=== start watching '${INPUT_DIR}' for new .mp4 files ==="

# close_write は「ファイルの書き込みが完了した」というイベント
inotifywait -m -e close_write --format '%w%f' "${INPUT_DIR}" | while read NEWFILE
do
  # .mp4 以外はスキップ
  if [[ "${NEWFILE}" =~ \.mp4$ ]]; then
    filename_only="$(basename "${NEWFILE}")"
    OUT_PATH="${OUTPUT_DIR}/${filename_only}"

    echo
    echo "=== 新しいファイル検知: ${NEWFILE} ==="
    if [ -f "${OUT_PATH}" ]; then
      echo "  --> すでに同名のファイルが output/ に存在します。上書きします。"
    fi

    # エンコードを実行
    encode_to_target_size "${NEWFILE}" "${OUT_PATH}"
    if [ $? -eq 0 ]; then
      # 正常終了なら元ファイルを削除
      echo "  --> 元ファイルを削除します: ${NEWFILE}"
      rm -f "${NEWFILE}"
    else
      echo "  --> エンコードに失敗したため、元ファイルは削除しません。"
    fi

    echo "=== 処理終了 ==="
  fi
done
