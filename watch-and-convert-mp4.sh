#!/usr/bin/env bash
#
# input/ に新たに .mp4 ファイルが置かれたら、
# 49MB を目指して FullHD 60fps にエンコードしたファイルを output/ に書き出し、
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
TARGET_SIZE_MB=49
MAX_LOOP=6                 # ビットレート再調整の最大試行回数
PRESET="medium"            # x264のプリセット
AUDIO_BITRATE=128          # kbps
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
encode_to_49mb () {
  local in_filepath="$1"
  local out_filepath="$2"

  # 拡張子抜きのベースファイル名を取得 (passlog名に使う)
  local basename_noext
  basename_noext="$(basename "${in_filepath}" .mp4)"
  
  local target_size_bytes=$(( TARGET_SIZE_MB * 1024 * 1024 ))
  local duration
  duration="$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
             -of csv=p=0 "${in_filepath}")"

  if [ -z "${duration}" ]; then
    echo "  --> エラー: 動画の長さを取得できませんでした。"
    return 1
  fi

  # 初期映像ビットレート(kbps)を計算
  local video_bitrate_initial
  video_bitrate_initial=$(
    awk -v size_bits=$((target_size_bytes * 8)) \
        -v dur="${duration}" \
        -v aud_kbps="${AUDIO_BITRATE}" \
      'BEGIN {
         vbps = (size_bits / dur) / 1000;  # 全体の平均ビットレート (kbps)
         vbps = (vbps - aud_kbps) * 0.95;  # 音声分を差し引いて安全率5%程度
         if (vbps < 100) vbps = 100;       # 下限 100 kbps
         printf "%.0f", vbps;
       }'
  )

  local min_video_bitrate=100
  local max_video_bitrate=$((video_bitrate_initial * 5))
  local current_loop=1
  local best_diff=999999999
  local best_bitrate="${video_bitrate_initial}"

  echo "  --> 動画長さ: ${duration}s"
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
      -c:a aac -b:a "${AUDIO_BITRATE}k" \
      "${out_filepath}" 2>/dev/null

    rm -f "${passlog}"*
  }

  # ビットレート調整の二分探索ループ
  while [ "${current_loop}" -le "${MAX_LOOP}" ]
  do
    local cur_video_bitrate
    cur_video_bitrate=$(
      awk -v min="${min_video_bitrate}" \
          -v max="${max_video_bitrate}" \
        'BEGIN { printf "%.0f", (min + max) / 2 }'
    )
    echo "  -> [${current_loop}/${MAX_LOOP}] 試行ビットレート: ${cur_video_bitrate} kbps"

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

    local diff=$(( filesize - target_size_bytes ))
    echo "    出力ファイルサイズ: $((filesize/1024/1024)) MB (差分: ${diff} bytes)"

    if [ "${diff}" -gt 0 ]; then
      # ターゲットサイズ超過 → ビットレートを下げる
      max_video_bitrate=$((cur_video_bitrate - 1))
    else
      # ターゲットサイズ未満 → ビットレートを上げる
      min_video_bitrate=$((cur_video_bitrate + 1))
    fi

    local abs_diff="${diff#-}"  # 絶対値
    if [ "${abs_diff}" -lt "${best_diff}" ]; then
      best_diff="${abs_diff}"
      best_bitrate="${cur_video_bitrate}"
    fi

    # 二分探索が収束したら終了
    if [ "${min_video_bitrate}" -gt "${max_video_bitrate}" ]; then
      echo "  --> ビットレート探索範囲が収束しました。"
      break
    fi

    current_loop=$((current_loop + 1))
  done

  echo "  --> 最終推奨ビットレート: ${best_bitrate} kbps"
  echo "  --> エンコード完了: ${out_filepath}"
  
  # 正常終了
  return 0
}

# ---- inotify を使って input/ を監視 ----
echo "=== start watching '${INPUT_DIR}' for new .mp4 files ==="

# close_write は「ファイルの書き込みが完了した」というイベント
inotifywait -m -e close_write --format '%w%f' "${INPUT_DIR}" | while IFS= read -r NEWFILE
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
    encode_to_49mb "${NEWFILE}" "${OUT_PATH}"
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
