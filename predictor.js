// 双色球推演器 · 纯前端核心（增强版）
// 16 方法 + 加权随机 + P1/P2/P4 + 综合投票
// 新增：回测引擎、权重优化、命中统计、自动比对、奖级判断
// 与 Swift 版 main.swift 完全对齐（方法、公式、参数）。

const METHOD_NAMES = [
  "热号追踪","冷号回补","区间分布","奇偶平衡","质数筛选",
  "和值分析","跨度分析","AC值分析","连号分析","重号分析",
  "尾数分布","遗漏分析","号码关联","蓝球热号","蓝球冷号","蓝球奇偶",
];
const COMPREHENSIVE = "综合推演";
const MIN_TRAINING = 30;
const PRIZE_WEIGHTS = {"一等奖":100,"二等奖":50,"三等奖":20,"四等奖":5,"五等奖":2,"六等奖":1};

function emptyVotes() {
  const rv = {}, bv = {};
  for (let i = 1; i <= 33; i++) rv[i] = 0;
  for (let i = 1; i <= 16; i++) bv[i] = 0;
  return [rv, bv];
}

function weightedPick(votes, count) {
  const keys = Object.keys(votes).map(Number);
  const isBlue = keys.length ? Math.max(...keys) <= 16 : false;
  const range = [];
  const hi = isBlue ? 16 : 33;
  for (let i = 1; i <= hi; i++) range.push(i);

  let items = Object.entries(votes).filter(([k, v]) => v > 0 && range.includes(+k));
  const selected = [];
  const minW = 0.01;

  while (selected.length < count && items.length) {
    const avail = items.filter(([k]) => !selected.includes(+k));
    if (!avail.length) break;
    const total = avail.reduce((s, [, v]) => s + Math.max(v, minW), 0);
    if (total <= 0) break;
    const threshold = Math.random() * total;
    let cum = 0, picked = null;
    for (const [k, v] of avail) {
      cum += Math.max(v, minW);
      if (threshold < cum) { picked = +k; break; }
    }
    if (picked !== null) {
      selected.push(picked);
      items = items.filter(([k]) => k !== String(picked));
    } else break;
  }
  let remain = range.filter(n => !selected.includes(n));
  while (selected.length < count && remain.length) {
    const idx = Math.floor(Math.random() * remain.length);
    selected.push(remain.splice(idx, 1)[0]);
  }
  return selected.sort((a, b) => a - b);
}

function getCount(arr) {
  const m = {};
  for (const x of arr) m[x] = (m[x] || 0) + 1;
  return m;
}

function prizeLevel(redMatch, blueMatch) {
  if (redMatch === 6 && blueMatch === 1) return "一等奖";
  if (redMatch === 6) return "二等奖";
  if (redMatch === 5 && blueMatch === 1) return "三等奖";
  if (redMatch === 5 || (redMatch === 4 && blueMatch === 1)) return "四等奖";
  if (redMatch === 4 || (redMatch === 3 && blueMatch === 1)) return "五等奖";
  if (blueMatch === 1) return "六等奖";
  return "未中奖";
}

function getMethodPredictions(records, steps, weights) {
  const results = [];
  const recent = records.slice(0, 50);
  const recentRed = recent.flatMap(r => r.red);
  const recentBlue = recent.map(r => r.blue);
  const latest = records[0];
  const latestRed = latest ? latest.red : [];
  const latestBlue = latest ? latest.blue : 0;

  for (let idx = 0; idx < METHOD_NAMES.length; idx++) {
    const name = METHOD_NAMES[idx];
    const [rv, bv] = emptyVotes();
    const detail = [];
    const w = (weights && weights[name]) || 1.0;

    if (name === "热号追踪") {
      const freq = getCount(recentRed);
      const hot = Object.entries(freq).filter(([, c]) => c >= 2)
        .sort((a, b) => b[1] - a[1]).slice(0, 8).map(x => +x[0]);
      for (const n of hot) rv[n] = freq[n] * 0.5 * w;
      const bf = getCount(recentBlue);
      const hotb = Object.entries(bf).filter(([, c]) => c >= 2).map(x => +x[0]);
      for (const n of hotb) bv[n] = bf[n] * 0.5 * w;
      detail.push("热号: " + hot.slice(0, 6).join(","));
      detail.push("蓝球热号: " + hotb.slice(0, 3).join(","));
    }
    else if (name === "冷号回补") {
      const s = new Set(recentRed);
      const cold = [];
      for (let n = 1; n <= 33; n++) if (!s.has(n)) cold.push(n);
      for (const n of cold) rv[n] = w * 0.4;
      const sb = new Set(recentBlue);
      const coldb = [];
      for (let n = 1; n <= 16; n++) if (!sb.has(n)) coldb.push(n);
      for (const n of coldb) bv[n] = w * 0.3;
      detail.push("冷号: " + cold.slice(0, 10).join(","));
    }
    else if (name === "区间分布") {
      const z1 = recentRed.filter(b => b <= 11).length;
      const z2 = recentRed.filter(b => b >= 12 && b <= 22).length;
      const z3 = recentRed.filter(b => b >= 23).length;
      detail.push(`区间: 一区${z1}个 二区${z2}个 三区${z3}个`);
      if (z1 < 2) for (let i = 1; i <= 11; i++) rv[i] += 0.3 * w;
      if (z2 < 2) for (let i = 12; i <= 22; i++) rv[i] += 0.3 * w;
      if (z3 < 2) for (let i = 23; i <= 33; i++) rv[i] += 0.3 * w;
    }
    else if (name === "奇偶平衡") {
      const odd = recentRed.slice(0, 6).filter(b => b % 2 === 1).length;
      const even = 6 - odd;
      detail.push(`上期奇偶: ${odd}奇:${even}偶`);
      for (let i = (odd > even ? 2 : 1); i <= 33; i += 2) rv[i] += 0.25 * w;
    }
    else if (name === "质数筛选") {
      const primes = [2,3,5,7,11,13,17,19,23,29,31];
      const lp = recentRed.slice(0, 6).filter(b => primes.includes(b));
      detail.push("上期质数: " + lp.join(",") + ` (${lp.length}个)`);
      if (lp.length < 2) for (const p of primes) rv[p] += 0.2 * w;
    }
    else if (name === "和值分析") {
      const sums = records.slice(0, 30).map(r => r.red.reduce((a, b) => a + b, 0));
      const avg = sums.length ? Math.floor(sums.reduce((a, b) => a + b, 0) / sums.length) : 100;
      const lastSum = latest ? latest.red.reduce((a, b) => a + b, 0) : 102;
      detail.push(`和值: 平均${avg} 上期${lastSum}`);
      if (lastSum > avg + 20) for (let i = 1; i <= 20; i++) rv[i] += 0.15 * w;
      else if (lastSum < avg - 20) for (let i = 15; i <= 33; i++) rv[i] += 0.15 * w;
    }
    else if (name === "跨度分析") {
      if (latest) {
        const srt = [...latest.red].sort((a, b) => a - b);
        const span = srt[srt.length - 1] - srt[0];
        detail.push(`跨度: ${span}`);
        if (span > 25) for (let i = 1; i <= 10; i++) rv[i] += 0.2 * w;
        else if (span < 15) for (let i = 20; i <= 33; i++) rv[i] += 0.2 * w;
      }
    }
    else if (name === "AC值分析") {
      detail.push("AC值: 复杂度均衡");
      for (let i = 1; i <= 33; i++) rv[i] += 0.05 * w;
    }
    else if (name === "连号分析") {
      if (latest) {
        const srt = [...latest.red].sort((a, b) => a - b);
        const pairs = [];
        for (let i = 0; i < srt.length - 1; i++) {
          if (srt[i + 1] - srt[i] === 1) {
            pairs.push(srt[i] + "" + srt[i + 1]);
            rv[srt[i]] += 0.25 * w;
            rv[srt[i + 1]] += 0.25 * w;
          }
        }
        detail.push("连号: " + (pairs.length ? pairs.join(",") : "无"));
      }
    }
    else if (name === "重号分析") {
      detail.push("重号: 上期号码加权");
      for (const n of new Set(latestRed)) rv[n] = (rv[n] || 0) + 0.3 * w;
      bv[latestBlue] = (bv[latestBlue] || 0) + 0.3 * w;
    }
    else if (name === "尾数分布") {
      const tf = getCount(recentRed.map(b => b % 10));
      const hotTails = Object.entries(tf).filter(([, c]) => c >= 3)
        .sort((a, b) => b[1] - a[1]).map(x => +x[0]);
      detail.push("热尾: " + (hotTails.length ? hotTails.join(",") : "无"));
      for (const t of hotTails)
        for (let i = 1; i <= 33; i++) if (i % 10 === t) rv[i] += 0.15 * w;
    }
    else if (name === "遗漏分析") {
      const s = new Set(recentRed);
      const missing = [];
      for (let n = 1; n <= 33; n++) if (!s.has(n)) missing.push(n);
      detail.push("遗漏: " + missing.slice(0, 12).join(","));
      for (const n of missing) rv[n] += 0.1 * w;
    }
    else if (name === "号码关联") {
      detail.push("关联: 邻号分析");
      if (latest) for (const n of latest.red)
        for (const o of [-1, 1, 2, -2]) {
          const nb = n + o;
          if (nb >= 1 && nb <= 33) rv[nb] += 0.08 * w;
        }
    }
    else if (name === "蓝球热号") {
      const bf = getCount(recentBlue);
      const hot = Object.entries(bf).filter(([, c]) => c >= 2)
        .sort((a, b) => b[1] - a[1]).map(x => +x[0]);
      detail.push("蓝球热号: " + hot.slice(0, 4).map(k => `${k}(${bf[k]}次)`).join(","));
      for (const n of hot.slice(0, 4)) bv[n] = bf[n] * 0.5 * w;
    }
    else if (name === "蓝球冷号") {
      const s = new Set(recentBlue);
      const cold = [];
      for (let n = 1; n <= 16; n++) if (!s.has(n)) cold.push(n);
      detail.push("蓝球冷号: " + cold.slice(0, 5).join(","));
      for (const n of cold) bv[n] += 0.3 * w;
    }
    else if (name === "蓝球奇偶") {
      const last5 = recentBlue.slice(0, 5);
      const odd = last5.filter(b => b % 2 === 1).length;
      const even = last5.length - odd;
      detail.push(`蓝球奇偶: 近${last5.length}期 ${odd}奇:${even}偶`);
      if (odd >= 4) for (let i = 2; i <= 16; i += 2) bv[i] += 0.25 * w;
      else if (even >= 4) for (let i = 1; i <= 16; i += 2) bv[i] += 0.25 * w;
    }
    else {
      detail.push("默认: 均匀分布");
      for (let i = 1; i <= 33; i++) rv[i] += 0.05 * w;
    }

    const selRed = weightedPick(rv, 6);
    const selBlue = weightedPick(bv, 1)[0];

    if (steps) {
      steps.push(`方法${idx + 1}/${METHOD_NAMES.length}: ${name}...`);
      for (const d of detail) steps.push(`  → ${d}`);
      steps.push("  → 推荐: " + selRed.map(x => String(x).padStart(2, "0")).join(" ") + ` + ${String(selBlue).padStart(2, "0")}`);
    }
    results.push([name, selRed, selBlue, detail.join(" ")]);
  }
  return results;
}

function isExtremeForm(reds) {
  const s = [...reds].sort((a, b) => a - b);
  let run = 1;
  for (let i = 1; i < 6; i++) {
    if (s[i] === s[i - 1] + 1) run++; else run = 1;
    if (run >= 3) return true;
  }
  const odd = s.filter(x => x % 2 === 1).length;
  if (odd === 0 || odd === 6) return true;
  const big = s.filter(x => x >= 17).length;
  if (big === 0 || big === 6) return true;
  const tc = getCount(s.map(x => x % 10));
  if (Object.values(tc).some(v => v >= 3)) return true;
  const d = s[1] - s[0];
  if (d > 0 && s.every((x, i) => i === 0 || x - s[i - 1] === d)) return true;
  if (s[0] + s[5] === s[1] + s[4] && s[1] + s[4] === s[2] + s[3]) return true;
  return false;
}
function birthdayFactor(reds) {
  const b = reds.filter(x => x >= 1 && x <= 31).length;
  if (b >= 6) return 0.55;
  if (b === 5) return 0.75;
  return 1;
}
function passesFilters(reds, prevReds) {
  if (isExtremeForm(reds)) return false;
  const st = new Set(reds);
  for (const h of prevReds) {
    let ov = 0;
    for (const n of h) if (st.has(n)) ov++;
    if (ov >= 4) return false;
  }
  return true;
}

function combinations(arr, k) {
  const res = [];
  const rec = (start, chosen) => {
    if (chosen.length === k) { res.push(chosen.slice()); return; }
    for (let i = start; i < arr.length; i++) {
      chosen.push(arr[i]);
      rec(i + 1, chosen);
      chosen.pop();
    }
  };
  rec(0, []);
  return res;
}

function vote(methodResults, prevReds, useP4, weights) {
  const finalRv = {}, finalBv = {};
  const bday = 0.85;
  for (const [name, red, blue] of methodResults) {
    const w = (weights && weights[name]) || 1.0;
    for (const n of red) {
      let v = w * 10;
      if (n >= 1 && n <= 31) v *= bday;
      finalRv[n] = (finalRv[n] || 0) + v;
    }
    finalBv[blue] = (finalBv[blue] || 0) + Math.round(w * 10);
  }
  const sortedReds = Object.entries(finalRv).sort((a, b) => b[1] - a[1]);
  const pool = sortedReds.slice(0, 12).map(x => +x[0]);

  let best = -1, selected = [];
  if (pool.length >= 6) {
    for (const combo of combinations(pool, 6)) {
      if (useP4 && !passesFilters(combo, prevReds)) continue;
      const factor = birthdayFactor(combo);
      const score = combo.reduce((s, x) => s + (finalRv[x] || 0), 0) * factor;
      if (score > best) { best = score; selected = combo; }
    }
  }
  if (selected.length < 6) {
    let fb = [...new Set(sortedReds.slice(0, 6).map(x => +x[0]))];
    for (const [k] of sortedReds) {
      if (!fb.includes(+k)) { fb.push(+k); if (fb.length >= 6) break; }
    }
    selected = fb.slice(0, 6);
  }
  const sortedBlues = Object.entries(finalBv).sort((a, b) => b[1] - a[1]);
  const blue = sortedBlues.length ? +sortedBlues[0][0] : 8;
  return {
    red: selected.sort((a, b) => a - b),
    blue,
    redVotes: sortedReds,
    blueVotes: sortedBlues,
  };
}

function predictOne(records, prevReds, weights, steps) {
  const results = getMethodPredictions(records, steps, weights);
  const voted = vote(results, prevReds, true, weights);
  return {
    red: voted.red,
    blue: voted.blue,
    methodResults: results,
    steps: steps || [],
    redVotes: voted.redVotes,
    blueVotes: voted.blueVotes,
  };
}

function autoCompare(history, records) {
  const drawByIssue = {};
  for (const h of history) drawByIssue[h.issue] = h;
  let changed = 0;
  for (const p of records) {
    if (p.autoCompared) continue;
    const draw = drawByIssue[p.issue];
    if (!draw) continue;
    const redMatch = [...new Set(p.predictedRed)].filter(x => draw.red.includes(x)).length;
    const blueMatch = p.predictedBlue === draw.blue ? 1 : 0;
    p.actualRed = draw.red;
    p.actualBlue = draw.blue;
    p.matchedRed = redMatch;
    p.matchedBlue = blueMatch;
    p.prize = prizeLevel(redMatch, blueMatch);
    p.autoCompared = true;
    changed++;
  }
  return changed;
}

function calcMethodStats(records, currentStats) {
  const compared = records.filter(r => r.autoCompared);
  const stats = {};
  for (const m of METHOD_NAMES) {
    stats[m] = {
      id: m, method: m,
      hitCount: 0, totalCount: 0, hitRate: 0,
      weight: (currentStats && currentStats[m] ? currentStats[m].weight : 1.0)
    };
  }
  for (const p of compared) {
    if (stats[p.method]) {
      stats[p.method].totalCount++;
      if (p.matchedRed > 0 || p.matchedBlue > 0) stats[p.method].hitCount++;
    }
  }
  for (const m of METHOD_NAMES) {
    const s = stats[m];
    s.hitRate = s.totalCount > 0 ? s.hitCount / s.totalCount : 0;
  }
  return stats;
}

function optimizeWeights(stats) {
  const out = {};
  for (const [m, s] of Object.entries(stats)) {
    let w = s.weight != null ? s.weight : 1.0;
    if (s.totalCount > 0) {
      const adjusted = 1.0 + (s.hitRate || 0) * 2.0;
      w = Math.min(Math.max(adjusted, 0.5), 3.0);
    }
    out[m] = { id: m, method: m, hitCount: s.hitCount || 0, totalCount: s.totalCount || 0, hitRate: s.hitRate || 0, weight: w };
  }
  return out;
}

async function runBacktest(history, periods, weights, onProgress) {
  const available = Math.max(0, history.length - MIN_TRAINING);
  if (available <= 0) return [];
  const P = periods <= 0 ? available : Math.min(periods, available);

  const acc = {};
  for (const m of METHOD_NAMES) acc[m] = { red: 0, blue: 0, prizes: {} };
  acc[COMPREHENSIVE] = { red: 0, blue: 0, prizes: {} };
  let tested = 0;

  for (let i = 0; i < P; i++) {
    const actual = history[i];
    const train = history.slice(i + 1);
    if (train.length < MIN_TRAINING) break;

    const results = getMethodPredictions(train, null, weights);
    const voted = vote(results, [], false, weights);

    const accumulate = (method, red, blue) => {
      const a = acc[method] || (acc[method] = { red: 0, blue: 0, prizes: {} });
      const redMatch = [...new Set(red)].filter(x => actual.red.includes(x)).length;
      const blueMatch = blue === actual.blue ? 1 : 0;
      a.red += redMatch;
      a.blue += blueMatch;
      const pz = prizeLevel(redMatch, blueMatch);
      if (pz !== "未中奖") a.prizes[pz] = (a.prizes[pz] || 0) + 1;
    };

    for (const [m, r, b] of results) accumulate(m, r, b);
    accumulate(COMPREHENSIVE, voted.red, voted.blue);
    tested++;

    if ((i + 1) % 25 === 0 || i + 1 === P) {
      if (onProgress) onProgress(i + 1, P);
      await new Promise(r => setTimeout(r, 0));
    }
  }

  const results2 = [];
  for (const [m, a] of Object.entries(acc)) {
    const avgRed = a.red / tested;
    const blueRate = a.blue / tested;
    const prizeScore = Object.entries(a.prizes).reduce((s, [k, v]) => s + v * (PRIZE_WEIGHTS[k] || 0), 0) / tested;
    const score = avgRed + blueRate * 3.0 + prizeScore;
    results2.push({
      method: m, periods: tested,
      redHits: a.red, blueHits: a.blue,
      avgRedHit: avgRed, blueHitRate: blueRate,
      prizeCounts: a.prizes, score,
    });
  }
  return results2.sort((a, b) => b.score - a.score);
}

function applyBacktestWeights(report, currentStats) {
  const out = Object.assign({}, currentStats || {});
  const methodResults = report.filter(r => r.method !== COMPREHENSIVE);
  const maxScore = methodResults.length ? Math.max(...methodResults.map(r => r.score)) : 0;
  for (const r of methodResults) {
    const norm = maxScore > 0 ? r.score / maxScore : 0;
    const weight = 0.5 + norm * 2.5;
    out[r.method] = {
      id: r.method, method: r.method,
      hitCount: out[r.method] ? out[r.method].hitCount : 0,
      totalCount: out[r.method] ? out[r.method].totalCount : 0,
      hitRate: out[r.method] ? out[r.method].hitRate : 0,
      weight,
    };
  }
  return out;
}

function nextIssue(latestIssue) {
  const year = parseInt(latestIssue.slice(0, 4)) || new Date().getFullYear();
  const num = parseInt(latestIssue.slice(4)) || 0;
  const n = num + 1;
  if (n > 150) return String(year + 1).padStart(4, "0") + "001";
  return String(year).padStart(4, "0") + String(n).padStart(3, "0");
}

window.SSQ = {
  METHOD_NAMES, COMPREHENSIVE, MIN_TRAINING, PRIZE_WEIGHTS,
  getMethodPredictions, weightedPick, vote, predictOne,
  isExtremeForm, passesFilters, prizeLevel,
  autoCompare, calcMethodStats, optimizeWeights,
  runBacktest, applyBacktestWeights, nextIssue,
};
