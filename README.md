# inotify-ffmpeg-auto-encoder


`watch-and-convert-mp4` は、**Ubuntu** 上で動作する Bash スクリプトです。  
`inotifywait` を利用して特定のディレクトリ（`input/`）を監視し、新たに置かれた `.mp4` ファイルを **49MB 以下** に収まるように自動エンコードします。  
エンコードしたファイルは `output/` ディレクトリに書き出され、処理完了後には元ファイルを削除します。

## 特徴

- **自動監視**  
  `inotifywait` を使って `input/` ディレクトリをリアルタイム監視。  
  新しい `.mp4` ファイルが書き込み完了したタイミングで即座に処理を開始します。

- **49MB サイズ指定**  
  入力動画の長さを調べ、目標サイズ（デフォルト 49MB）に近づけるために  
  2pass エンコードを複数回繰り返し、ビットレートを調整します。

- **出力設定**  
  - 解像度: 1920x1080 (Full HD)  
  - フレームレート: 60fps  
  - エンコーダ: H.264 (libx264)  
  - 音声コーデック: AAC (128kbps)  
  - エンコード完了後に元ファイル (`input/*.mp4`) は自動削除

- **2pass エンコード**  
  高品質な 2pass 方式により、ビットレート効率の良い動画を生成します。

## 動作環境

- **OS**: Ubuntu 等、`inotify-tools` が利用可能な Linux
- **必須パッケージ**: `ffmpeg`, `ffprobe`, `inotify-tools`

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg inotify-tools
```
