# HSK 단어 서랍

급수·교재별 서랍에 중국어 단어를 담고, 계정마다 진도를 따로 쌓는 암기 앱입니다.
화면은 두 가지입니다.

- **카드 화면 (iOS 스타일)**: 하루치(기본 30개) 단어를 좌우로 넘기며 봅니다. 위로 올리면 *외움*, 아래로 내리면 *헷갈림*으로 체크되고 카드는 그대로 있습니다.
- **ERP 화면**: 오른쪽 위 `ERP` 버튼. 같은 서랍·진도를 사내 ERP 조회 화면 형태의 표로 봅니다.

## 파일

| 파일 | 내용 |
|---|---|
| `index.html` | 앱 전체 (한 파일) |
| `config.js` | Supabase 연결 설정. 비워 두면 로컬 모드 |
| `supabase/schema.sql` | 테이블과 보안 함수 |
| `supabase/seed.sql` | 기본 서랍 4개, HSK 4급 494개·실전모의고사 388개 단어, 관리자 계정 |

## 1. GitHub Pages 켜기

1. 이 저장소의 **Settings → Pages**
2. *Build and deployment*에서 Source를 **Deploy from a branch**, Branch를 **main / (root)** 로 저장
3. 1~2분 뒤 `https://<아이디>.github.io/<저장소>/` 주소가 생깁니다

이 상태로는 **로컬 모드**입니다. 계정·서랍·진도가 그 브라우저에만 저장됩니다.

## 2. Supabase 연결 (어느 기기에서든 같은 진도)

1. [supabase.com](https://supabase.com)에서 무료 프로젝트를 만듭니다 (Region은 Northeast Asia (Seoul) 추천).
2. 대시보드 **SQL Editor → New query**에 `supabase/schema.sql` 내용을 붙여넣고 **Run**.
3. 새 쿼리에 `supabase/seed.sql` 내용을 붙여넣고 **Run**.
4. **Project Settings → API**(또는 *Data API*)에서 다음 두 값을 복사합니다.
   - Project URL
   - `anon` `public` 키 (또는 `sb_publishable_…` 키)
5. `config.js`를 열어 두 값을 넣고 커밋합니다.

```js
window.HSK_CONFIG = {
  supabaseUrl: "https://abcdefgh.supabase.co",
  supabaseKey: "sb_publishable_xxxxxxxx"
};
```

> anon/publishable 키는 공개돼도 괜찮습니다. 테이블은 잠겨 있고, 앱은 로그인 토큰을 확인하는 함수로만 데이터에 접근합니다.
> **service_role / secret 키는 절대 넣지 마세요.**

## 계정과 권한

- 기본 관리자: **이정빈 / 7052**
- 누구나 첫 화면에서 *새 계정 만들기*로 계정을 만들 수 있고, 진도는 계정마다 따로 저장됩니다.
- **서랍 만들기·파일 올리기·이름 바꾸기·비우기·삭제는 관리자만** 할 수 있습니다. 다른 계정을 관리자로 만들려면 Supabase **Table Editor → hsk_app_users**에서 `is_admin`을 `true`로 바꾸세요.
- 암호를 5번 틀리면 5분 동안 잠깁니다.

## 단어 올리기

관리자로 로그인 → **서랍** 탭 → *파일로 단어 올리기* (ERP 화면에서는 툴바 **올리기**).

- 지원 형식: PDF, CSV, Word(.docx), TXT, 직접 붙여넣기
- 표의 한 행에 `중국어 · 병음 · 뜻`이 있으면 열 순서와 상관없이 문자 종류(한자/병음/한글)로 찾아냅니다.
- 넣기 전에 인식 결과를 표로 보여 주고, 칸을 눌러 고치거나 ✕로 뺄 수 있습니다.
- 같은 서랍에 이미 있는 한자는 건너뜁니다. *서랍 비우고 교체*를 고르면 새 파일로 바꿉니다 (진도는 한자 기준이라 다시 올려도 유지됩니다).

CSV 예시:

```csv
중국어,병음,뜻
爱好,àihào,취미
帮助,bāngzhù,"돕다, 도움"
```

## 데이터 구조

모든 테이블·함수 이름이 `hsk_`로 시작해서, 이미 쓰던 Supabase 프로젝트에 같이 넣어도 기존 테이블과 겹치지 않습니다.

```
hsk_app_users      id, name, pin_hash(bcrypt), is_admin
hsk_sessions       token, user_id
hsk_decks          id, name, color, sort            ← 서랍 (모든 계정 공용)
hsk_words          deck_id, ord, han, py, mn        ← 서랍 속 단어
hsk_progress       user_id, deck_id, han, d(외움), x(헷갈림), c(횟수), t(최근), m(메모)
hsk_user_settings  user_id, data(jsonb)             ← 하루 단어 수, 가리기, 마지막 위치 등
```
