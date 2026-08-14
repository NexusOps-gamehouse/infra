// ===========================================================================
// 회차 결과를 파일로 남긴다.
//
// handleSummary() 를 export 하면 k6 는 기본 요약을 화면에 찍지 않는다.
// 대신 이 함수가 돌려준 { 경로: 내용 } 을 그대로 쓴다. 'stdout' 키가
// 터미널 출력이므로, 여기서 만들지 않으면 화면에 아무것도 안 뜬다.
//
// ⚠️ 외부 라이브러리(jslib.k6.io)를 쓰지 않는다. 러너 EC2 의 egress 여부에
//    따라 init 단계에서 실패할 수 있고, 무엇보다 기본 요약은 우리 판정 기준
//    (등급별 p95 / dropped / 4xx 구분)을 그대로 보여주지 않는다. 직접 만든다.
//
// ⚠️ p(99) 는 k6 기본 summaryTrendStats 에 없다. threshold 판정은 정상이지만
//    요약에는 안 찍힌다. run.sh 가 --summary-trend-stats 로 넘긴다.
//    k6 를 직접 부를 때는 그 플래그를 같이 주지 않으면 p99 칸이 비어 보인다.
// ===========================================================================

import { loadModeNote, loadModeInfo } from './config.js';

// run.sh 가 절대경로로 넘긴다. 직접 k6 를 부르면 CWD 기준 상대경로가 된다.
const DIR = __ENV.RESULT_DIR || 'results/local';
const TESTID = __ENV.TESTID || 'local';
const ROUND = __ENV.ROUND || 'unknown';

const BAR = '═'.repeat(72);

// 회차 이름 → VU 프로파일 키. 축소가 적용되는 회차만 매핑한다.
//
// ⚠️ 예전에는 'round-a 면 roundA, 아니면 roundBC' 로 갈랐다. 그러면 스모크와
//    회차 D 도 roundBC 로 취급돼, 축소되지도 않은 회차에 '로컬 축소' 경고가
//    붙었다. 요약이 사실과 다르면 요약이 아니라 소음이다.
const MODE_KEY = { 'round-a': 'roundA', 'round-b': 'roundBC', 'round-c': 'roundBC' }[ROUND] || null;

// ---------------------------------------------------------------------------
// 조회 도우미 — 지표가 없을 때 예외를 던지지 않는다.
//
// 회차가 중간에 끊기거나(회차 B 의 abortOnFail) 시나리오 일부만 도는 경우
// (회차 D) 특정 지표가 통째로 없다. 요약을 만들다 실패하면 회차 결과 자체를
// 잃으므로, 없는 값은 '-' 로 두고 넘어간다.
// ---------------------------------------------------------------------------

function metric(data, name) {
  return data.metrics[name] || null;
}

function value(data, name, key) {
  const m = metric(data, name);
  if (!m || m.values[key] === undefined) return null;
  return m.values[key];
}

function ms(v) {
  if (v === null) return '-';
  return v >= 1000 ? `${(v / 1000).toFixed(2)}s` : `${Math.round(v)}ms`;
}

// ⚠️ toLocaleString('en-US', {...}) 을 쓰지 않는다.
//    k6 의 JS 엔진(goja)은 Number.prototype.toLocaleString 을 toString(radix)
//    로 구현해 두어서, 로케일 문자열을 넘기면
//      RangeError: toString() radix argument must be between 2 and 36
//    이 난다. handleSummary 안에서 예외가 나면 k6 는 조용히 기본 요약으로
//    돌아가고 파일도 안 쓴다 — 회차가 끝난 뒤에야 결과가 없다는 걸 안다.
function num(v, digits = 0) {
  if (v === null || v === undefined) return '-';
  const [int, frac] = Number(v).toFixed(digits).split('.');
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return frac ? `${grouped}.${frac}` : grouped;
}

function pct(v, digits = 2) {
  return v === null ? '-' : `${(v * 100).toFixed(digits)}%`;
}

function pad(s, w) {
  s = String(s);
  return s.length >= w ? s : s + ' '.repeat(w - s.length);
}

function padStart(s, w) {
  s = String(s);
  return s.length >= w ? s : ' '.repeat(w - s.length) + s;
}

function duration(msTotal) {
  const total = Math.round(msTotal / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

// ---------------------------------------------------------------------------
// threshold 결과 수집
//
// 각 지표 객체의 thresholds 는 { 'p(95)<500': { ok: true } } 모양이다.
// 목표값을 여기서 따로 정의하지 않고 이 표현식에서 되읽는다 — thresholds.js
// 와 두 벌로 관리하면 언젠가 어긋나고, 어긋난 요약은 오히려 해롭다.
// ---------------------------------------------------------------------------

function collectThresholds(data) {
  const out = [];
  for (const [name, m] of Object.entries(data.metrics)) {
    if (!m.thresholds) continue;
    for (const [expr, result] of Object.entries(m.thresholds)) {
      out.push({ metric: name, expr, ok: result.ok !== false });
    }
  }
  return out;
}

/** 'p(95)<500' 에서 500 을 꺼낸다. 못 읽으면 null. */
function limitOf(thresholds, prefix) {
  const hit = thresholds.find((t) => t.expr.startsWith(prefix));
  if (!hit) return null;
  const m = hit.expr.match(/<\s*(\d+(?:\.\d+)?)/);
  return m ? Number(m[1]) : null;
}

const GRADES = ['light_read', 'list_read', 'write', 'auth'];

// ---------------------------------------------------------------------------
// 본문
// ---------------------------------------------------------------------------

function render(data) {
  const L = [];
  const seed = data.setup_data || {};
  const all = collectThresholds(data);
  const failed = all.filter((t) => !t.ok);

  L.push(BAR);
  L.push(` 회차 ${ROUND}  ·  testid ${TESTID}`);
  if (seed.profile) {
    L.push(
      ` 프로파일 ${seed.profile} · 계정 ${num(seed.accounts)}` +
      ` · 게시글 ${num(seed.posts)} · 신청 ${num(seed.applications)}`,
    );
  }
  L.push(` 소요 ${duration(data.state.testRunDurationMs)}`);

  // 축소 모드로 돈 회차를 정상 회차로 착각하는 것을 막는다. 숫자만 보면
  // 구분이 안 되고, 구분이 안 되면 언젠가 이 결과가 보고서로 샌다.
  // 꼬리말('완주 검증용' 등)은 config.js 가 모드에 맞춰 붙인다 — 축소와
  // --full 은 남길 말이 다르다.
  const mode = loadModeNote(MODE_KEY);
  if (mode) L.push(` ⚠ ${mode}`);

  L.push(BAR);

  // --- 대상이 죽었나 ------------------------------------------------------
  // 다른 무엇보다 먼저 찍는다. 이게 있으면 아래 숫자는 전부 읽을 필요가 없다.
  const connCount = value(data, 'lt_conn_errors', 'count') ?? 0;
  if (connCount > 0) {
    const first = value(data, 'lt_conn_error_at', 'min');
    const last = value(data, 'lt_conn_error_at', 'max');
    const ran = data.state.testRunDurationMs / 1000;

    // VU·RPS 는 연결 오류가 난 요청들에서만 모은 값이다. 중단이 20건째에
    // 걸리므로 전부 1~2초 안의 표본이고, 따라서 범위가 좁다. 그래도 min~max 로
    // 적는다 — 한 값으로 뭉뚱그리면 "그 순간의 값" 인 것처럼 읽히기 때문이다.
    const vusMin = value(data, 'lt_conn_error_vus', 'min');
    const vusMax = value(data, 'lt_conn_error_vus', 'max');
    const rpsMin = value(data, 'lt_conn_error_rps', 'min');
    const rpsMax = value(data, 'lt_conn_error_rps', 'max');
    const range = (a, b, digits = 0) =>
      a === null ? '-'
        : Math.abs(a - b) < (digits ? 0.05 : 0.5)
          ? num(a, digits)
          : `${num(a, digits)} ~ ${num(b, digits)}`;

    L.push('');
    L.push(' ⛔ 대상에 연결되지 않았다 — 이 회차는 폐기한다');
    L.push(`   연결 실패     ${padStart(num(connCount), 10)} 건`);
    L.push(`   최초 발생     ${padStart(first === null ? '-' : duration(first * 1000), 10)}   ← 여기서 끊겼다`);
    L.push(`   마지막 발생   ${padStart(last === null ? '-' : duration(last * 1000), 10)}`);
    L.push(`   그때 활성 VU  ${padStart(range(vusMin, vusMax), 10)}`);
    L.push(`   그때 RPS      ${padStart(range(rpsMin, rpsMax, 1), 10)}   회차 시작부터의 누적 평균 (순간값 아님)`);
    L.push(`   회차 진행     ${padStart(duration(data.state.testRunDurationMs), 10)}`);
    if (first !== null && ran > 0) {
      L.push(`   즉, 예정 구간의 앞 ${duration(first * 1000)} 까지만 유효한 측정이다.`);
    }
    L.push('');
    // ⚠️ 순서가 중요하다. 실측(2026-08-13 회차 A): 컨테이너가 cgroup OOM 으로
    //    죽었는데 docker logs 에는 아무것도 안 남았고(Java OOM 이 아니라 커널
    //    SIGKILL 이라 그렇다), mac 에서는 dmesg 도 못 쓴다.
    //    확정시켜준 것은 inspect 의 OOMKilled 한 줄뿐이라 그것을 맨 위에 둔다.
    L.push('   확인할 것: OOM 이 먼저다. 아래 순서대로 본다');
    L.push("     docker inspect gamehouse-backend --format '{{.State.OOMKilled}} {{.State.ExitCode}} {{.RestartCount}}'");
    L.push('       → true 137 이면 컨테이너 메모리 한도 초과다 (mem_limit vs 유휴 RSS 를 본다)');
    L.push('     docker ps -a | grep gamehouse-backend');
    L.push('     docker logs --tail 100 gamehouse-backend');
    L.push('       → 커널이 죽인 경우 여기엔 아무것도 안 남는다. 로그가 조용한 것이 곧 단서다');
    L.push(BAR);
  }

  // --- 투입 ---------------------------------------------------------------
  // 달성 RPS 가 목표에 못 미치면 그 구간은 '135 RPS 에서의 측정'이 아니다.
  // dropped 와 함께 봐야 러너 병목인지 서버 병목인지 갈린다.
  L.push('');
  L.push(' 투입');
  L.push(`   달성 RPS     ${padStart(num(value(data, 'http_reqs', 'rate'), 1), 10)}   http_reqs`);
  L.push(`   TPS          ${padStart(num(value(data, 'iterations', 'rate'), 1), 10)}   iterations (1 iter = 1 요청)`);
  // ⚠️ vus 와 vus_max 는 다른 것을 센다.
  //      vus      매초 관측된 '활성' VU     ← 우리가 보려는 값(결과)
  //      vus_max  사전할당 상한             ← 투입한 설정값. 회차 내내 상수다
  //    vus_max 를 찍으면 회차 A 는 늘 400, B·C 는 늘 800 이 나와서
  //    "150 근처인가" 라는 판정 자체가 성립하지 않는다.
  const vusObserved = value(data, 'vus', 'max');
  const vusAlloc = value(data, 'vus_max', 'max') ?? value(data, 'vus_max', 'value');
  L.push(
    `   VU 관측 최대 ${padStart(num(vusObserved), 10)}   150 근처면 사고시간 가정과 일관` +
    (vusObserved === 0 ? ' (0 = 회차가 짧아 표본 없음)' : ''),
  );
  L.push(`   VU 할당      ${padStart(num(vusAlloc), 10)}   preAllocated/max. 관측값이 여기 닿으면 러너가 상한이다`);

  const dropped = value(data, 'dropped_iterations', 'count') ?? 0;
  L.push(
    `   dropped      ${padStart(num(dropped), 10)}   ` +
    (dropped > 0 ? '⚠ 0 이 아니면 이 구간은 폐기한다' : '정상'),
  );

  L.push(`   송신          ${padStart(mb(value(data, 'data_sent', 'count')), 10)}   Data Transfer Out 과금 대상`);
  L.push(`   수신          ${padStart(mb(value(data, 'data_received', 'count')), 10)}`);

  // --- 등급별 지연 ---------------------------------------------------------
  // 전체 합산 p95 는 일부러 안 찍는다. 무거운 API 가 가벼운 API 에 희석돼
  // "평균적으로는 괜찮다" 는 잘못된 답이 나온다.
  L.push('');
  L.push(' 등급별 지연 (전체 합산 p95 는 판정에 쓰지 않는다)');
  L.push(`   ${pad('등급', 10)}${padStart('p95', 9)}${padStart('p99', 9)}` +
         `${padStart('목표 p95', 11)}${padStart('목표 p99', 11)}   판정`);

  for (const g of GRADES) {
    const key = `http_req_duration{grade:${g}}`;
    const m = metric(data, key);
    if (!m) {
      // ⚠️ k6 는 threshold 가 참조하는 서브메트릭만 만든다.
      //    요청에 grade 태그를 붙였어도 'http_req_duration{grade:write}' 에
      //    대한 threshold 가 없으면 이 키 자체가 존재하지 않는다.
      //    스모크가 그 경우다(5xx 와 dropped 만 본다) — 요청이 없는 것과
      //    구분해서 적지 않으면 "안 돌았나?" 로 오해한다.
      const ran = (value(data, 'http_reqs', 'count') ?? 0) > 0;
      L.push(`   ${pad(g, 14)}${padStart('-', 9)}${padStart('-', 9)}` +
             `${padStart('-', 11)}${padStart('-', 11)}   ` +
             (ran ? '(등급 threshold 미정의 — 집계 안 함)' : '(요청 없음)'));
      continue;
    }
    const th = all.filter((t) => t.metric === key);
    const p95 = value(data, key, 'p(95)');
    const p99 = value(data, key, 'p(99)');
    const lim95 = limitOf(th, 'p(95)');
    const lim99 = limitOf(th, 'p(99)');
    const ok = th.every((t) => t.ok);

    L.push(
      `   ${pad(g, 14)}${padStart(ms(p95), 9)}${padStart(ms(p99), 9)}` +
      `${padStart(lim95 === null ? '-' : `< ${ms(lim95)}`, 11)}` +
      `${padStart(lim99 === null ? '-' : `< ${ms(lim99)}`, 11)}` +
      `   ${th.length === 0 ? '-' : ok ? 'PASS' : 'FAIL'}`,
    );
  }

  // --- 오류 ---------------------------------------------------------------
  // 4xx 와 5xx 를 반드시 갈라서 본다. 4xx 는 비즈니스 거절이라 정상이고,
  // 오히려 0 이면 시나리오 4 가 제대로 안 돌았다는 뜻이다.
  L.push('');
  L.push(' 오류');
  L.push(`   실패율       ${padStart(pct(value(data, 'http_req_failed', 'rate')), 10)}   5xx · 예상 밖 4xx · 연결 실패`);
  L.push(`   4xx 건수     ${padStart(num(value(data, 'lt_client_errors', 'count') ?? 0), 10)}   전체 4xx. S4 중복신청만 정상, 나머지는 위 실패율에도 포함`);
  L.push(`   checks       ${padStart(pct(value(data, 'checks', 'rate')), 10)}`);

  // --- threshold -----------------------------------------------------------
  L.push('');
  if (failed.length === 0) {
    L.push(` threshold    ${all.length}개 전부 통과`);
  } else {
    L.push(` threshold    ${all.length}개 중 ${failed.length}개 위반`);
    for (const t of failed) {
      L.push(`   ✗ ${t.metric}  ${t.expr}`);
    }
  }

  L.push('');
  L.push(BAR);

  // 로컬에서 나온 숫자를 보고서에 옮겨 적는 사고를 막는다.
  if (__ENV.LOCAL === '1') {
    L.push(' ⚠ 로컬 실행이다. 이 숫자는 성능 판정에 인용하지 않는다 (Rosetta 에뮬레이션).');
    L.push(BAR);
  }

  return L.join('\n');
}

function mb(bytes) {
  if (bytes === null) return '-';
  const m = bytes / 1024 / 1024;
  if (m >= 1024) return `${(m / 1024).toFixed(2)} GB`;
  if (m >= 1) return `${m.toFixed(1)} MB`;
  return `${(bytes / 1024).toFixed(0)} KB`;
}

// ---------------------------------------------------------------------------

export function handleSummary(data) {
  const text = render(data);
  const mode = loadModeInfo(MODE_KEY);

  const files = {
    // 축소 모드로 돌았다면 '무엇으로 돌았는지' 를 기계가 읽을 형태로 남긴다.
    // run.sh 가 이 파일을 manifest.json 에 그대로 옮겨 담는다 — bash 가 기본값을
    // 다시 계산하지 않게 하려는 것이다(config.js 의 loadModeInfo 주석 참조).
    //
    // localFull(로컬인데 --full 로 축소를 끈 회차)도 같이 남긴다. 축소가 아니니
    // reduced 는 false 지만, 그 사실이야말로 manifest 에 있어야 하는 것이다.
    ...(mode.reduced || mode.localFull
      ? { [`${DIR}/load-mode.json`]: JSON.stringify(mode, null, 2) }
      : {}),

    stdout: `\n${text}\n`,

    // 사람이 읽을 것. 회차 직후 그대로 공유해도 되게 만든다.
    [`${DIR}/summary.txt`]: text,

    // 기계가 읽을 것. k6 원본 구조를 그대로 남긴다 — 나중에 무엇이 필요할지
    // 지금 알 수 없으므로 골라 담지 않는다. 수십 KB 밖에 안 된다.
    [`${DIR}/summary.json`]: JSON.stringify(data, null, 2),
  };

  return files;
}
