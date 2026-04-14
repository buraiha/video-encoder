# video-encoder

TSファイルを 720p または 1080p の mp4 に変換するための、cron 前提のバッチ式エンコーダです。

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

## 使い方

### 720p に変換したい場合

inbox-720p に .ts ファイルを置きます。

### 1080p に変換したい場合

inbox-1080p に .ts ファイルを置きます。

### 一回だけ処理する

```bash
./bin/watch-and-encode.sh
```

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