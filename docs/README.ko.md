<p align="center">
  <h1 align="center">multi-repo-agent (mra)</h1>
  <p align="center">
    <strong>AI 기반 멀티 리포지토리 개발 -- 하나의 터미널에서.</strong>
  </p>
  <p align="center">
    <a href="../README.md">English</a> |
    <a href="./README.zh-TW.md">繁體中文</a> |
    <a href="./README.ja.md">日本語</a> |
    <strong>한국어</strong>
  </p>
</p>

---

> 리포지토리 A의 API를 변경하면, mra가 자동으로 리포지토리 B, C, D의 모든 다운스트림 소비자를 찾아 영향을 분석하고, 코드를 업데이트하고, PR을 생성합니다. 단 하나의 명령으로.

**v2.3.0** | 32 CLI 명령어 | 6 AI 에이전트 | 9 MCP 도구 | 35 테스트 스위트 | 10 TM 추적 보안 제어

---

## 왜 mra인가?

현대 소프트웨어는 여러 리포지토리에 걸쳐 있습니다. 하나의 API 변경이 세 개의 프런트엔드를 조용히 망가뜨릴 수 있습니다. Claude Code는 한 번에 하나의 디렉토리만 볼 수 있습니다.

**mra가 그 간극을 메워줍니다.**

| mra 없이 | mra와 함께 |
|---|---|
| 어떤 리포지토리가 API를 사용하는지 수동으로 확인 | `mra scan`이 크로스 리포지토리 의존성을 자동 감지 |
| 리포지토리마다 별도의 Claude 세션을 열기 | `mra my-api --with-deps`로 관련 리포지토리를 모두 로드 |
| 리뷰어가 파괴적 변경을 찾기를 기대 | `mra review --pr 123`이 `consumer:42`가 여전히 이전 필드를 참조하고 있음을 발견 |
| 세션마다 프로젝트 컨텍스트를 다시 설명 | PKB가 프로젝트 지식을 캐시 -- 에이전트가 약 50 토큰으로 시작 |
| 리뷰 품질을 추측 | `mra eval-review`가 사람 리뷰 대비 정밀도/재현율을 측정 |

---

## 빠른 시작

```bash
# 설치
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc

# 워크스페이스 초기화
mra init ~/workspace --git-org git@github.com:my-org

# 설정 확인
mra doctor

# 멀티 리포지토리 개발 시작
mra my-api --with-deps
```

---

## 주요 기능

### 1. 크로스 리포지토리 오케스트레이션 (Cross-Repo Orchestration)

여러 리포지토리와 그 의존성을 완전히 파악한 상태로 Claude를 실행합니다.

```bash
mra my-api --with-deps       # my-api + 모든 소비자/의존성 로드
mra my-api frontend-app      # 특정 리포지토리를 함께 로드
mra --all                    # 전체 로드
```

오케스트레이터는 리포지토리별로 서브 에이전트를 배치하고, 의존성 순서에 따라 변경을 조율하며, 각 커밋 후 코드 리뷰를 실행합니다.

### 1b. 브랜치 인식 동기화 & 크로스 리포지토리 PR (Branch-Aware Sync & Cross-Repo PRs)

여러 리포지토리를 동일한 기능 브랜치에 유지한 다음, 함께 출시합니다. 모든 명령어는 의존성 순서로 실행되며 일부 리포지토리만 대상으로 지정할 수 있습니다.

```bash
mra branch status                 # Repos needing attention (ahead/behind/dirty/PR state)
mra branch new feature/login      # Create the same branch across repos
mra branch pr                     # Push branches + open PRs (deps first)
mra branch merge --wait-ci        # Merge open PRs once CI is green
```

| 명령어 | 동작 |
|---------|--------------|
| `mra sync [--safe] [--push] [--review] [--json]` | 모든 리포지토리를 클론/풀합니다. `--safe`는 fast-forward 전용, `--push`는 푸시, `--review`는 자동 리뷰, `--json`은 리포지토리별 `{repo, action, ok}`를 출력 |
| `mra branch status [--all] [--fetch] [--json]` | 크로스 리포지토리 브랜치 개요 (기본: 주의가 필요한 리포지토리, `--json`: 모든 리포지토리) |
| `mra branch new\|switch <name>` | 모든 리포지토리에서 동일한 브랜치를 생성/전환 |
| `mra branch pr [--base <ref>] [--dry-run] [repos…]` | 기능 브랜치를 푸시하고 PR을 생성 (의존성 우선, 선택적 `[repos…]` 서브셋) |
| `mra branch merge [--strategy S] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [--dry-run] [repos…]` | mergeable + CI를 게이트로 하여 열린 PR을 병합. `--wait-ci`는 병합 전 CI를 폴링 |

`--json` (`sync`와 `branch status`에서)은 다른 도구로 파이핑하도록 설계되었습니다 -- 워커 로그는 stderr로 가므로 stdout은 유효한 JSON으로 유지됩니다.

### 2. 토론 기반 AI 코드 리뷰 (AI Code Review with Debate)

차이 크기에 따라 자동 선택되는 3가지 리뷰 전략:

| 전략 | 조건 | 방법 |
|----------|------|-----|
| **라이트 (Light)** | 50줄 미만, 3개 파일 이하 | 싱글 패스, 2턴 (약 15초) |
| **스탠다드 (Standard)** | 300줄 미만 | 싱글 패스, 3턴 (약 30초) |
| **디베이트 (Debate)** | 대규모 차이 또는 API 변경 | 2명의 분석가 + 투표 + 종합 (약 3분) |

```bash
mra review my-api              # 터미널 출력 (전략 자동 선택)
mra review my-api --pr 123     # GitHub PR에 인라인 코멘트 게시
mra review my-api --strategy debate  # 철저한 리뷰 강제
```

**디베이트 모드 (Debate mode)**는 적대적 멀티 에이전트 리뷰를 사용합니다:

```
라운드 1: 두 에이전트가 독립적으로 코드베이스를 검색
  에이전트 A (영향 분석) → 깨진 참조, 데드 코드, API 파괴
  에이전트 B (품질 감사) → 보안, 패턴, 타입 안전성

라운드 2: 메일박스 투표
  모든 발견 사항 통합 → 각 에이전트가 증거와 함께 KEEP/DROP 투표
  → 증거가 뒷받침되는 발견 사항만 생존

최종: 신시사이저가 구조화된 인라인 리뷰를 생성
```

모든 리뷰 에이전트는 **쓰기 보호** (`--disallowedTools "Write,Edit"`) 되어 있어 읽기 전용입니다.

### 2b. 페르소나 기반 리뷰 (Persona-Based Review, 옵트인)

일반적인 영향/품질 분석만으로 충분하지 않은 PR의 경우, 이름이 부여된 다섯 명의 도메인 전문가를 병렬로 실행합니다:

```bash
mra review my-api --personas          # Use 5 named domain experts
mra review my-api --pr 123 --personas # PR review with personas
```

| 페르소나 | 초점 |
|---------|-------|
| `security-auditor` | 시크릿, 인젝션, 인증, 역직렬화 (Troy Hunt 스타일) |
| `api-contract-guardian` | 크로스 리포지토리 시그니처 드리프트, 응답 형태 변경 |
| `performance-hawk` | N+1 쿼리, 핫 패스 I/O, 번들 비대화 (Vercel 스타일) |
| `refactoring-sage` | 코드 스멜, 네이밍, 응집도 (Martin Fowler 스타일) |
| `test-architect` | Kent Beck 11원칙 |

각 페르소나는 집중된 관점을 가지며 동일한 심각도 단계(CRITICAL/HIGH/MEDIUM)에 따라 작성합니다. 발견 사항은 디베이트 경로가 생성하는 것과 동일한 JSON으로 병합 및 종합되므로 -- PR 인라인 코멘트도 동일하게 작동합니다.

`agents/personas/`에 마크다운 파일을 추가하여 직접 페르소나를 만들 수 있습니다. `agents/personas/README.md`를 참고하세요.

### 3. 프로젝트 지식 베이스 (Project Knowledge Base / PKB)

세션마다 전체 코드베이스를 다시 읽는 대신, PKB가 프로젝트 지식을 재사용 가능한 문서로 증류합니다.

```bash
mra analyze my-api    # 최초 1회: 4개 에이전트가 병렬로 프로젝트를 스캔
```

생성되는 문서:

| 문서 | 내용 |
|----------|---------|
| `identity.md` | 프로젝트 이름, 유형, 한 줄 목적 (약 50 토큰) |
| `sitemap.md` | 파일 트리 + 모듈 목적 인덱스 |
| `architecture.md` | 패턴, 데이터 플로우, 기술 스택 |
| `conventions.md` | `[CONVENTION]`/`[PATTERN]`/`[DECISION]` 태그가 달린 코딩 스타일 |
| `api-surface.md` | 엔드포인트, 익스포트, 이벤트 컨트랙트 |
| `tunnels.md` | 크로스 모듈 엔티티 참조 (자동 감지) |
| `modules/*.md` | 모듈별 상세 요약 |

**4계층 메모리 스택** ([mempalace](https://github.com/milla-jovovich/mempalace)에서 영감):

| 계층 | 내용 | 토큰 | 로드 시점 |
|-------|---------|--------|-------------|
| L0: 아이덴티티 | 이름 + 유형 + 목적 | 약 50 | 항상 |
| L1: 에센셜 | 태그된 규칙 + 패턴 | 약 200 | 항상 |
| L2: 룸 리콜 | 사이트맵 + 아키텍처 + 관련 모듈 | 약 500 | 리뷰/질의 시 |
| L3: 딥 서치 | 전체 API 서피스 + 모든 모듈 | 약 800 이상 | 오케스트레이터 실행 시 |

**결과**: 리뷰 시작 비용이 약 150K 토큰에서 약 250 토큰으로 감소.

PKB는 각 리뷰 후 자동 업데이트(백그라운드, 비차단)되며, **mtime 감지**를 사용하여 변경되지 않은 모듈을 건너뜁니다.

### 4. 크로스 리포지토리 의존성 감지 (Cross-Repo Dependency Detection)

5개의 내장 스캐너 + 커스텀 플러그인:

| 스캐너 | 감지 대상 | 신뢰도 |
|---------|---------|------------|
| `docker-compose` | 서비스 간 관계 | 높음 |
| `shared-db` | 데이터베이스를 공유하는 프로젝트 | 높음 |
| `gateway-routes` | API 게이트웨이 라우팅 | 중간 |
| `shared-packages` | 내부 npm/gem 패키지 | 높음 |
| `api-calls` | 환경 변수 API 호스트 참조 | 낮음 |

```bash
mra scan                 # 의존성 자동 감지
mra deps my-api          # 의존성 트리 표시
mra graph --mermaid      # 의존성 그래프 시각화
```

### 5. 리뷰 품질 평가 (Review Quality Evaluation)

사람 리뷰어 대비 리뷰 정확도를 측정:

```bash
mra eval-review my-api --pr 123
```

동일 PR에 대한 MRA 발견 사항과 사람 리뷰를 비교:
- **정밀도 (Precision)** -- MRA 발견 사항 중 실제 문제는 몇 퍼센트인가?
- **재현율 (Recall)** -- 사람 발견 사항 중 MRA가 몇 퍼센트를 감지했는가?
- **F1 점수 (F1 Score)** -- 균형 잡힌 품질 지표

보고서는 `.collab/eval/`에 저장되어 추세를 추적할 수 있습니다.

### 6. Docker 환경 및 테스트 (Docker Environments & Testing)

```bash
mra db setup                     # DB 컨테이너 시작 + 덤프 임포트
mra test my-api                  # 테스트 전략 자동 감지
mra test my-api --integration    # 전체 통합 테스트
mra watch my-api                 # 파일 변경 시 자동 테스트
```

---

## 튜토리얼

### 초기 설정

<details>
<summary><strong>단계별 워크스페이스 초기화</strong></summary>

#### 1. 사전 요구 사항

| 도구 | 설치 |
|------|---------|
| `git` | macOS에 기본 설치 |
| `docker` | [Docker Desktop](https://docker.com) 또는 [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` 후 `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

선택 사항: `yq` (`brew install yq`), `fswatch` (`brew install fswatch`)

#### 2. 워크스페이스 초기화

```bash
gh auth login                    # 필요 시 조직 계정으로 전환
mra init ~/workspace --git-org git@github.com:my-org
```

리포지토리 클론, docker-compose 파일 스캔, 의존성 감지, 워크스페이스 별칭 생성을 수행합니다.

#### 3. 데이터베이스 설정

```bash
mkdir -p ~/workspace/dumps
cp /path/to/myapp_db.sql.bz2 ~/workspace/dumps/
mra db setup
```

db.json 형식:

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

지원 형식: `.sql`, `.sql.gz`, `.sql.bz2`, `.sql.xz`, `.sql.zst`, `.dump` | 엔진: `mysql`, `postgres`

#### 4. 확인 및 스냅샷

```bash
mra doctor                       # 상태 점검
mra snapshot "initial-setup"     # 안전 체크포인트
```

</details>

### 일상 개발

<details>
<summary><strong>일반적인 워크플로우와 명령어</strong></summary>

```bash
# 아침 점검
mra status                       # 전체 프로젝트 개요
mra diff                         # 미커밋/미푸시 변경 사항
mra dashboard                    # 인터랙티브 TUI

# 크로스 프로젝트 개발
mra my-api --with-deps           # 오케스트레이터 실행
# Claude에 작업 지시:
# > "order API를 data 대신 items를 반환하도록 수정하고, 소비자를 동기화"

# 빠른 질의 (인터랙티브 세션 없음)
mra ask my-api "list all order-related API endpoints"
mra ask my-api --with-deps "API dependencies between my-api and frontend"

# 리포지토리 간 동기화 & 기능 브랜치
mra sync --safe                  # Fast-forward pull every repo
mra branch status                # Which repos need attention
mra branch pr                    # Open PRs across repos (deps first)
mra branch merge --wait-ci       # Merge each PR once its CI is green

# 코드 품질
mra lint frontend-app            # BLOCKER 규칙 확인
mra lint --all                   # 모든 프런트엔드 프로젝트

# 푸시 전
mra snapshot "before-push"
mra review my-api --pr 123       # 인라인 PR 리뷰

# 문제가 생겼다면?
mra rollback my-api              # 최신 스냅샷으로 복원
```

#### 멀티 전문가 플래닝 (Multi-Expert Planning)

```bash
mra plan my-api "Migrate session tokens to JWT"
mra plan my-api "Migrate session tokens to JWT" --dual   # claude + codex council
```

다섯 명의 도메인 전문가가 독립적으로 구현 전략을 제안한 다음, 신시사이저가 이를 하나의 통합된 계획(통합된 파일 목록, 위험도 순으로 정렬된 우려 사항, 실행 단계)으로 병합합니다. 출력은 stdout으로 가므로 파일로 파이핑하여 저장할 수 있습니다.

`--dual`을 사용하면 각 페르소나가 `claude`와 `codex` CLI **양쪽**으로 실행되며, 신시사이저가 두 모델의 제안을 조정합니다(합의된 부분은 강조하고, 의견이 다른 부분은 드러냅니다). `PATH`에 `codex` CLI가 필요합니다.

#### 테스트 품질 감사 (Test Quality Audit)

```bash
mra test-audit frontend-app        # Kent Beck 11-principles audit of all test files
MRA_AUDIT_PARALLEL=3 mra test-audit frontend-app  # Cap concurrent audits
```

`*.test.*`, `*_test.*`, `*.spec.*` 파일을 (`node_modules`, `dist`, `build`, `vendor`, `.git` 제외) 발견하여, `test-architect` 페르소나를 통해 각 파일을 Kent Beck의 11가지 테스트 원칙에 대해 감사합니다.

</details>

### 코드 리뷰

<details>
<summary><strong>로컬 리뷰, PR 인라인 코멘트, CI 자동화</strong></summary>

```bash
# 로컬 터미널 리뷰
mra review my-api                         # 전략 자동 선택
mra review my-api --base development      # 특정 브랜치에 대해
mra review my-api --strategy debate       # 철저한 리뷰 강제

# GitHub PR 인라인 리뷰
mra review my-api --pr 123               # 인라인 코멘트 게시
mra review my-api --pr 123 --model opus  # 더 강력한 모델 사용

# 자동 CI 리뷰
mra ci my-api --with-review              # GitHub Actions 워크플로우 생성
```

리포지토리 시크릿에 `ANTHROPIC_API_KEY`를 추가하세요. 워크플로우는 모든 PR에서 트리거되어 인라인 코멘트를 게시하고, 이후 푸시에서 업데이트됩니다.

**토큰 최적화 전략:**
- PKB 통합 (전체 코드베이스 대신 지식 문서)
- 모델 계층화 (투표에 haiku, 분석에 sonnet)
- 포커스 컨텍스트 (변경된 파일의 디렉토리만 로드)
- 발견 사항 압축 (후반 라운드에서는 요약만)

</details>

### 프로젝트 지식 베이스

<details>
<summary><strong>프로젝트 지식 생성, 사용, 유지 관리</strong></summary>

```bash
# PKB 생성 (최초 투자)
mra analyze my-api
mra analyze my-api --model haiku    # 모듈 요약에는 더 저렴하게

# PKB는 모든 명령어에서 자동 사용
mra review my-api --pr 123          # PKB 컨텍스트 사용
mra my-api --with-deps              # 오케스트레이터가 전체 PKB 획득
mra ask my-api "how does auth work?"  # 스탠다드 계층 PKB
```

리뷰 후 PKB가 자동 업데이트됩니다:
- 변경된 모듈의 요약이 업데이트 (백그라운드, haiku)
- 새 파일이 사이트맵을 업데이트
- CRITICAL/HIGH 발견 사항이 `[DECISION]` 태그로 conventions.md에 기록
- 크로스 모듈 참조의 터널 링크가 재생성

PKB가 없는 경우 전체 코드베이스 로딩으로 폴백합니다.

</details>

### 팀원 온보딩

<details>
<summary><strong>새 팀원과 워크스페이스 설정 공유</strong></summary>

`<workspace>/.collab/`에서 다음 파일을 공유:

| 파일 | 필수 |
|------|----------|
| `repos.json` | 예 |
| `db.json` | 예 |
| `manual-deps.json` | 선택 사항 |
| SQL 덤프 파일 | 예 |

새 멤버 절차:

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

템플릿 생성: `mra template`

</details>

---

## 명령어 레퍼런스

<details>
<summary><strong>전체 명령어</strong></summary>

### 코어 (Core)

| 명령어 | 설명 |
|---------|-------------|
| `mra init <path> --git-org <url>` | 워크스페이스 초기화 |
| `mra scan` | 의존성 재스캔 |
| `mra deps [project]` | 의존성 그래프 표시 |
| `mra status` | 워크스페이스 개요 |
| `mra diff` | 크로스 리포지토리 차이 요약 |
| `mra log [project]` | 작업 이력 |

### 브랜치 & 동기화 (Branch & Sync)

| 명령어 | 설명 |
|---------|-------------|
| `mra sync [--safe] [--push] [--review] [--json]` | 모든 리포지토리 클론/풀 (`--json`: 리포지토리별 `{repo, action, ok}`) |
| `mra branch status [--all] [--fetch] [--json]` | 크로스 리포지토리 브랜치 개요 |
| `mra branch new\|switch <name>` | 모든 리포지토리에서 동일한 브랜치 생성/전환 |
| `mra branch pr [--base <ref>] [--dry-run] [repos…]` | 브랜치를 푸시하고 PR 생성 (의존성 우선, 선택적 서브셋) |
| `mra branch merge [--strategy S] [--delete-branch] [--wait-ci] [--ci-timeout <sec>] [--dry-run] [repos…]` | 열린 PR 병합 (mergeable + CI 게이트) |

### AI & 개발 (AI & Development)

| 명령어 | 설명 |
|---------|-------------|
| `mra <project...> [--with-deps]` | Claude 오케스트레이터 실행 |
| `mra ask <project> "<question>"` | 코드베이스 질의 |
| `mra export [project]` | 프로젝트 컨텍스트 익스포트 |

### 코드 리뷰 & 분석 (Code Review & Analysis)

| 명령어 | 설명 |
|---------|-------------|
| `mra review <project> [--pr N] [--strategy S] [--base ref] [--personas]` | 코드 리뷰 (--personas로 이름이 부여된 5명의 전문가 추가) |
| `mra plan <project> "<task>" [--model M] [--dual]` | 멀티 전문가 계획 (`--dual`: claude + codex council) |
| `mra test-audit <project> [--model M]` | Kent Beck 11원칙 테스트 감사 |
| `mra analyze <project> [--model M]` | PKB 생성 |
| `mra eval-review <project> --pr N [--baseline file]` | 리뷰 품질 평가 |

### Docker & 테스트 (Docker & Testing)

| 명령어 | 설명 |
|---------|-------------|
| `mra db setup\|status\|import` | 데이터베이스 관리 |
| `mra test <project> [--integration\|--mock]` | 테스트 실행 |
| `mra setup <project\|--all>` | 의존성 설치 |
| `mra watch <project>` | 변경 시 자동 테스트 |

### 품질 & 안전 (Quality & Safety)

| 명령어 | 설명 |
|---------|-------------|
| `mra doctor` | 상태 점검 |
| `mra lint <project\|--all>` | JS/TS BLOCKER 규칙 |
| `mra cost [--reset]` | API 사용량 추적 |
| `mra snapshot [name]` | 체크포인트 생성 |
| `mra snapshots` | 스냅샷 목록 조회 |
| `mra rollback <project> [name]` | 스냅샷 복원 |
| `mra trust <project>` | 프로젝트에 Docker 신뢰 부여 |

### CI/CD & 협업 (CI/CD & Collaboration)

| 명령어 | 설명 |
|---------|-------------|
| `mra ci <project> [--with-review]` | GitHub Actions 생성 |
| `mra federation publish\|subscribe\|verify` | 팀 간 컨트랙트 |
| `mra notify setup\|test` | Webhook 알림 |

### 유틸리티 (Utilities)

| 명령어 | 설명 |
|---------|-------------|
| `mra graph [--mermaid\|--dot]` | 의존성 시각화 |
| `mra dashboard` | 인터랙티브 TUI |
| `mra open <project>` | IDE에서 열기 |
| `mra config <key> <value>` | 설정 |
| `mra alias <name> <path>` | 워크스페이스 별칭 |
| `mra template [repos\|db\|deps\|all]` | 설정 템플릿 생성 |
| `mra clean` | 정리 |

</details>

---

## AI 에이전트 팀

| 에이전트 | 역할 |
|-------|------|
| **오케스트레이터 (Orchestrator)** | 크로스 프로젝트 변경을 조율하고 서브 에이전트를 배치 |
| **PM 에이전트 (PM Agent)** | 요구 사항 분석, 작업 분해 |
| **서브 에이전트 (Sub-Agent)** | 코드 작성, 테스트 실행, 프로젝트별 커밋 |
| **코드 리뷰어 (Code Reviewer)** | 정확성, 보안, API 일관성에 대한 차이 리뷰 |
| **PR 리뷰어 (PR Reviewer)** | 크로스 프로젝트 컨텍스트로 전체 PR 리뷰 |
| **PKB 분석기 (PKB Analyzer)** | 프로젝트 심층 분석, 지식 문서 생성 |

### 디베이트 리뷰 에이전트 (Debate Review Agents)

| 에이전트 | 모델 | 역할 |
|-------|-------|------|
| 영향 분석가 (Impact Analyst) | sonnet | 깨진 참조, 데드 코드 검색 |
| 품질 감사인 (Quality Auditor) | sonnet | 패턴, 보안, 타입 안전성 점검 |
| 투표자 A/B (Voter A/B) | haiku | 발견 사항 풀에 대한 KEEP/DROP 투표 |
| 신시사이저 (Synthesizer) | sonnet | 생존한 발견 사항을 JSON으로 병합 |

모든 리뷰 에이전트는 **읽기 전용**입니다 (쓰기 도구 비활성화).

---

## 아키텍처

```
mra CLI (순수 셸, jq/git/docker/gh 외 런타임 의존성 없음)
  |
  +-- 워크스페이스 매니저 (Workspace Manager)
  |     리포지토리 동기화, 의존성 스캔 (5개 스캐너), 데이터베이스 설정
  |
  +-- 프로젝트 지식 베이스 (Project Knowledge Base / PKB)
  |     L0-L3 메모리 스택, 자동 분류 태그,
  |     터널 링킹, mtime 기반 증분 업데이트
  |
  +-- 코드 리뷰 엔진 (Code Review Engine)
  |     자동 전략 선택, 메일박스 투표 디베이트,
  |     쓰기 보호 에이전트, 모델 계층화, 평가 프레임워크
  |
  +-- Claude 오케스트레이터 (Claude Orchestrator)
  |     멀티 리포지토리 컨텍스트, PM/서브/리뷰어 배치,
  |     Docker 테스트 실행, API 변경 감지
  |
  +-- 통합 (Integrations)
        MCP 서버 (9개 도구), GitHub Actions, Federation, Slack/Discord
```

---

## 통합

<details>
<summary><strong>MCP 서버, GitHub Actions, Federation, 알림</strong></summary>

### MCP 서버

```bash
cd ~/multi-repo-agent/mcp-server && npm install && npm run build
claude mcp add mra node ~/multi-repo-agent/mcp-server/dist/index.js
```

9개 도구: `mra_status`, `mra_deps`, `mra_ask`, `mra_export`, `mra_diff`, `mra_doctor`, `mra_graph`, `mra_scan`, `mra_test`

**워크스페이스 접근 제한 (공유 머신에서 강력 권장):**

```bash
# MCP 서버를 특정 워크스페이스 루트로 고정. 목록 외 경로는 거부됩니다.
export MRA_ALLOWED_WORKSPACES="$HOME/workspace:$HOME/sandbox"
```

설정하지 않으면 모든 경로가 허용됩니다 (open mode). 서버는 시작 시 명시적인 잠금을 권유하는 경고를 출력합니다.

### GitHub Actions

```bash
mra ci my-api --with-review    # CI + 리뷰 워크플로우 생성
```

### Federation

```bash
mra federation publish my-api              # API 컨트랙트 퍼블리시
mra federation subscribe https://url.json  # 구독
mra federation verify                      # 호환성 확인
```

### 알림 (Notifications)

```bash
mra notify setup    # Webhook 설정 생성 (Slack/Discord)
mra notify test     # 테스트 알림 전송
```

</details>

---

## 설정

<details>
<summary><strong>워크스페이스 및 전역 설정</strong></summary>

모든 워크스페이스 설정은 `<workspace>/.collab/`에 위치합니다:

| 파일 | 용도 | 공유 가능 |
|------|---------|-----------|
| `repos.json` | 클론할 리포지토리 | 예 |
| `db.json` | 데이터베이스 설정 | 예 |
| `dep-graph.json` | 자동 생성된 의존성 그래프 | 아니오 |
| `manual-deps.json` | 수동 의존성 오버라이드 | 예 |
| `lint-profile.json` | lint 규칙 세트 선택 (`{"profile":"ts-strict"}` 또는 인라인 `rules`) | 예 |
| `notify.json` | Webhook 설정 | 예 |
| `eval/` | 리뷰 평가 보고서 | 아니오 |

`repos.json`、`db.json`、`dep-graph.json`、`manual-deps.json` 및 scanner JSONL 레코드의 JSON Schema는 [`schemas/`](../schemas/)에 포함되어 있습니다. `.collab/*.json` 최상단에 `"$schema"`를 추가하면 IDE 내에서 실시간 검증이 가능합니다. `mra doctor`는 구조 검사를 자동 실행합니다.

> **⚠ 마이그레이션 안내 (lint 기본값 변경)**: 이전 버전은 `lib/lint.sh`에 기본 제공 BLOCKER 규칙이 하드코딩되어 있었습니다. 이제 lint는 profile 기반이며 기본 profile은 비어 있습니다. 이전 동작을 유지하려면 워크스페이스에 한 줄 파일을 추가하세요:
> ```bash
> echo '{"profile":"ts-strict"}' > <workspace>/.collab/lint-profile.json
> ```

**Lint Profiles**는 [`templates/lint-profiles/`](../templates/lint-profiles/)에 포함되어 있습니다:

| Profile | 용도 |
|---------|------|
| `default` | 규칙 없음 — lint가 조용히 통과 |
| `ts-strict` | 엄격한 TypeScript BLOCKER 규칙 (no-interface / no-enum / no-any / no-non-null / no-var) |

`<workspace>/.collab/lint-profile.json`로 활성화:

```json
{ "profile": "ts-strict" }
```

또는 사용자 정의 규칙을 인라인으로 작성 (각 규칙은 `id`、`severity`、`pattern`、`message`、`line_excludes`、`file_excludes` 포함):

```json
{ "rules": [{ "id": "no-todo", "severity": "warn", "pattern": "TODO", "message": "코드에 TODO 남음", "line_excludes": [], "file_excludes": [] }] }
```

전역 설정: `~/multi-repo-agent/config.json`

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

## 로드맵

### 최근 추가된 기능

- 브랜치 인식 동기화 & 크로스 리포지토리 PR (`mra sync`, `mra branch status|new|switch|pr|merge`)
- CI 폴링 자동 병합 (`branch merge --wait-ci [--ci-timeout]`)
- `branch pr|merge`의 리포지토리별 서브셋 지정 (`[repos…]`)
- 머신 판독 가능한 JSON 출력 (`sync --json`, `branch status --json`)
- 멀티 모델 플래닝 카운슬 (`mra plan --dual` -- claude + codex)
- 자동 전략 리뷰 (light/standard/debate)
- 메일박스 투표 디베이트 시스템
- L0-L3 메모리 스택을 갖춘 프로젝트 지식 베이스
- 자동 분류 태그 (`[CONVENTION]`/`[PATTERN]`/`[DECISION]`)
- 크로스 모듈 터널 링킹
- mtime 기반 증분 PKB 업데이트
- 리뷰 평가 프레임워크 (precision/recall/F1)
- 쓰기 보호 리뷰 에이전트
- 리뷰에서의 의사결정 자동 캡처

### 향후 계획

- Playwright E2E 테스트 통합
- 웹 대시보드 (브라우저 기반 의존성 그래프)
- PKB 시맨틱 검색 (임베딩 기반 검색)
- 크로스 리포지토리 PKB 링킹 (공유 타입 컨트랙트)
- 평가 추세 대시보드

---

## 개발

```bash
make test         # tests/ 하의 모든 shell 테스트 + mcp-server node 테스트 실행
make build        # mcp-server를 tsc로 빌드 (incremental)
make lint         # lib/、bin/、scanners/、tests/、test.sh에 shellcheck 실행
make clean        # mcp-server 빌드 산출물 제거
```

`bash test.sh`와 `make test`는 동일한 진입점이며, CI에서도 이를 실행합니다 (`.github/workflows/repo-tests.yml`).

---

## 라이선스

MIT
