<p align="center">
  <h1 align="center">multi-repo-agent (mra)</h1>
  <p align="center">
    <strong>AI駆動の複数リポジトリ開発 -- 1つのターミナルから。</strong>
  </p>
  <p align="center">
    <a href="../README.md">English</a> |
    <a href="./README.zh-TW.md">繁體中文</a> |
    <strong>日本語</strong> |
    <a href="./README.ko.md">한국어</a>
  </p>
</p>

---

> リポジトリAのAPIを変更すると、mraが自動的にリポジトリB、C、Dのすべての下流コンシューマーを検出し、影響を分析し、コードを更新し、PRを作成します。すべて1つのコマンドで。

**v2.2.0** | 28 CLIコマンド | 6 AIエージェント | 9 MCPツール | 20テストスイート

---

## なぜmraなのか？

現代のソフトウェアは複数のリポジトリにまたがっています。1つのAPI変更が3つのフロントエンドを静かに壊す可能性があります。Claude Codeは一度に1つのディレクトリしか参照できません。

**mraはそのギャップを埋めます。**

| mraなし | mraあり |
|---|---|
| どのリポジトリがAPIを使用しているか手動で確認 | `mra scan` がクロスリポジトリの依存関係を自動検出 |
| リポジトリごとに別々のClaudeセッションを開く | `mra my-api --with-deps` で関連リポジトリをすべて読み込み |
| レビュアーが破壊的変更を見つけることを期待 | `mra review --pr 123` が `consumer:42` がまだ古いフィールドを参照していることを発見 |
| セッションごとにプロジェクトコンテキストを再説明 | PKBがプロジェクト知識をキャッシュ -- エージェントが約50トークンで起動 |
| レビューの品質を推測 | `mra eval-review` が人間のレビューに対する精度/再現率を測定 |

---

## クイックスタート

```bash
# インストール
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc

# ワークスペースの初期化
mra init ~/workspace --git-org git@github.com:my-org

# セットアップの確認
mra doctor

# 複数リポジトリでの開発を開始
mra my-api --with-deps
```

---

## 主要機能

### 1. クロスリポジトリオーケストレーション (Cross-Repo Orchestration)

複数のリポジトリとその依存関係を完全に把握した状態でClaudeを起動します。

```bash
mra my-api --with-deps       # my-api + すべてのコンシューマー/依存関係を読み込み
mra my-api frontend-app      # 特定のリポジトリをまとめて読み込み
mra --all                    # すべてを読み込み
```

オーケストレーターはリポジトリごとにサブエージェントを配置し、依存順序に従って変更を調整し、各コミット後にコードレビューを実行します。

### 2. ディベートによるAIコードレビュー (AI Code Review with Debate)

差分サイズによって自動選択される3つのレビュー戦略：

| 戦略 | 条件 | 方法 |
|----------|------|-----|
| **ライト (Light)** | 50行未満、3ファイル以下 | シングルパス、2ターン（約15秒） |
| **スタンダード (Standard)** | 300行未満 | シングルパス、3ターン（約30秒） |
| **ディベート (Debate)** | 大規模な差分またはAPI変更 | 2人のアナリスト + 投票 + 統合（約3分） |

```bash
mra review my-api              # ターミナル出力（戦略を自動選択）
mra review my-api --pr 123     # GitHub PRにインラインコメントを投稿
mra review my-api --strategy debate  # 徹底的なレビューを強制
```

**ディベートモード (Debate mode)** は敵対的マルチエージェントレビューを使用します：

```
ラウンド1: 2つのエージェントが独立してコードベースを検索
  エージェントA (影響分析) → 壊れた参照、デッドコード、API破壊
  エージェントB (品質監査) → セキュリティ、パターン、型安全性

ラウンド2: メールボックス投票
  すべての発見を統合 → 各エージェントが証拠付きでKEEP/DROPを投票
  → 証拠に裏付けられた発見のみが残る

最終: シンセサイザーが構造化されたインラインレビューを生成
```

すべてのレビューエージェントは**書き込み保護** (`--disallowedTools "Write,Edit"`) されており、読み取り専用です。

### 3. プロジェクト知識ベース (Project Knowledge Base / PKB)

セッションごとにコードベース全体を再読み込みする代わりに、PKBがプロジェクト知識を再利用可能なドキュメントに蒸留します。

```bash
mra analyze my-api    # 初回のみ: 4つのエージェントが並行してプロジェクトをスキャン
```

生成されるドキュメント：

| ドキュメント | 内容 |
|----------|---------|
| `identity.md` | プロジェクト名、種類、一行の目的（約50トークン） |
| `sitemap.md` | ファイルツリー + モジュール目的インデックス |
| `architecture.md` | パターン、データフロー、技術スタック |
| `conventions.md` | `[CONVENTION]`/`[PATTERN]`/`[DECISION]` タグ付きコーディングスタイル |
| `api-surface.md` | エンドポイント、エクスポート、イベントコントラクト |
| `tunnels.md` | クロスモジュールエンティティ参照（自動検出） |
| `modules/*.md` | モジュールごとの詳細サマリー |

**4層メモリスタック** ([mempalace](https://github.com/milla-jovovich/mempalace) にインスパイア)：

| レイヤー | 内容 | トークン | 読み込みタイミング |
|-------|---------|--------|-------------|
| L0: アイデンティティ | 名前 + 種類 + 目的 | 約50 | 常時 |
| L1: エッセンシャル | タグ付き規約 + パターン | 約200 | 常時 |
| L2: ルームリコール | サイトマップ + アーキテクチャ + 関連モジュール | 約500 | レビュー/質問時 |
| L3: ディープサーチ | 完全なAPIサーフェス + 全モジュール | 約800以上 | オーケストレーター起動時 |

**結果**: レビュー起動コストが約150Kトークンから約250トークンに削減。

PKBは各レビュー後に自動更新（バックグラウンド、非ブロッキング）され、**mtime検出**を使用して未変更モジュールをスキップします。

### 4. クロスリポジトリ依存関係検出 (Cross-Repo Dependency Detection)

5つの組み込みスキャナー + カスタムプラグイン：

| スキャナー | 検出対象 | 信頼度 |
|---------|---------|------------|
| `docker-compose` | サービス間の関係 | 高 |
| `shared-db` | データベースを共有するプロジェクト | 高 |
| `gateway-routes` | APIゲートウェイルーティング | 中 |
| `shared-packages` | 内部npm/gemパッケージ | 高 |
| `api-calls` | 環境変数APIホスト参照 | 低 |

```bash
mra scan                 # 依存関係を自動検出
mra deps my-api          # 依存関係ツリーを表示
mra graph --mermaid      # 依存関係グラフを可視化
```

### 5. レビュー品質評価 (Review Quality Evaluation)

人間のレビュアーに対するレビュー精度を測定：

```bash
mra eval-review my-api --pr 123
```

同じPRに対するMRAの発見と人間のレビューを比較：
- **精度 (Precision)** -- MRAの発見のうち実際の問題はどれくらいか？
- **再現率 (Recall)** -- 人間の発見のうちMRAはどれくらい検出したか？
- **F1スコア (F1 Score)** -- バランスの取れた品質指標

レポートは `.collab/eval/` に保存され、傾向を追跡できます。

### 6. Docker環境とテスト (Docker Environments & Testing)

```bash
mra db setup                     # DBコンテナを起動 + ダンプをインポート
mra test my-api                  # テスト戦略を自動検出
mra test my-api --integration    # 完全な統合テスト
mra watch my-api                 # ファイル変更時に自動テスト
```

---

## チュートリアル

### 初回セットアップ

<details>
<summary><strong>ステップバイステップのワークスペース初期化</strong></summary>

#### 1. 前提条件

| ツール | インストール |
|------|---------|
| `git` | macOSにプリインストール |
| `docker` | [Docker Desktop](https://docker.com) または [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` のあと `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

オプション: `yq` (`brew install yq`), `fswatch` (`brew install fswatch`)

#### 2. ワークスペースの初期化

```bash
gh auth login                    # 必要に応じて組織アカウントに切り替え
mra init ~/workspace --git-org git@github.com:my-org
```

リポジトリのクローン、docker-composeファイルのスキャン、依存関係の検出、ワークスペースエイリアスの作成を行います。

#### 3. データベースのセットアップ

```bash
mkdir -p ~/workspace/dumps
cp /path/to/myapp_db.sql.bz2 ~/workspace/dumps/
mra db setup
```

db.jsonのフォーマット:

```json
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "5.7",
      "platform": "linux/amd64",
      "port": 3306,
      "password": "123456",
      "schemas": {
        "myapp_db": {
          "source": "./dumps/myapp_db.sql.bz2",
          "usedBy": ["my-api", "backend-api"]
        }
      }
    }
  }
}
```

対応フォーマット: `.sql`, `.sql.gz`, `.sql.bz2`, `.sql.xz`, `.sql.zst`, `.dump` | エンジン: `mysql`, `postgres`

#### 4. 確認とスナップショット

```bash
mra doctor                       # ヘルスチェック
mra snapshot "initial-setup"     # 安全なチェックポイント
```

</details>

### 日常の開発

<details>
<summary><strong>一般的なワークフローとコマンド</strong></summary>

```bash
# 朝の確認
mra status                       # 全プロジェクト概要
mra diff                         # 未コミット/未プッシュの変更
mra dashboard                    # インタラクティブTUI

# クロスプロジェクト開発
mra my-api --with-deps           # オーケストレーターを起動
# Claudeにタスクを指示:
# > "order APIをitemsではなくdataを返すように変更し、コンシューマーを同期"

# クイッククエリ（インタラクティブセッションなし）
mra ask my-api "list all order-related API endpoints"
mra ask my-api --with-deps "API dependencies between my-api and frontend"

# コード品質
mra lint frontend-app            # BLOCKERルールをチェック
mra lint --all                   # すべてのフロントエンドプロジェクト

# プッシュ前
mra snapshot "before-push"
mra review my-api --pr 123       # インラインPRレビュー

# 何か壊れた？
mra rollback my-api              # 最新のスナップショットに復元
```

</details>

### コードレビュー

<details>
<summary><strong>ローカルレビュー、PRインラインコメント、CI自動化</strong></summary>

```bash
# ローカルターミナルレビュー
mra review my-api                         # 戦略を自動選択
mra review my-api --base development      # 特定のブランチに対して
mra review my-api --strategy debate       # 徹底的なレビューを強制

# GitHub PRインラインレビュー
mra review my-api --pr 123               # インラインコメントを投稿
mra review my-api --pr 123 --model opus  # より強力なモデルを使用

# 自動CIレビュー
mra ci my-api --with-review              # GitHub Actionsワークフローを生成
```

リポジトリのシークレットに `ANTHROPIC_API_KEY` を追加してください。ワークフローはすべてのPRでトリガーされ、インラインコメントを投稿し、以降のプッシュで更新されます。

**トークン最適化戦略:**
- PKB統合（コードベース全体ではなく知識ドキュメント）
- モデル階層化（投票にhaiku、分析にsonnet）
- フォーカスコンテキスト（変更ファイルのディレクトリのみ読み込み）
- 発見の圧縮（後のラウンドではサマリーのみ）

</details>

### プロジェクト知識ベース

<details>
<summary><strong>プロジェクト知識の生成、使用、メンテナンス</strong></summary>

```bash
# PKBの生成（初回の投資）
mra analyze my-api
mra analyze my-api --model haiku    # モジュールサマリーにはより安価

# PKBはすべてのコマンドで自動使用
mra review my-api --pr 123          # PKBコンテキストを使用
mra my-api --with-deps              # オーケストレーターが完全なPKBを取得
mra ask my-api "how does auth work?"  # スタンダード階層PKB
```

レビュー後、PKBは自動更新されます：
- 変更されたモジュールのサマリーが更新（バックグラウンド、haiku）
- 新しいファイルがサイトマップを更新
- CRITICAL/HIGHの発見が `[DECISION]` タグとしてconventions.mdに記録
- クロスモジュール参照のトンネルリンクが再生成

PKBが存在しない場合はコードベース全体の読み込みにフォールバックします。

</details>

### チームメンバーのオンボーディング

<details>
<summary><strong>新しいチームメンバーとワークスペース設定を共有</strong></summary>

`<workspace>/.collab/` から以下のファイルを共有：

| ファイル | 必須 |
|------|----------|
| `repos.json` | はい |
| `db.json` | はい |
| `manual-deps.json` | オプション |
| SQLダンプファイル | はい |

新メンバーの手順：

```bash
git clone <mra-repo> ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
gh auth login

mkdir -p ~/workspace/.collab ~/workspace/dumps
cp /from/teammate/repos.json ~/workspace/.collab/
cp /from/teammate/db.json ~/workspace/.collab/
cp /from/teammate/*.sql.bz2 ~/workspace/dumps/

mra init ~/workspace --git-org git@github.com:my-org
mra db setup
mra doctor
```

テンプレートの生成: `mra template`

</details>

---

## コマンドリファレンス

<details>
<summary><strong>全28コマンド</strong></summary>

### コア (Core)

| コマンド | 説明 |
|---------|-------------|
| `mra init <path> --git-org <url>` | ワークスペースの初期化 |
| `mra scan` | 依存関係の再スキャン |
| `mra deps [project]` | 依存関係グラフの表示 |
| `mra status` | ワークスペース概要 |
| `mra diff` | クロスリポジトリ差分サマリー |
| `mra log [project]` | 操作履歴 |

### AI & 開発 (AI & Development)

| コマンド | 説明 |
|---------|-------------|
| `mra <project...> [--with-deps]` | Claudeオーケストレーターの起動 |
| `mra ask <project> "<question>"` | コードベースへの質問 |
| `mra export [project]` | プロジェクトコンテキストのエクスポート |

### コードレビュー & 分析 (Code Review & Analysis)

| コマンド | 説明 |
|---------|-------------|
| `mra review <project> [--pr N] [--strategy S] [--base ref]` | コードレビュー |
| `mra analyze <project> [--model M]` | PKBの生成 |
| `mra eval-review <project> --pr N [--baseline file]` | レビュー品質の評価 |

### Docker & テスト (Docker & Testing)

| コマンド | 説明 |
|---------|-------------|
| `mra db setup\|status\|import` | データベース管理 |
| `mra test <project> [--integration\|--mock]` | テストの実行 |
| `mra setup <project\|--all>` | 依存関係のインストール |
| `mra watch <project>` | 変更時の自動テスト |

### 品質 & 安全性 (Quality & Safety)

| コマンド | 説明 |
|---------|-------------|
| `mra doctor` | ヘルスチェック |
| `mra lint <project\|--all>` | JS/TS BLOCKERルール |
| `mra cost [--reset]` | API使用量の追跡 |
| `mra snapshot [name]` | チェックポイントの作成 |
| `mra rollback <project> [name]` | スナップショットの復元 |

### CI/CD & コラボレーション (CI/CD & Collaboration)

| コマンド | 説明 |
|---------|-------------|
| `mra ci <project> [--with-review]` | GitHub Actionsの生成 |
| `mra federation publish\|subscribe\|verify` | チーム間コントラクト |
| `mra notify setup\|test` | Webhook通知 |

### ユーティリティ (Utilities)

| コマンド | 説明 |
|---------|-------------|
| `mra graph [--mermaid\|--dot]` | 依存関係の可視化 |
| `mra dashboard` | インタラクティブTUI |
| `mra open <project>` | IDEで開く |
| `mra config <key> <value>` | 設定 |
| `mra clean` | クリーンアップ |

</details>

---

## AIエージェントチーム

| エージェント | 役割 |
|-------|------|
| **オーケストレーター (Orchestrator)** | クロスプロジェクトの変更を調整し、サブエージェントを配置 |
| **PMエージェント (PM Agent)** | 要件分析、タスク分解 |
| **サブエージェント (Sub-Agent)** | コードの記述、テストの実行、プロジェクトごとのコミット |
| **コードレビュアー (Code Reviewer)** | 正確性、セキュリティ、API一貫性について差分をレビュー |
| **PRレビュアー (PR Reviewer)** | クロスプロジェクトコンテキストでPR全体をレビュー |
| **PKBアナライザー (PKB Analyzer)** | プロジェクトの深い分析、知識ドキュメントの生成 |

### ディベートレビューエージェント (Debate Review Agents)

| エージェント | モデル | 役割 |
|-------|-------|------|
| 影響アナリスト (Impact Analyst) | sonnet | 壊れた参照、デッドコードの検索 |
| 品質監査人 (Quality Auditor) | sonnet | パターン、セキュリティ、型安全性のチェック |
| 投票者A/B (Voter A/B) | haiku | 発見プールに対するKEEP/DROP投票 |
| シンセサイザー (Synthesizer) | sonnet | 残った発見をJSONに統合 |

すべてのレビューエージェントは**読み取り専用**です（書き込みツール無効）。

---

## アーキテクチャ

```
mra CLI (純粋なシェル、jq/git/docker/gh以外のランタイム依存なし)
  |
  +-- ワークスペースマネージャー (Workspace Manager)
  |     リポジトリ同期、依存関係スキャン（5つのスキャナー）、データベースセットアップ
  |
  +-- プロジェクト知識ベース (Project Knowledge Base / PKB)
  |     L0-L3メモリスタック、自動分類タグ、
  |     トンネルリンキング、mtimeベースの増分更新
  |
  +-- コードレビューエンジン (Code Review Engine)
  |     自動戦略選択、メールボックス投票ディベート、
  |     書き込み保護エージェント、モデル階層化、評価フレームワーク
  |
  +-- Claudeオーケストレーター (Claude Orchestrator)
  |     マルチリポジトリコンテキスト、PM/サブ/レビュアー配置、
  |     Dockerテスト実行、API変更検出
  |
  +-- インテグレーション (Integrations)
        MCPサーバー（9ツール）、GitHub Actions、Federation、Slack/Discord
```

---

## インテグレーション

<details>
<summary><strong>MCPサーバー、GitHub Actions、Federation、通知</strong></summary>

### MCPサーバー

```bash
cd ~/multi-repo-agent/mcp-server && npm install && npm run build
claude mcp add mra node ~/multi-repo-agent/mcp-server/dist/index.js
```

9ツール: `mra_status`, `mra_deps`, `mra_ask`, `mra_export`, `mra_diff`, `mra_doctor`, `mra_graph`, `mra_scan`, `mra_test`

### GitHub Actions

```bash
mra ci my-api --with-review    # CI + レビューワークフローを生成
```

### Federation

```bash
mra federation publish my-api              # APIコントラクトを公開
mra federation subscribe https://url.json  # サブスクライブ
mra federation verify                      # 互換性をチェック
```

### 通知 (Notifications)

```bash
mra notify setup    # Webhook設定を作成（Slack/Discord）
mra notify test     # テスト通知を送信
```

</details>

---

## 設定

<details>
<summary><strong>ワークスペースとグローバル設定</strong></summary>

すべてのワークスペース設定は `<workspace>/.collab/` にあります：

| ファイル | 用途 | 共有可能 |
|------|---------|-----------|
| `repos.json` | クローンするリポジトリ | はい |
| `db.json` | データベース設定 | はい |
| `dep-graph.json` | 自動生成された依存関係グラフ | いいえ |
| `manual-deps.json` | 手動の依存関係オーバーライド | はい |
| `notify.json` | Webhook設定 | はい |
| `eval/` | レビュー評価レポート | いいえ |

グローバル設定: `~/multi-repo-agent/config.json`

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "outputLanguage": "繁體中文台灣用語",
  "subAgentWorkflow": { "reviewLoopMax": 3, "autoCommit": true, "autoPR": true }
}
```

</details>

---

## ロードマップ

### 最近追加された機能

- 自動戦略レビュー（light/standard/debate）
- メールボックス投票ディベートシステム
- L0-L3メモリスタック付きプロジェクト知識ベース
- 自動分類タグ (`[CONVENTION]`/`[PATTERN]`/`[DECISION]`)
- クロスモジュールトンネルリンキング
- mtimeベースの増分PKB更新
- レビュー評価フレームワーク（precision/recall/F1）
- 書き込み保護レビューエージェント
- レビューからの意思決定自動キャプチャ

### 今後の予定

- Playwright E2Eテスト統合
- Webダッシュボード（ブラウザベースの依存関係グラフ）
- PKBセマンティック検索（エンベディングベースの検索）
- クロスリポジトリPKBリンキング（共有型コントラクト）
- 評価トレンドダッシュボード

---

## ライセンス

MIT
