"use strict";
(async function boot() {
  const packed = JSON.parse(document.getElementById("dataset").textContent);
  const compressed = Uint8Array.from(atob(packed.data), (c) => c.charCodeAt(0));
  const D = JSON.parse(
    await new Response(
      new Blob([compressed])
        .stream()
        .pipeThrough(new DecompressionStream("gzip")),
    ).text(),
  );
  const $ = (id) => document.getElementById(id),
    F = D.frames,
    M = D.meta;
  let selected = 0,
    group = 0,
    timer = null,
    tab = "overview",
    visible = [],
    chosen = new Set([0]);
  const num = (n, d = 1) =>
    n == null || !Number.isFinite(n)
      ? "—"
      : n.toLocaleString(undefined, { maximumFractionDigits: d });
  const esc = (s) =>
    String(s).replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  const sum = (rs, k) => rs.reduce((a, r) => a + (r[k] || 0), 0);
  const ratio = (rs, k, den = "capacity") =>
    rs.length && sum(rs, den) > 0 ? sum(rs, k) / sum(rs, den) : null;
  const phase = (r) =>
    $("phase").value === "all" ||
    r.phase === $("phase").value || r.subphase === $("phase").value;
  // Index once: heatmaps query each bank/entry across every time window.
  // Scanning every record for each cell makes full RTL traces unresponsive.
  const rowIndex = F.map((frame) => {
    const index = new Map();
    for (const row of frame.rows) {
      for (const key of [row.kind, `${row.kind}:${row.g}`]) {
        if (!index.has(key)) index.set(key, []);
        index.get(key).push(row);
      }
    }
    return index;
  });
  const rows = (i, kind, g = null) => {
    const candidates = rowIndex[i].get(g === null ? kind : `${kind}:${g}`) || [];
    const mode = $("phase").value;
    if (mode === "all") return candidates;
    return candidates.filter(phase);
  };
  const now = (kind) => rows(selected, kind);
  // DMA bytes on one interface in a frame, as a share of the L2 bandwidth roof.
  const axiShare = (fi, channel, field) => {
    const l2 = (D.roofline?.roofs || []).find((r) => r.boundary === "l2");
    const rs = rows(fi, "dma").filter((r) => r.channel === channel);
    if (!rs.length || !l2) return null;
    const cycles = sum(rs.map((r) => ({ width: r.end - r.start })), "width");
    return cycles ? sum(rs, field) / cycles / l2.bandwidth : null;
  };
  const color = (v) =>
    v == null
      ? "#dce2e8"
      : `rgb(${Math.round(230 - 212 * Math.min(1, Math.max(0, v)))},${Math.round(243 - 110 * Math.min(1, Math.max(0, v)))},${Math.round(250 - 78 * Math.min(1, Math.max(0, v)))})`;
  const empty = (id, msg) =>
    ($(id).innerHTML = `<div class="empty">${esc(msg)}</div>`);
  const tip = (e, text) => {
    const t = $("tooltip");
    t.textContent = text;
    t.style.display = "block";
    t.style.left = Math.min(e.clientX + 14, window.innerWidth - 390) + "px";
    t.style.top = Math.min(e.clientY + 12, window.innerHeight - 150) + "px";
  };
  const untip = () => ($("tooltip").style.display = "none");
  const span = (rs) =>
    rs.length
      ? `${rs.reduce((value, row) => Math.min(value, row.start), Infinity)}–${rs.reduce((value, row) => Math.max(value, row.end), -Infinity)} cycles`
      : "no coverage";
  function stats(id, items) {
    $(id).innerHTML = items
      .map(
        ([k, v]) =>
          `<div class="stat"><span>${esc(k)}</span><b>${esc(v)}</b></div>`,
      )
      .join("");
    $(id).classList.add("summary");
  }
  function table(id, headers, data) {
    $(id).innerHTML =
      `<div class="tableScroll"><table><thead><tr>${headers.map((x) => `<th>${esc(x)}</th>`).join("")}</tr></thead><tbody>${data.map((r) => `<tr>${r.map((x) => `<td>${esc(x)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;
  }
  function axisBounds() {
    const lo = F[visible[0]].start, hi = F[visible.at(-1)].end;
    const bounds = M.phase_ranges?.[$("phase").value] || ($("phase").value === "bench" ? M.benchmark : null);
    return bounds ? [Math.max(lo, bounds[0]), Math.min(hi, bounds[1])] : [lo, hi];
  }
  function chart(
    id,
    series,
    { max = 1, label = "Utilization", height = 240 } = {},
  ) {
    const w = 900,
      h = height,
      l = 54,
      r = 42,
      t = 18,
      b = 35,
      xs = (i) => l + (i / Math.max(1, visible.length - 1)) * (w - l - r),
      ys = (v) => h - b - (v / max) * (h - t - b);
    let s = `<svg class="chart" viewBox="0 0 ${w} ${h}" role="img" aria-label="${esc(label)}">`;
    for (let j = 0; j <= 4; j++) {
      let v = (max * j) / 4;
      s += `<path d="M${l} ${ys(v)}H${w - r}" stroke="#e6edf2"/><text x="${l - 7}" y="${ys(v) + 4}" text-anchor="end">${max <= 1 ? num(v * 100, 0) + "%" : num(v, 0)}</text>`;
    }
    for (let j = 0; j <= 4; j++) {
      let i = Math.round(((visible.length - 1) * j) / 4);
      if (i >= 0)
        s += `<text x="${xs(i)}" y="${h - 8}" text-anchor="middle">${num(axisBounds()[0] + (axisBounds()[1]-axisBounds()[0])*j/4, 0)}</text>`;
    }
    series.forEach((line, k) => {
      let path = "",
        open = false;
      line.values.forEach((v, i) => {
        if (v == null) {
          open = false;
          return;
        }
        path += `${open ? "L" : "M"}${xs(i)},${ys(v)} `;
        open = true;
      });
      s += `<path d="${path}" stroke="${line.color || "#1385a3"}" fill="none" stroke-width="${k ? 1.4 : 2.5}"/>`;
    });
    let ix = visible.indexOf(selected);
    s += `<path d="M${xs(ix)} ${t}V${h - b}" stroke="#db9534" stroke-dasharray="4 3"/></svg>`;
    $(id).innerHTML =
      s +
      `<div class="legend">${series.map((x) => `<span style="color:${x.color || "#1385a3"}">● ${esc(x.name)}</span>`).join(" · ")} · x: simulation cycles</div>`;
    const svg = $(id).querySelector("svg");
    svg.onclick = (e) => {
      let q =
        (e.clientX - svg.getBoundingClientRect().left) /
        svg.getBoundingClientRect().width;
      select(
        visible[
          Math.max(
            0,
            Math.min(
              visible.length - 1,
              Math.round(((q * w - l) / (w - l - r)) * (visible.length - 1)),
            ),
          )
        ],
      );
    };
    svg.onmousemove = (e) => {
      let q =
        (e.clientX - svg.getBoundingClientRect().left) /
        svg.getBoundingClientRect().width;
      let i = Math.max(
        0,
        Math.min(
          visible.length - 1,
          Math.round(((q * w - l) / (w - l - r)) * (visible.length - 1)),
        ),
      );
      tip(
        e,
        `Cycle ${F[visible[i]].end}\n` +
          series.map((x) => `${x.name}: ${num(x.values[i], 3)}`).join("\n"),
      );
    };
    svg.onmouseleave = untip;
  }
  function heat(
    id,
    labels,
    value,
    { max = 1, format = (v) => num(v * 100) + "%", details = null, palette = color } = {},
  ) {
    if (!labels.length || !visible.length) {
      empty(id, "No observations available.");
      return;
    }
    const h = Math.max(110, Math.min(700, labels.length * 18 + 32)),
      w = 950,
      l = 100,
      b = 25;
    $(id).innerHTML = '<div class="heatwrap"><canvas></canvas></div>';
    let c = $(id).querySelector("canvas");
    c.width = w;
    c.height = h;
    let ctx = c.getContext("2d"),
      cw = (w - l) / visible.length,
      ch = (h - b) / labels.length;
    labels.forEach((label, j) => {
      visible.forEach((fi, i) => {
        let v = value(fi, j);
        ctx.fillStyle = palette(v == null ? null : v / max);
        ctx.fillRect(l + i * cw, j * ch, Math.max(cw, 1), ch);
      });
      if (ch >= 10) {
        ctx.fillStyle = "#63778b";
        ctx.font = "10px system-ui";
        ctx.fillText(label, 2, j * ch + ch * 0.7);
      }
    });
    ctx.fillStyle = "#63778b";
    ctx.font = "11px system-ui";
    ctx.fillText(`${axisBounds()[0]} cycles`, l, h - 5);
    ctx.fillText(`${axisBounds()[1]}`, w - 75, h - 5);
    ctx.strokeStyle = "#e9a132";
    ctx.lineWidth = 2;
    ctx.strokeRect(
      l + visible.indexOf(selected) * cw,
      0,
      Math.max(cw, 2),
      h - b,
    );
    function hit(e) {
      let rect = c.getBoundingClientRect();
      return [
        Math.min(
          visible.length - 1,
          Math.max(
            0,
            Math.floor((((e.clientX - rect.left) / rect.width) * w - l) / cw),
          ),
        ),
        Math.min(
          labels.length - 1,
          Math.max(
            0,
            Math.floor((((e.clientY - rect.top) / rect.height) * h) / ch),
          ),
        ),
      ];
    }
    c.onmousemove = (e) => {
      let [i, j] = hit(e),
        fi = visible[i],
        v = value(fi, j);
      tip(
        e,
        `${labels[j]} · ${F[fi].start}–${F[fi].end}\n${v == null ? "Unavailable" : format(v)}${details ? "\n" + details(fi, j) : ""}`,
      );
    };
    c.onmouseleave = untip;
    c.onclick = (e) => {
      let [i] = hit(e);
      select(visible[i]);
    };
  }
  function fpu(fi, g = null) {
    let rs = rows(fi, "fpu", g);
    if (
      rs.length &&
      (g !== null || new Set(rs.map((r) => r.g)).size === M.mesh[0] * M.mesh[1])
    )
      return ratio(rs, "busy");
    if (g === null) {
      let overall = rows(fi, "overall");
      return overall.length ? overall.at(-1).util / 100 : null;
    }
    return null;
  }
  function progress(g) {
    let rs = F.slice(0, selected + 1).flatMap((f, i) =>
      (rowIndex[i].get(`work:${g}`) || []).filter(
        (r) => r.phase === "bench" || r.workload_phase === "bench",
      ),
    );
    let expected = M.expected_fmac_per_group?.[g];
    return { done: rs.length ? sum(rs, "fmac") : null, expected };
  }
  function renderOverview() {
    let series = [{ name: "Overall", values: visible.map((i) => fpu(i)) }];
    if ($("groupLines").checked)
      chosen.forEach((g) =>
        series.push({
          name: `G${g}`,
          color: `hsl(${(g * 137.5) % 360} 58% 43%)`,
          values: visible.map((i) => fpu(i, g)),
        }),
      );
    chart("fpuChart", series);
    // Delivered DMA bandwidth per direction, as a fraction of the L2 ceiling.
    chart("axiChart", [
      { name: "AXI read (delivered)", color: "#2487a8", values: visible.map((i) => axiShare(i, "axi_read", "completed_bytes")) },
      { name: "AXI write (delivered)", color: "#a65fa2", values: visible.map((i) => axiShare(i, "axi_write", "completed_bytes")) },
      { name: "AXI read (requested)", color: "#8fc4d6", values: visible.map((i) => axiShare(i, "axi_read", "programmed_bytes")) },
      { name: "AXI write (requested)", color: "#d0aecd", values: visible.map((i) => axiShare(i, "axi_write", "programmed_bytes")) },
    ]);
    let [nx, ny] = M.mesh;
    const mesh = $("mesh");
    mesh.style.gridTemplateColumns = `repeat(${nx},minmax(0,1fr))`;
    mesh.innerHTML = "";
    for (let y = ny - 1; y >= 0; y--)
      for (let x = 0; x < nx; x++) {
        let g = x * ny + y,
          v = fpu(selected, g),
          p = progress(g),
          cell = document.createElement("button");
        cell.className = "groupCell" + (g === group ? " selected" : "");
        cell.style.background = color(v);
        cell.style.color = v > 0.55 ? "white" : "#20334a";
        cell.innerHTML = `G${g} <strong>${v == null ? "—" : num(v * 100) + "%"}</strong><progress max="1" value="${p.done != null && p.expected ? Math.min(1, p.done / p.expected) : 0}"></progress><small>${p.done != null && p.expected ? num((p.done / p.expected) * 100) + "% done" : "Progress unavailable"}</small>`;
        cell.onclick = () => setGroup(g);
        cell.onmousemove = (e) =>
          tip(
            e,
            `G${g} (${x},${y})\nFPU: ${num(v == null ? null : v * 100)}%\nFMAC: ${num(p.done, 0)} / ${num(p.expected, 0)}\n${span(rows(selected, "fpu", g))}`,
          );
        cell.onmouseleave = untip;
        mesh.append(cell);
      }
    heat(
      "fpuHeat",
      Array.from({ length: nx * ny }, (_, i) => `G${i}`),
      (fi, g) => fpu(fi, g),
    );
  }
  function renderMemory() {
    let n = M.mesh[0] * M.mesh[1];
    heat(
      "mshrHeat",
      Array.from({ length: n }, (_, i) => `G${i}`),
      (fi, g) => ratio(rows(fi, "mshr", g), "occupied"),
    );
    const rs = rows(selected, "mshr", group);
    $("mshrTitle").textContent = `Group ${group} MSHR`;
    stats("mshrStats", [
      [
        "Mean occupied",
        rs.length
          ? num(
              sum(rs, "occupied") / rs.reduce((a, r) => a + r.end - r.start, 0),
            )
          : "—",
      ],
      [
        "Peak entries",
        rs.length && rs.every(r => r.peak != null) ? Math.max(...rs.map(r => r.peak)) : "—",
      ],
      ["Full cycles", rs.length && rs.every(r => r.full != null) ? num(sum(rs, "full"), 0) : "—"],
      ["Allocations / merges", rs.length && rs.every(r => r.alloc != null && r.merge != null)
        ? `${num(sum(rs, "alloc"), 0)} / ${num(sum(rs, "merge"), 0)}` : "—"],
      // Hold-window and serve-timeout expiries below the subscriber target: entries that waited
      // out their window instead of being released by a merge. Optional probe.
      [
        "Hold timeouts (single / burst)",
        rs.length && rs.every((r) => r.timeout_single != null)
          ? `${num(sum(rs, "timeout_single"), 0)} / ${num(sum(rs, "timeout_burst"), 0)}`
          : "—",
      ],
      // Subscribers present when a hold window expired: a cohort that never formed sits near
      // zero, one that formed too late sits just below the merge target.
      [
        "Mean subscribers at expiry",
        rs.length &&
        rs.every((r) => r.timeout_subs != null) &&
        sum(rs, "timeout_single") + sum(rs, "timeout_burst") > 0
          ? num(
              sum(rs, "timeout_subs") /
                (sum(rs, "timeout_single") + sum(rs, "timeout_burst")),
            )
          : "—",
      ],
      [
        "Response-hold / cache expiries",
        rs.length && rs.every((r) => r.resp_hold_timeout != null)
          ? `${num(sum(rs, "resp_hold_timeout"), 0)} / ${
              rs.every((r) => r.cache_timeout != null)
                ? num(sum(rs, "cache_timeout"), 0)
                : "—"
            }`
          : "—",
      ],
      // Bankless overflow pool: an entry is taken from it only when the hashed bank had no
      // free way, so any use at all marks inner loops whose cohorts outnumber a bank's ways.
      [
        "Overflow pool (allocs / merges)",
        rs.length && rs.every((r) => r.overflow_alloc != null)
          ? `${num(sum(rs, "overflow_alloc"), 0)} / ${num(sum(rs, "overflow_merge"), 0)}`
          : M.mshr_overflow_entries
            ? "—"
            : "Not configured",
      ],
      [
        "Mean pool entries occupied",
        rs.length && rs.every((r) => r.overflow_occupied != null)
          ? num(
              sum(rs, "overflow_occupied") /
                rs.reduce((a, r) => a + r.end - r.start, 0),
            )
          : M.mshr_overflow_entries
            ? "—"
            : "Not configured",
      ],
    ]);
    const classRatio = (rs, key) => rs.length && rs.every(r => r[key] != null)
      ? ratio(rs, key) : null;
    const classRecorded = visible.some(fi => rows(fi, "mshr").some(r =>
      r.occupied_single != null && r.occupied_burst != null));
    $("mshrClassNote").textContent = classRecorded
      ? "Cycle-by-cycle classification, including entry reuse within a window. Each class uses the full table capacity as denominator; single-word plus burst equals total occupancy. Heatmap rows are groups, columns are time windows; statistics use the selected group/window."
      : "This trace did not record per-window occupancy by request class. Rebuild with the updated dashboard probe for these heatmaps. The whole-run completed-entry counts below are available when MSHRLIFE-BL was printed; they cannot reconstruct occupancy over time.";
    for (const [id, key] of [["mshrSingleHeat", "occupied_single"], ["mshrBurstHeat", "occupied_burst"]]) {
      if (classRecorded) heat(id, Array.from({length: n}, (_, g) => `G${g}`),
        (fi, g) => classRatio(rows(fi, "mshr", g), key));
      else empty(id, "Per-window class counters were not collected.");
    }
    const pct = v => v == null ? "Unavailable" : num(v * 100, 2) + "%";
    const target = kind => rs.at(-1)?.[kind + "_merge_target"] ?? M.software_merge_targets?.[kind];
    const policy = kind => target(kind) == null ? "Not captured" : `${target(kind)}${target(kind) === 1 ? " (bypass)" : " (merge target)"}`;
    const policySource = rs.at(-1)?.single_merge_target != null ? "sampled at window end" : "compiled policy from ELF";
    stats("mshrClassStats", [
      ["Single-word / full table capacity", pct(classRatio(rs, "occupied_single"))],
      ["Burst / full table capacity", pct(classRatio(rs, "occupied_burst"))],
      ["Single-word target: " + policySource, policy("single")],
      ["Burst target: " + policySource, policy("burst")],
    ]);
    const life = M.mshr_lifetime_classes?.[`${Math.floor(group / M.mesh[1])},${group % M.mesh[1]}`];
    if (life) table("mshrClassLifetime", ["Class", "Completed entries (whole run)", "Mean first-response-to-free cycles"],
      ["single", "burst"].map(k => [k === "single" ? "Single-word" : "Burst",
        num(life[`drain_${k}_n`], 0), life[`drain_${k}_n`] > 0
          ? num(life[`drain_${k}_sum`] / life[`drain_${k}_n`], 2) : "Not applicable: no completed entries"]));
    else empty("mshrClassLifetime", "No MSHRLIFE-BL completed-entry counters in this trace.");
    // The original timeline also shows both classes when measurements exist.
    chart("mshrTimeline", [
      { name: "Total occupancy", values: visible.map(i => ratio(rows(i, "mshr", group), "occupied")) },
      ... (classRecorded ? ["single", "burst"].map(k => ({
        name: k === "single" ? "Single-word" : "Burst",
        values: visible.map(i => classRatio(rows(i, "mshr", group), "occupied_" + k)),
      })) : []),
    ], {height: 180});
    const stages = rows(selected, "stage", group);
    if (stages.length)
      table(
        "stageStats",
        ["Stage / tile", "Accepted", "Stalled", "Active cycles"],
        stages.map((r) => [
          r.label + (r.t >= 0 ? " T" + r.t : ""),
          r.hsk,
          r.stall,
          r.active,
        ]),
      );
    else empty("stageStats", "No pipeline-stage counters in this window.");
    const entries = [
        ...new Set(
          F.flatMap((f) =>
            f.rows
              .filter((r) => r.kind === "entry" && r.g === group)
              .map((r) => r.entry),
          ),
        ),
      ].sort((a, b) => a - b),
      metric = $("entryMetric").value,
      // Timeout metrics are counts of expiries, not a fraction of the window.
      counting = metric.startsWith("timeout"),
      entryValue = (fi, j) => {
        let rs = rows(fi, "entry", group).filter((r) => r.entry === entries[j]);
        return rs.length && rs.every((r) => r[metric] != null)
          ? metric === "state"
            ? rs.at(-1).state
            : counting
              ? sum(rs, metric)
              : sum(rs, metric) / rs.reduce((a, r) => a + r.end - r.start, 0)
          : null;
      },
      entryPeak = counting
        ? Math.max(
            1,
            ...visible.flatMap((fi) =>
              entries.map((_, j) => entryValue(fi, j) || 0),
            ),
          )
        : 1;
    if (entries.length)
      heat(
        "entryHeat",
        entries.map((e) =>
          M.mshr_entries && e >= M.mshr_entries
            ? `Pool ${e - M.mshr_entries}` // bankless: no bank/way label applies
            : M.mshr_ways
              ? `B${Math.floor(e / M.mshr_ways)} W${e % M.mshr_ways}`
              : `Entry ${e}`,
        ),
        entryValue,
        {
          max: metric === "state" ? 4 : counting ? entryPeak : 1,
          format: (v) =>
            metric === "state"
              ? ["Free", "Waiting", "Draining", "Cached", "Response hold"][v] ||
                String(v)
              : counting
                ? num(v, 0) + (v === 1 ? " timeout" : " timeouts")
                : num(100 * v) + "%",
        },
      );
    else
      empty(
        "entryHeat",
        "This trace has no individual-entry telemetry. Enable the optional dashboard probe for entry occupancy and state history.",
      );
    const banks = [
      ...new Set(
        F.flatMap((f) =>
          f.rows
            .filter((r) => r.kind === "bank" && r.g === group)
            .map((r) => `${r.t}:${r.bank}`),
        ),
      ),
    ].sort((a, b) => {
      let [x, y] = a.split(":").map(Number),
        [u, v] = b.split(":").map(Number);
      return x - u || y - v;
    });
    let bm = $("bankMetric").value;
    const bv = (fi, j) => {
      let [t, b] = banks[j].split(":").map(Number),
        rs = rows(fi, "bank", group).filter((r) => r.t === t && r.bank === b);
      return rs.length
        ? sum(rs, bm) / rs.reduce((a, r) => a + r.end - r.start, 0)
        : null;
    };
    if (banks.length) {
      table(
        "bankGrid",
        ["Tile / bank", "Current " + bm, "Source interval"],
        banks.map((key, j) => [
          key,
          num(bv(selected, j), 3),
          span(
            rows(selected, "bank", group).filter(
              (r) => `${r.t}:${r.bank}` === key,
            ),
          ),
        ]),
      );
      $("bankGrid").style.maxHeight = "240px";
      $("bankGrid").style.overflow = "auto";
      heat(
        "bankHeat",
        banks.map((x) => "T:B " + x),
        bv,
      );
    } else {
      empty(
        "bankGrid",
        "Per-bank observations are unavailable. Existing BP bank records sum all banks within a tile.",
      );
      $("bankHeat").innerHTML = "";
    }
  }
  // Keep the scale fixed across windows and networks for direct comparison.
  function nocColor(v) {
    if (v == null) return "#aeb8c2";
    if (v === 0) return "#ffffff";
    let t = Math.min(1, Math.max(0, v));
    if ($("nocScale").value === "log")
      t = Math.log1p(t / 0.0001) / Math.log1p(10000);
    const stops = [[68, 1, 84], [59, 82, 139], [33, 145, 140],
      [94, 201, 98], [253, 231, 37]];
    const x = t * (stops.length - 1), i = Math.min(3, Math.floor(x));
    return `rgb(${stops[i].map((v, c) =>
      Math.round(v + (stops[i + 1][c] - v) * (x - i))).join(",")})`;
  }
  function physicalLink(r) {
    if (M.torus) return true;
    const [nx, ny] = M.mesh, x = Math.floor(r.g / ny), y = r.g % ny;
    const [dx, dy] = [[0, 1], [1, 0], [0, -1], [-1, 0]][r.direction];
    return x + dx >= 0 && x + dx < nx && y + dy >= 0 && y + dy < ny;
  }
  function renderNoc() {
    let net = $("network").value,
      sub = $("subnet").value,
      metric = $("linkMetric").value,
      rs = now("link").filter(
        (r) => physicalLink(r) && r.network === net && (sub === "all" || String(r.subnet) === sub),
      );
    $("nocLegend").innerHTML = [null, 0, 0.0001, 0.001, 0.01, 0.1, 1]
      .map(v => `<span><i style="background:${nocColor(v)}"></i>${v == null
        ? "Unavailable" : num(v * 100, 2) + "%"}</span>`).join("");
    const capacity = rs.reduce((n, r) => n + r.end - r.start, 0);
    stats("nocStats", [
      ["Mean physical-link utilization", capacity ? num(100 * sum(rs, "hsk") / capacity, 3) + "%" : "Unavailable"],
      ["Selected-window transfers", rs.length ? num(sum(rs, "hsk"), 0) : "Unavailable"],
      ["Backpressured link-cycles", rs.length ? num(sum(rs, "stall"), 0) : "Unavailable"],
      ["Link counter records", rs.length],
    ]);
    let [nx, ny] = M.mesh,
      w = 850,
      h = 400,
      pad = 60,
      px = (x) => pad + (x / Math.max(1, nx - 1)) * (w - 2 * pad),
      py = (y) => h - pad - (y / Math.max(1, ny - 1)) * (h - 2 * pad);
    if (!rs.length)
      empty(
        "nocMesh",
        "No directional link counters in this window. Legacy endpoint counts cannot establish per-link congestion.",
      );
    else {
      let svg = `<svg class="chart" viewBox="0 0 ${w} ${h}"><defs><marker id="arrow" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto"><path d="M0 0L6 3L0 6" fill="#687b8f"/></marker></defs>`;
      for (let g = 0; g < nx * ny; g++) {
        let x = Math.floor(g / ny),
          y = g % ny;
        for (let d = 0; d < 4; d++) {
          let [dx, dy] = [
              [0, 1],
              [1, 0],
              [0, -1],
              [-1, 0],
            ][d],
            xx = x + dx,
            yy = y + dy;
          if (M.torus) {
            xx = (xx + nx) % nx;
            yy = (yy + ny) % ny;
          }
          if (xx < 0 || yy < 0 || xx >= nx || yy >= ny) continue;
          let link = rs.filter((r) => r.g === g && r.direction === d),
            dur = link.reduce((a, r) => a + r.end - r.start, 0),
            v = dur ? sum(link, metric) / dur : null;
          svg += `<path d="M${px(x) + dy * 5} ${py(y) + dx * 5}L${px(xx) - dx * 20 + dy * 5} ${py(yy) + dy * 20 + dx * 5}" stroke="${nocColor(v)}" stroke-width="${v == null ? 2 : 3 + v * 6}" marker-end="url(#arrow)"><title>G${g} → G${xx * ny + yy}, ${net}, ${metric}: ${num(v == null ? null : v * 100, 4)}%; ${sum(link, "hsk")} transfers; ${span(link)}</title></path>`;
        }
      }
      for (let g = 0; g < nx * ny; g++) {
        let x = Math.floor(g / ny),
          y = g % ny;
        svg += `<g data-g="${g}" style="cursor:pointer"><circle cx="${px(x)}" cy="${py(y)}" r="18" fill="${g === group ? "#f3b651" : "#edf3f7"}" stroke="#aebfce"/><text x="${px(x)}" y="${py(y) + 4}" text-anchor="middle">${g}</text></g>`;
      }
      svg += "</svg>";
      $("nocMesh").innerHTML = svg;
      $("nocMesh")
        .querySelectorAll("[data-g]")
        .forEach((el) => (el.onclick = () => setGroup(+el.dataset.g)));
    }
    let subs = [
      ...new Set(
        F.flatMap((f) =>
          f.rows
            .filter((r) => r.kind === "link" && r.network === net)
            .map((r) => r.subnet),
        ),
      ),
    ].sort((a, b) => a - b);
    heat(
      "nocHeat",
      subs.map((s) => `${net} ${s}`),
      (fi, j) => {
        let a = rows(fi, "link").filter(
          (r) => physicalLink(r) && r.network === net && r.subnet === subs[j],
        );
        return a.length
          ? sum(a, metric) / a.reduce((v, r) => v + r.end - r.start, 0)
          : null;
      },
      { palette: nocColor, format: v => num(v * 100, 4) + "%" },
    );
    let tr = now("traffic");
    const responseRatio = records => {
      if (!records.length || records.some(r =>
        !r.mst_resp?.length || !r.slv_resp?.length)) return "Unavailable";
      const total = k => records.reduce((n, r) =>
        n + r[k].reduce((a, b) => a + b, 0), 0);
      const denominator = total("slv_resp");
      return denominator ? num(total("mst_resp") / denominator, 3) + "×"
        : "Undefined (no serving responses)";
    };
    stats("multicastStats", [
      ["Window multicast/reuse factor", responseRatio(tr)],
      ["Benchmark multicast/reuse factor", responseRatio(F.flatMap(f =>
        f.rows.filter(r => r.kind === "traffic" && r.phase === "bench")))],
    ]);
    if (tr.length)
      table(
        "endpointChart",
        ["Boundary", "Words / transfers"],
        ["mst_req", "mst_resp", "slv_req", "slv_resp"].map((k) => [
          k,
          tr.some((r) => r[k]?.length)
            ? num(tr.reduce((n, r) => n + (r[k] || []).reduce((a, b) => a + b, 0), 0), 0)
            : "Unavailable",
        ]),
      );
    else empty("endpointChart", "No endpoint traffic counters in this window.");
  }
  function bars(id, sets) {
    let max = Math.max(1, ...sets.flatMap((s) => s.histogram)),
      n = sets[0].histogram.length,
      w = 600,
      h = 200,
      l = 30,
      b = 25;
    let s = `<svg class="chart" viewBox="0 0 ${w} ${h}">`;
    sets.forEach((set, k) =>
      set.histogram.forEach((v, i) => {
        let bw = (w - l) / n / sets.length;
        s += `<rect x="${l + (i * (w - l)) / n + k * bw}" y="${h - b - (v / max) * (h - b - 10)}" width="${bw * 0.8}" height="${(v / max) * (h - b - 10)}" fill="${k ? "#d79a40" : "#188ca6"}"><title>${esc(set.name)} bank ${i}: ${num(v)}</title></rect>`;
      }),
    );
    for (let i = 0; i < n; i++)
      s += `<text x="${l + ((i + 0.5) * (w - l)) / n}" y="${h - 5}" text-anchor="middle">${i}</text>`;
    s +=
      '</svg><div class="legend">' +
      sets.map((x, i) => `${i ? "Gold" : "Blue"}: ${esc(x.name)}`).join(" · ") +
      "</div>";
    $(id).innerHTML = s;
  }
  function renderDiagnostics() {
    const d = D.diagnostics;
    if (!d?.available) {
      empty("diagnosticSummary", d?.reason || "Regenerate to include benchmark diagnostics.");
      return;
    }
    const pct = v => v == null ? "Unavailable" : num(v * 100, 1) + "%";
    const names = gs => gs.map(g => `G${g}`).join(", ");
    const tail = d.tail;
    stats("diagnosticSummary", [
      ["Last groups with FMAC work", tail ? names(tail.groups) : d.tail_status === "no_resolved_tail" ? "Same completion window" : "Incomplete work coverage"],
      ["Benchmark cycles after other groups finish", tail ? pct(tail.cycle_fraction) : d.tail_status === "no_resolved_tail" ? "No resolved tail" : "Unavailable"],
      ["Assigned FMAC work remaining at that point", tail ? pct(tail.remaining_work_fraction) : d.tail_status === "no_resolved_tail" ? "No resolved tail" : "Unavailable"],
    ]);
    const facts = [];
    if (d.completion_summary) facts.push(`All groups have complete FMAC coverage and match their assigned totals. Completion-window ends span ${d.completion_summary.first_end}–${d.completion_summary.last_end} cycles.`);
    if (d.tail_status === "no_resolved_tail") facts.push("All groups finish in the same sampled window. There is no separately resolved tail; this does not mean their exact completion cycles are identical.");
    if (tail) facts.push(`By cycle ${tail.start}, all groups except ${names(tail.groups)} have completed their assigned FMACs. The remaining benchmark interval ends at ${tail.end}. Boundaries are limited by source-window resolution; this is not a predicted speedup.`);
    if (d.hold_outliers.length) facts.push(`${names(d.hold_outliers)} spend over half their occupied entry-cycles holding unissued fetches, and more than twice the group-median fraction (${pct(d.median_held_share)}).`);
    if (d.hash_matches_best_groups.length === d.groups.length)
      facts.push("Every group's current hash matches the best modeled bank spread among the tested legal candidates. The model does not single out the late groups as hash outliers.");
    else facts.push(`${d.hash_matches_best_groups.length}/${d.groups.length} groups match the best tested hash spread. A model improvement is a candidate to test, not a measured speedup.`);
    $("diagnosticFindings").innerHTML = facts.map(x => `<li>${esc(x)}</li>`).join("");
    table("diagnosticGroups", ["Group", "Final FMAC interval (cycles)", "Done at tail start", "Mean MSHR occupancy", "Held / occupied", "Peak entries", "Table-full cycles"], d.groups.map(g => [
      `G${g.g}${g.g === group ? " (selected)" : ""}`,
      g.completion ? g.completion.join("–") : "Not established",
      (d.tail_status === "no_resolved_tail" ? "Not applicable" : pct(g.progress_at_tail)), pct(g.occupancy), pct(g.held_share),
      num(g.peak, 0), num(g.full_cycles, 0),
    ]));
    $("diagnosticGroups").querySelectorAll("tbody tr").forEach((el, i) => {
      el.style.cursor = "pointer";
      el.onclick = () => setGroup(d.groups[i].g);
    });
    const g = d.groups.find(g => g.g === group);
    $("diagnosticGroupTitle").textContent = `G${group}: evidence and possible causes`;
    const score = key => g.hash[key] ? `${num(g.hash[key].current)} / ${num(g.hash[key].best)} banks` : "Unavailable";
    table("diagnosticSelected", ["Measurement / model", "Value"], [
      ["Complete benchmark work / occupancy coverage", `${g.work_coverage ? "Yes" : "No"} / ${g.mshr_coverage ? "Yes" : "No"}`],
      ["A hash spread: current / best tested", score("a")],
      ["B hash spread: current / best tested", score("w")],
      ["Modeled A accesses served within this group", pct(g.locality?.a)],
      ["Modeled B accesses served within this group", pct(g.locality?.b)],
      ["Mean fetch-hold duration (whole-run lifetime counters)", num(g.lifetime.hold, 2) + " cycles"],
      ["Mean fetch-to-first-response duration (whole-run lifetime counters)", num(g.lifetime.flight, 2) + " cycles"],
      ["Mean response-drain duration (whole-run lifetime counters)", num(g.lifetime.drain, 2) + " cycles"],
    ]);
    $("diagnosticHypothesis").textContent = d.hold_outliers.includes(group)
      ? "Prioritize fetch-hold/subscriber arrival timing. Long unissued residency is direct evidence; a hash bottleneck is not established. Local versus remote operand accesses can alter arrival alignment, but locality alone does not prove the cause. Compare a shorter hold window with the baseline while retaining the subscriber target, then test operand placement separately. Capture hold-release reasons and bank allocation stalls to distinguish deliberate waiting, replay backpressure and hash conflicts."
      : "Compare this group's completion and unissued residency with the late groups. Test hash changes only as controlled candidates, using the same workload and correctness checks. Whole-table occupancy alone cannot diagnose per-bank conflicts.";
    $("diagnosticNotes").innerHTML = d.notes.map(x => `<li>${esc(x)}</li>`).join("");
  }
  function renderHash() {
    let h = D.hash;
    if (!h.available) {
      empty("hashSummary", h.reason);
      return;
    }
    $("hashNote").textContent = h.note + (M.software_merge_targets?.single === 1
      ? " The compiled software policy bypasses single-word requests (merge target 1). The single-class hash plot is hypothetical bank spread, not observed scalar MSHR usage." : "");
    let g = h.groups.find((x) => x.g === group);
    if (!g) {
      // Reduced active sets model only the groups that run the kernel.
      empty("hashSummary", `Group ${group} does not run the kernel in this run: ${h.active_groups ?? h.groups.length} of ${h.mesh_groups ?? M.mesh[0] * M.mesh[1]} groups are active. Select an active group for the modeled hash distribution.`);
      for (const id of ["hashSharing", "hashA", "hashW", "hashCandidates", "hashObserved"])
        empty(id, "Inactive group: no modeled or observed hash distribution.");
      return;
    }
    stats("hashSummary", [
      ["MSHR banks", h.banks],
      ["Burst model", h.burst_model || "Not specified"],
      ["B requests modeled (this group)", g.request_counts ? `${g.request_counts.burst} bursts / ${g.request_counts.single} singles` : "Unavailable"],
      ["Reduction steps modeled", `${h.sampled_steps} / ${h.total_steps}`],
      ["Software kernel size (rows)", M.kernel_size ?? M.hash?.kernel ?? "Unavailable"],
    ]);
    const sharing = g.sharing;
    if (sharing) {
      const degree = (x) => x.minimum === x.maximum
        ? `${num(x.mean, 2)} cores` : `${num(x.mean, 2)} mean (${x.minimum}–${x.maximum})`;
      const sampled = rows(selected, "mshr", group).at(-1);
      const target = k => sampled?.[k + "_merge_target"] ?? M.software_merge_targets?.[k];
      const targetText = k => target(k) == null ? "Not captured"
        : `${target(k)}${target(k) === 1 ? " — bypass table" : " — subscriber target"}`;
      table("hashSharing", ["Operand", "Potential cores sharing each element", "MSHR target / policy", "Distinct operand tiles/group"], [
        ["Matrix A", degree(sharing.a), targetText("single"), sharing.a.distinct_tiles],
        ["Matrix B (weights)", degree(sharing.b), g.request_counts?.single ? `Single: ${targetText("single")}; burst: ${targetText("burst")}` : targetText("burst"), sharing.b.distinct_tiles],
      ]);
      $("sharingNote").textContent = `${sharing.cores} cores/group; each core computes a ${sharing.kernel_rows} × ${sharing.columns_per_core} output tile. Sharing follows the workload partition: A is shared across column tiles, B across row tiles. This is potential same-element sharing, not measured simultaneous accesses or achieved MSHR merging. The MSHR target is a separate software policy: 1 means bypass, not one physical sharer. Targets are ${sampled?.single_merge_target != null ? "captured simulator CSR settings" : "compiled ELF policy when available"}; they are not measured multicast factors.`;
    }
    for (let [k, list, current] of [
      ["hashA", g.singles, g.current_a],
      ["hashW", g.weights, g.current_w],
    ]) {
      bars(k, [
        ...(current ? [{ ...current, name: "Current hash" }] : []),
        { ...list[0], name: "Best legal spread" },
      ]);
    }
    table(
      "hashCandidates",
      ["Access", "Shift", "Burst bits", "Concurrent banks"],
      [
        ["Singles (A + scalar B)", g.singles],
        ["Bursts (B)", g.weights],
      ].flatMap(([kind, list]) =>
        list.map((c) => [
          kind,
          c.shift,
          c.burst_bits,
          num(c.concurrent_banks) + " / " + h.banks,
        ]),
      ),
    );
    if (g.concurrency) {
      let c = g.concurrency,
        pool = h.overflow_entries || 0;
      bars("hashConcurrency", [
        {
          name: "Singles (A + scalar B) in one k step",
          histogram: c.banks.map((b) => b.single),
        },
        { name: "Bursts (B) in one k step", histogram: c.banks.map((b) => b.burst) },
      ]);
      $("hashConcurrencyNote").textContent =
        `Modeled lines of reduction step ${c.step} placed by the current hash. The busiest bank holds ${c.busiest} concurrent lines against ${c.ways} ways` +
        (pool ? ` plus ${pool} bankless overflow ${pool === 1 ? "entry" : "entries"} shared by every bank` : "") +
        ". " +
        (c.over_ways
          ? `${c.over_ways} of ${h.banks} banks need more entries than they have ways. Those cohorts cannot all be resident at once: a request hashing to a full bank waits for a hold window to expire, even when the entry it would merge with is the one being waited for.`
          : "No bank needs more entries than it has ways, so every inner-loop cohort can be resident at once.") +
        " Modeled addresses for one step, not measured allocations.";
    } else
      empty(
        "hashConcurrency",
        "Per-bank concurrency requires the configured shift and burst bits for this group.",
      );
    let rs = rows(selected, "entry", group);
    if (rs.length) {
      let ways = h.entries / h.banks,
        hist = Array(h.banks).fill(0),
        pool = 0;
      // Pool entries (ids at or above the banked table) belong to no bank: binning them by
      // entry/ways would invent occupancy in a bank that never held the line.
      rs.forEach((r) => {
        if (r.entry >= h.entries) pool += r.occupied / (r.end - r.start);
        else hist[Math.floor(r.entry / ways)] += r.occupied / (r.end - r.start);
      });
      if (hist.some((value) => value > 0))
        bars("hashObserved", [
          {
            name: pool
              ? `Observed mean occupied entries (plus ${num(pool, 2)} in the bankless pool)`
              : "Observed mean occupied entries",
            histogram: hist,
          },
        ]);
      else
        empty(
          "hashObserved",
          "Selected window has measured entry telemetry but zero MSHR occupancy. Choose another time window.",
        );
    } else
      empty(
        "hashObserved",
        "Observed per-bank occupancy requires entry telemetry. The charts above are modeled address distributions.",
      );
  }
  function renderDma() {
    const dma = M.dma;
    if (!dma) {
      for (const id of ["dmaSummary", "dmaPhases", "dmaChart", "dmaSchedule", "dmaTiles", "dmaInterfaces"])
        empty(id, "DMA measurements were not collected for this run.");
      return;
    }
    $("dmaNote").textContent = dma.note;
    const bytes = dma.programmed_bytes || {};
    if (dma.channels) {
      // Bus-side observation: what each interface moved, and how much of the
      // benchmark it was busy at all.
      stats(
        "dmaSummary",
        Object.entries(dma.channels).flatMap(([name, c]) => [
          [`${name}: delivered bytes`, num(c.completed_bytes, 0)],
          [`${name}: requested bytes`, num(c.programmed_bytes, 0)],
          [`${name}: bursts`, num(c.transactions, 0)],
          [`${name}: mean bytes/cycle`, num(c.bytes_per_cycle, 2)],
          [
            `${name}: windows with traffic`,
            `${num(c.active_windows, 0)} of ${num(c.windows, 0)}`,
          ],
        ]),
      );
    } else {
      stats("dmaSummary", [
        ["Weights: programmed bytes", num(bytes.weights, 0)],
        ["Inputs: programmed bytes", num(bytes.inputs, 0)],
        ["Outputs: programmed bytes", num(bytes.outputs, 0)],
        ["Reuse-guard timer cycles", num(dma.reuse_guard_cycles, 0)],
        ["Observed post-compute wait checks", num(dma.wait_check_cycles, 0)],
      ]);
    }
    if (!dma.projections && dma.channels)
      empty("dmaPhases", "Per-projection accounting needs application-supplied DMA metadata; the interface totals above are measured.");
    else
    table("dmaPhases", ["Projection", "Cycles", "Useful utilization", "FPU busy", "Whole-system scope"],
      Object.entries(dma.projections || {}).map(([name, p]) => [name,
        num(p.cycles, 0), num(100*p.utilization, 2)+"%",
        num(100*p.fpu_busy_utilization, 2)+"%", "Includes fill, joins and output writeback"]));
    const wait = i => {
      const rs = rows(i, "dma").filter(r => r.measurement === "software" && r.scope === "global" && r.wait_check_cycles != null);
      return rs.length ? sum(rs, "wait_check_cycles")/sum(rs.map(r => ({width:r.end-r.start})), "width") : null;
    };
    const dmaSeries = [{name:"Overall FPU busy", values:visible.map(i => fpu(i))}];
    if (dma.channels)
      Object.keys(dma.channels).forEach((name, n) =>
        dmaSeries.push({
          name: `${name} delivered (of L2 roof)`,
          color: ["#2487a8", "#a65fa2"][n % 2],
          values: visible.map((i) => axiShare(i, name, "completed_bytes")),
        }));
    else
      dmaSeries.push({name:"Post-compute DMA wait-check fraction", color:"#c67b24", values:visible.map(wait)});
    chart("dmaChart", dmaSeries);
    const [lo, hi] = axisBounds(), width = Math.max(1, hi-lo);
    const tiles = (dma.tiles || []).filter(t => t.begin < hi && t.ready > lo);
    const colors = ["#2487a8", "#a65fa2", "#d2932e"];
    let svg = '<svg class="chart" viewBox="0 0 1000 130" role="img" aria-label="Software double-buffer schedule">';
    for (let slot=0; slot<2; ++slot) svg += `<text x="0" y="${35+slot*42}">Buffer ${slot}</text>`;
    const x = cycle => 85+900*(Math.max(lo, Math.min(hi, cycle))-lo)/width;
    for (const t of tiles) {
      const edges = [t.begin, t.compute_end, t.joined, t.ready];
      for (let i=0; i<3; ++i) if (edges[i+1] > lo && edges[i] < hi)
        svg += `<rect x="${x(edges[i])}" y="${16+t.buffer*42}" width="${Math.max(0, x(edges[i+1])-x(edges[i]))}" height="28" fill="${colors[i]}"><title>${esc(t.projection)} panel ${t.p} K tile ${t.k}: ${edges[i]}–${edges[i+1]}</title></rect>`;
    }
    svg += `<text x="85" y="116">${num(lo,0)}</text><text x="980" y="116" text-anchor="end">${num(hi,0)} cycles</text></svg>`;
    $("dmaSchedule").innerHTML = svg+'<div class="legend">Blue: launch + core 0 compute · Purple: remaining join · Amber: DMA wait check. Blank intervals are not classified.</div>';
    table("dmaTiles", ["Projection", "Panel / K tile", "Buffer", "Launch + core 0 compute", "Remaining join", "Wait check"],
      tiles.slice(0, 100).map(t => [t.projection, `${t.p} / ${t.k}`, t.buffer,
        t.compute_end-t.begin, t.joined-t.compute_end, t.ready-t.joined]));
    const counters = now("dma").filter(r => r.measurement !== "software");
    if (!counters.length) empty("dmaInterfaces", "DMA channel activity, payload handshakes and bus stalls: unavailable. This capture contains software timing and byte accounting only.");
    else table("dmaInterfaces", ["Scope / channel", "Measurement", "Completed bytes", "Active cycles", "Stall cycles"],
      counters.map(r => [r.scope === "global" ? "Whole system" : r.channel, r.measurement,
        num(r.completed_bytes,0), num(r.active_cycles,0), num(r.stall_cycles,0)]));
  }
  function renderRoof() {
    let r = D.roofline;
    if (!r.available) {
      empty("roofChart", r.reason);
      return;
    }
    let boundary = $("roofBoundary").value,
      roof = r.roofs.find((x) => x.boundary === boundary),
      point = r.points.find((x) => x.boundary === boundary),
      points = [];
    if (point)
      points.push({
        name: r.estimated_ai ? "Whole run (estimated AI)" : "Whole run",
        x: point.ai,
        y: r.performance,
        color: "#137d9e",
      });
    if ($("roofWindow").checked) {
      let work = now("work"),
        traffic = now("traffic"),
        key =
          boundary === "demand"
            ? "mst_resp"
            : boundary === "mesh"
              ? "slv_resp"
              : null;
      if (work.length && traffic.length && key) {
        let intervals = new Set(
          [...work, ...traffic].map((x) => `${x.start}:${x.end}`),
        );
        if (intervals.size === 1) {
          let bytes =
              4 *
              traffic.reduce(
                (a, x) => a + x[key].reduce((b, c) => b + c, 0),
                0,
              ),
            flops = 2 * sum(work, "fmac");
          if (bytes && flops)
            points.push({
              name: "Selected interval",
              x: flops / bytes,
              y: flops / (work[0].end - work[0].start),
              color: "#d79232",
            });
        }
      }
    }
    let w = 950,
      h = 340,
      l = 70,
      b = 45,
      t = 25,
      xmin = -2,
      xmax = Math.max(4, ...points.map((p) => Math.ceil(Math.log2(p.x)) + 1)),
      ymin = 0,
      ymax = Math.ceil(Math.log2(r.peak)) + 1,
      xx = (x) => l + ((Math.log2(x) - xmin) / (xmax - xmin)) * (w - l - 30),
      yy = (y) => h - b - ((Math.log2(y) - ymin) / (ymax - ymin)) * (h - b - t);
    let s = `<svg class="chart" viewBox="0 0 ${w} ${h}" role="img" aria-label="Roofline in FLOP per cycle and FLOP per byte">`;
    for (let x = xmin; x <= xmax; x += 2)
      s += `<path d="M${xx(2 ** x)} ${t}V${h - b}" stroke="#e8edf2"/><text x="${xx(2 ** x)}" y="${h - b + 18}" text-anchor="middle">${num(2 ** x, 2)}</text>`;
    for (let y = ymin; y <= ymax; y += 2)
      s += `<path d="M${l} ${yy(2 ** y)}H${w - 30}" stroke="#e8edf2"/><text x="${l - 8}" y="${yy(2 ** y) + 4}" text-anchor="end">${num(2 ** y, 0)}</text>`;
    s += `<path d="M${l} ${yy(r.peak)}H${w - 30}" stroke="#7b8794" stroke-dasharray="5 4"/><text x="${w - 230}" y="${yy(r.peak) - 8}">${M.compute_precision || M.precision} peak: ${num(r.peak, 0)}</text>`;
    let x0 = 2 ** xmin,
      x1 = 2 ** xmax,
      knee = r.peak / roof.bandwidth;
    let path = "";
    for (let i = 0; i <= 100; i++) {
      let x = 2 ** (xmin + ((xmax - xmin) * i) / 100),
        y = Math.min(r.peak, roof.bandwidth * x);
      path += `${i ? "L" : "M"}${xx(x)} ${yy(Math.max(1, y))}`;
    }
    s += `<path d="${path}" fill="none" stroke="#166f87" stroke-width="3"/>`;
    points.forEach(
      (p) =>
        (s += `<circle cx="${xx(p.x)}" cy="${yy(p.y)}" r="7" fill="${p.color}" stroke="white" stroke-width="2"><title>${esc(p.name)}: ${num(p.x, 3)} FLOP/B, ${num(p.y)} FLOP/cycle</title></circle>`),
    );
    s += `<text x="${w / 2}" y="${h - 3}" text-anchor="middle">${esc(roof.name)} arithmetic intensity (FLOP/byte, log₂)</text><text x="${l}" y="14">FLOP/cycle (log₂)</text></svg>`;
    $("roofChart").innerHTML =
      s +
      `<p class="hint">${esc(roof.name)}: ${num(roof.bandwidth)} B/cycle. ${points.length ? points.map((p) => esc(p.name)).join(" · ") : "No measured intensity at this byte boundary."}</p>`;
    stats("roofStats", [
      ["Whole-run FLOP/cycle", num(r.performance)],
      [
        "Compute peak efficiency",
        r.performance ? num((r.performance / r.peak) * 100) + "%" : "—",
      ],
      ["Measured merge factor", num(r.merge_factor, 2)],
      ["Correctness", M.correctness],
    ]);
    if (r.estimated_ai) $("roofStats").insertAdjacentHTML("afterend", "");
  }
  function renderSources() {
    const counts = {};
    F.forEach((f) =>
      f.rows.forEach((r) => (counts[r.kind] = (counts[r.kind] || 0) + 1)),
    );
    table("coverage", ["Record type", "Records"], Object.entries(counts));
    $("warnings").innerHTML =
      D.warnings.map((w) => `<li>${esc(w)}</li>`).join("") ||
      "<li>No parser warnings.</li>";
    table(
      "sourceFiles",
      ["File", "Bytes"],
      D.sources.map((x) => [x.path, num(x.bytes, 0)]),
    );
    $("metadata").textContent = JSON.stringify(M, null, 2);
    $("raw").textContent = JSON.stringify(
      F[selected].rows.filter(phase),
      null,
      2,
    );
  }
  function render() {
    if (!visible.length) return;
    let rs = rows(selected, "fpu"),
      p = progress(group);
    const roof = D.roofline;
    stats("benchmarkSummary", [
      ["Benchmark FPU utilization (ideal / actual)", roof.benchmark_compute_utilization == null ? "Unavailable" : num(100*roof.benchmark_compute_utilization, 2)+"%"],
      ["Ideal compute cycles", num(roof.ideal_cycles, 2)],
      ["Actual benchmark cycles", num(roof.benchmark_cycles, 0)],
    ]);
    $("benchmarkDefinition").textContent = M.workload?.definition ? `${M.workload.definition}. Useful work excludes padding; FMAC progress includes executed padded outputs. Busy lanes are a separate measure.` : "Ideal cycles = 2 × M × N × P × repetitions / peak FLOPs per cycle (including precision-dependent SIMD throughput). This workload-based utilization is separate from the busy-lane percentages plotted below.";
    stats("summary", [
      [
        "Current overall FPU",
        num(fpu(selected) == null ? null : fpu(selected) * 100) + "%",
      ],
      ["Selected group", `G${group}`],
      ["Group completed FMAC", num(p.done, 0)],
      [
        "Group progress",
        p.done != null && p.expected
          ? num((p.done / p.expected) * 100) + "%"
          : "Unavailable",
      ],
    ]);
    $("time").value = visible.indexOf(selected);
    $("timeLabel").textContent =
      `${num(Math.max(F[selected].start, axisBounds()[0]), 0)}–${num(Math.min(F[selected].end, axisBounds()[1]), 0)} cycles`;
    ({
      overview: renderOverview,
      memory: renderMemory,
      noc: renderNoc,
      hash: renderHash,
      diagnostics: renderDiagnostics,
      dma: renderDma,
      roof: renderRoof,
      sources: renderSources,
    })[tab]();
  }
  function select(i) {
    selected = i;
    render();
  }
  function setGroup(g) {
    group = g;
    $("group").value = g;
    chosen.add(g);
    $("lineGroups")
      .querySelectorAll("input")
      .forEach((x) => (x.checked = chosen.has(+x.value)));
    render();
  }
  function filter() {
    visible = F.map((f, i) => (f.rows.some(phase) ? i : null)).filter(
      (i) => i !== null,
    );
    document.querySelector("main").classList.toggle("noPhase", !visible.length);
    $("phaseEmpty").hidden = !!visible.length;
    if (!visible.length) {
      $("time").max = 0;
      $("timeLabel").textContent = "No records in this phase";
      return;
    }
    if (!visible.includes(selected)) {
      selected = visible.find((i) => rows(i, "fpu").length || rows(i, "link").length) ?? visible[0];
    }
    $("time").max = visible.length - 1;
    render();
  }
  $("title").textContent = M.name;
  $("subtitle").textContent =
    `${M.backend.toUpperCase()} · ${M.mesh.join(" × ")} groups · ${M.precision || "precision unknown"}${M.shape ? " · " + (M.workload?.name || "GEMM") + " " + M.shape.join(" × ") : ""} · KS=${M.kernel_size ?? M.hash?.kernel ?? "unknown"} rows · ${D.window}-cycle display windows`;
  for (let g = 0; g < M.mesh[0] * M.mesh[1]; g++) {
    let o = document.createElement("option");
    o.value = g;
    o.textContent = "G" + g;
    $("group").append(o);
    let label = document.createElement("label");
    label.innerHTML = `<input type="checkbox" value="${g}" ${g === 0 ? "checked" : ""}>G${g}`;
    label.querySelector("input").onchange = (e) => {
      e.target.checked ? chosen.add(g) : chosen.delete(g);
      render();
    };
    $("lineGroups").append(label);
  }
  [
    ...new Set(
      F.flatMap((f) =>
        f.rows.filter((r) => r.kind === "link").map((r) => r.subnet),
      ),
    ),
  ]
    .sort((a, b) => a - b)
    .forEach((s) => {
      let o = document.createElement("option");
      o.value = s;
      o.textContent = s;
      $("subnet").append(o);
    });
  $("time").oninput = (e) => select(visible[+e.target.value]);
  for (const name of Object.keys(M.phase_ranges || {})) {
    if (![...$("phase").options].some(o => o.value === name)) {
      const option = document.createElement("option");
      option.value = name; option.textContent = name[0].toUpperCase()+name.slice(1);
      $("phase").append(option);
    }
  }
  let phaseRequest = 0;
  $("phase").onchange = async () => {
    const request = ++phaseRequest;
    filter();
    const bounds = M.phase_ranges?.[$("phase").value];
    if (bounds && typeof loadRange === "function") {
      // A second selection can arrive while a compressed detail page is being
      // decoded. The pager rejects overlapping loads; queue only the newest
      // phase selection so it cannot leave an empty view on the old page.
      while (typeof loading !== "undefined" && loading)
        await new Promise(resolve => setTimeout(resolve, 10));
      if (request !== phaseRequest) return;
      const width = D.detail_range ? D.detail_range[1]-D.detail_range[0] : 20000;
      await loadRange(bounds[0], Math.min(bounds[1], bounds[0]+width));
    }
    if (request === phaseRequest) filter();
  };
  $("group").onchange = (e) => setGroup(+e.target.value);
  $("prev").onclick = () =>
    select(visible[Math.max(0, visible.indexOf(selected) - 1)]);
  $("next").onclick = () =>
    select(
      visible[Math.min(visible.length - 1, visible.indexOf(selected) + 1)],
    );
  $("play").onclick = () => {
    if (timer) {
      clearInterval(timer);
      timer = null;
      $("play").textContent = "Play";
    } else {
      $("play").textContent = "Pause";
      timer = setInterval(() => {
        let i = visible.indexOf(selected);
        select(visible[(i + 1) % visible.length]);
      }, 500);
    }
  };
  for (let id of [
    "groupLines",
    "entryMetric",
    "bankMetric",
    "network",
    "subnet",
    "linkMetric",
    "nocScale",
    "roofBoundary",
    "roofWindow",
  ])
    $(id).onchange = render;
  $("allGroups").onclick = () => {
    for (let g = 0; g < M.mesh[0] * M.mesh[1]; g++) chosen.add(g);
    $("groupLines").checked = true;
    setGroup(group);
  };
  $("clearGroups").onclick = () => {
    chosen.clear();
    $("lineGroups")
      .querySelectorAll("input")
      .forEach((x) => (x.checked = false));
    render();
  };
  document.querySelectorAll("nav button").forEach(
    (button) =>
      (button.onclick = () => {
        tab = button.dataset.tab;
        document
          .querySelectorAll("nav button")
          .forEach((b) => b.classList.toggle("active", b === button));
        document
          .querySelectorAll(".tab")
          .forEach((s) => s.classList.toggle("active", s.id === tab));
        render();
      }),
  );
  $("export").onclick = () => {
    let blob = new Blob(
        [
          JSON.stringify(
            { meta: M, window: F[selected], phase: $("phase").value, group },
            null,
            2,
          ),
        ],
        { type: "application/json" },
      ),
      a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "simulation-window.json";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };
  // A boundary frame can contain setup only. Prefer measured activity for the
  // selected group so the initial memory and utilization views are meaningful.
  const firstBenchmark = F.findIndex((frame) =>
    frame.rows.some((row) => row.phase === "bench" && row.g === group && (
      (row.kind === "entry" && row.occupied > 0) ||
      (row.kind === "mshr" && row.occupied > 0) ||
      (row.kind === "fpu" && row.busy > 0))));
  if (firstBenchmark >= 0) selected = firstBenchmark;
  filter();
  window.dashboardTest = { select, setGroup, data: D, render, axisBounds, get visible() { return visible; } };
})().catch((error) => {
  document.querySelector("main").textContent =
    "Dashboard could not load: " + error.message;
  console.error(error);
});
