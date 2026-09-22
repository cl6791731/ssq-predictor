// 双色球推演器 · 纯前端版（移植自 predictor.py，零依赖）
// 16 方法 + 加权随机选号 + 反拥挤过滤 P1/P2/P4 + 综合投票（组合枚举）
// 浏览器内直接运行，history.json 由 index.html 打包载入。

const METHOD_NAMES = [
  "热号追踪","冷号回补","区间分布","奇偶平衡","质数筛选",
  "和值分析","跨度分析","AC值分析","连号分析","重号分析",
  "尾数分布","遗漏分析","号码关联","蓝球热号","蓝球冷号","蓝球奇偶",
];

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
  const minWeight = 0.01;

  while (selected.length < count && items.length) {
    const avail = items.filter(([k]) => !selected.includes(+k));
    if (!avail.length) break;
    const total = avail.reduce((s, [, v]) => s + Math.max(v, minWeight), 0);
    if (total <= 0) break;
    const threshold = Math.random() * total;
    let cum = 0, picked = null;
    for (const [k, v] of avail) {
      cum += Math.max(v, minWeight);
      if (threshold < cum) { picked = +k; break; }
    }
    if (picked !== null) {
      selected.push(picked);
      items = items.filter(([k]) => k !== String(picked));
    } else break;
  }
  // 补足
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

// records: 新→旧。返回 [name, red[], blue, detail][]
function getMethodPredictions(records, steps) {
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
    const w = 1.0;

    if (name === "热号追踪") {
      const freq = getCount(recentRed);
      const hot = Object.entries(freq).filter(([, c]) => c >= 2)
        .sort((a, b) => b[1] - a[1]).slice(0, 8).map(x => +x[0]);
      for (const num of hot) rv[num] = freq[num] * 0.5 * w;
      const bf = getCount(recentBlue);
      const hotb = Object.entries(bf).filter(([, c]) => c >= 2).map(x => +x[0]);
      for (const num of hotb) bv[num] = bf[num] * 0.5 * w;
      detail.push("热号: " + hot.slice(0, 6).join(","));
      detail.push("蓝球热号: " + hotb.slice(0, 3).join(","));
    }
    else if (name === "冷号回补") {
      const s = new Set(recentRed);
      const cold = [];
      for (let n = 1; n <= 33; n++) if (!s.has(n)) cold.push(n);
      for (const num of cold) rv[num] = w * 0.4;
      const sb = new Set(recentBlue);
      const coldb = [];
      for (let n = 1; n <= 16; n++) if (!sb.has(n)) coldb.push(n);
      for (const num of coldb) bv[num] = w * 0.3;
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
      const step = 2, start = odd > even ? 2 : 1;
      for (let i = start; i <= 33; i += step) rv[i] += 0.25 * w;
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
      for (const num of new Set(latestRed)) rv[num] = (rv[num] || 0) + 0.3 * w;
      bv[latestBlue] = (bv[latestBlue] || 0) + 0.3 * w;
    }
    else if (name === "尾数分布") {
      const tf = getCount(recentRed.map(b => b % 10));
      const hotTails = Object.entries(tf).filter(([, c]) => c >= 3)
        .sort((a, b) => b[1] - a[1]).map(x => +x[0]);
      detail.push("热尾: " + (hotTails.length ? hotTails.join(",") : "无"));
      for (const tail of hotTails)
        for (let i = 1; i <= 33; i++) if (i % 10 === tail) rv[i] += 0.15 * w;
    }
    else if (name === "遗漏分析") {
      const s = new Set(recentRed);
      const missing = [];
      for (let n = 1; n <= 33; n++) if (!s.has(n)) missing.push(n);
      detail.push("遗漏: " + missing.slice(0, 12).join(","));
      for (const num of missing) rv[num] += 0.1 * w;
    }
    else if (name === "号码关联") {
      detail.push("关联: 邻号分析");
      if (latest) for (const num of latest.red)
        for (const o of [-1, 1, 2, -2]) {
          const nb = num + o;
          if (nb >= 1 && nb <= 33) rv[nb] += 0.08 * w;
        }
    }
    else if (name === "蓝球热号") {
      const bf = getCount(recentBlue);
      const hot = Object.entries(bf).filter(([, c]) => c >= 2)
        .sort((a, b) => b[1] - a[1]).map(x => +x[0]);
      detail.push("蓝球热号: " + hot.slice(0, 4).map(k => `${k}(${bf[k]}次)`).join(","));
      for (const num of hot.slice(0, 4)) bv[num] = bf[num] * 0.5 * w;
    }
    else if (name === "蓝球冷号") {
      const s = new Set(recentBlue);
      const cold = [];
      for (let n = 1; n <= 16; n++) if (!s.has(n)) cold.push(n);
      detail.push("蓝球冷号: " + cold.slice(0, 5).join(","));
      for (const num of cold) bv[num] += 0.3 * w;
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

// ---- 反拥挤过滤 P1/P2/P4 ----
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

function vote(methodResults, prevReds, useP4) {
  const finalRv = {}, finalBv = {};
  const bday = 0.85;
  for (const [name, red, blue] of methodResults) {
    const w = 1.0;
    for (const num of red) {
      let v = w * 10;
      if (num >= 1 && num <= 31) v *= bday;
      finalRv[num] = (finalRv[num] || 0) + v;
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

// 供 index.html 调用
window.SSQ = { METHOD_NAMES, getMethodPredictions, vote, isExtremeForm };
