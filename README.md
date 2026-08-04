# video-encoder

TSファイルを 720p または 1080p の mp4 に変換するための、cron 前提のバッチ式エンコーダです。
ローカル実行にも対応していますが、Podman コンテナ内での定期実行を推奨する構成です。

## ディレクトリ構成

```text
video-encoder/
├── bin/
│   ├── encode-one.sh
│   └── watch-and-encode.sh
├── inbox-720p/
├── inbox-1080p/
├── working/
├── out/
│   ├── 720p/
│   └── 1080p/
├── done/
│   ├── 720p/
│   └── 1080p/
├── failed/
│   ├── 720p/
│   └── 1080p/
└── logs/
```

## 前提コマンド

- ffmpeg
- nice
- ionice
- find

watch-and-encode.sh は常駐監視ではなく、一回だけキューを処理して終了します。
cron から定期実行する想定です。

## 環境構築

### ローカル実行する場合

以下のコマンドが使える状態にします。

- bash
- ffmpeg
- nice
- ionice
- find
- cron

macOS では ionice は標準では入っていないため、そのままでは encode-one.sh を実行できません。
このリポジトリは Podman でのコンテナ実行を推奨します。

### コンテナ実行する場合

以下を事前に用意します。

- Podman
- podman compose

Docker Engine と docker compose 互換でも動作する想定ですが、以降の例は Podman を基準にしています。

初回セットアップ手順は以下です。

1. このリポジトリを配置する
2. 必要に応じて inbox-720p と inbox-1080p に投入する .ts ファイルを準備する
3. コンテナをビルドして起動する

```bash
podman compose up -d --build
```

1. ログを確認する

```bash
podman compose logs -f
```

1. 停止するときは以下を実行する

```bash
podman compose down
```

## コンテナ実行

コンテナイメージには ffmpeg と cron が入っており、コンテナ起動後は cron が前面実行されます。
日常運用は Podman を想定しています。
Podman の bind mount で実行ビットが素直に扱えない環境を考慮し、コンテナ内ではシェルスクリプトを bash 経由で起動します。

### 起動

```bash
podman compose up -d --build
```

### 停止

```bash
podman compose down
```

### 主な環境変数

- TZ: タイムゾーン。既定値は Asia/Tokyo
- CRON_SCHEDULE: cron 書式の実行間隔。既定値は毎分
- RUN_ON_STARTUP: 1 にするとコンテナ起動時に一度だけ即時実行

### ログ確認

```bash
podman compose logs -f
```

ホスト側の logs/ にも各処理ログが残ります。

### Docker 互換で使う場合

Podman の代わりに docker compose を使っても構いません。
その場合は上記コマンドの podman を docker に読み替えてください。

## 使い方

### 720p に変換したい場合

inbox-720p に .ts ファイルを置きます。

### 1080p に変換したい場合

inbox-1080p に .ts ファイルを置きます。

### 一回だけ処理する

```bash
./bin/watch-and-encode.sh
```

cron 管理中のコンテナが動いている間は、同じコンテナ内で手動実行しないでください。
通常運用では cron に任せ、検証時だけ単発実行に切り替える前提です。

この実行で以下を順番に行います。

1. 前回実行時点から inbox 内のファイル増減をログへ記録
2. working に残っている途中ファイルを再処理
3. inbox-720p と inbox-1080p の .ts を一件ずつ直列処理
4. キューが空になったら終了

## 出力先

- 成功した mp4 は out/720p または out/1080p
- 元の .ts は成功時に done/720p または done/1080p
- 失敗した元ファイルは failed/720p または failed/1080p
- ログは logs/

## cron 例

1 分ごとに処理する例です。

```cron
* * * * * cd /Users/takashi/my_development/video-encoder && ./bin/watch-and-encode.sh >> /Users/takashi/my_development/video-encoder/logs/cron.log 2>&1
```

同時起動を避けるため、watch-and-encode.sh にはロック処理が入っています。
前回実行がまだ動いている間に cron が再度起動しても、重複実行はせず終了します。

コンテナ版では、この cron 実行が Podman コンテナ内で行われます。
