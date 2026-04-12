# video-encoder (Podman + FFmpeg)

TSファイルをPodman上のFFmpegでmp4に変換するための最小手順。

## 前提

* Podmanが使えること
* このリポジトリ配下に `in/`, `out/` ディレクトリがあること

## ディレクトリ構成

```text
video-encoder/
├── Dockerfile
├── build.sh
├── ffenc-720.sh
├── ffenc-1080.sh
├── in/
└── out/
```

## 1. ビルド

```bash
cd ~/video-encoder
./build.sh
```

## 2. 入力配置

```bash
cp /path/to/file.ts ~/video-encoder/in/
```

## 3. 実行

`in/` に入っている通常ファイルを上から順番にまとめて処理する。

### 720p

```bash
./ffenc-720.sh
```

### 1080p

```bash
./ffenc-1080.sh
```

## 4. 出力

```text
out/
├── file_720p.mp4
└── file_1080p.mp4
```

## 補足

* 入力は `in/`、出力は `out/` を使用
* 失敗時は `podman run` の標準出力/標準エラーを確認
