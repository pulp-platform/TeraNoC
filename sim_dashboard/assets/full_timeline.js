  const pager = $("timelinePage");
  const maxDetailCycles = root.meta.page_cycles * 3;
  let detailRange = [root.pages[pageNumber].start, root.pages[pageNumber].end];
  // Load all detail for a short benchmark even when it crosses a page edge.
  if (root.meta.benchmark?.every(Number.isFinite) &&
      root.meta.benchmark[1] - root.meta.benchmark[0] <= maxDetailCycles) {
    detailRange = [...root.meta.benchmark];
  }
  let loading = false;
  root.pages.forEach(p => {
    const option = document.createElement("option"); option.value = p.index;
    option.textContent = `${p.start.toLocaleString()}–${p.end.toLocaleString()} cycles`;
    pager.append(option);
  });
  pager.value = String(pageNumber);
  const timelinePoints = root.overview || [];
  const fullStart = Math.min(
    root.pages[0].start,
    timelinePoints.reduce((value, point) => Math.min(value, point.start), Infinity),
    (root.long_intervals || []).reduce((value, row) => Math.min(value, row.start), Infinity),
  );
  const fullEnd = Math.max(
    root.pages.at(-1).end,
    timelinePoints.reduce((value, point) => Math.max(value, point.end), -Infinity),
  );
  function drawTimeline() {
    const w=1000, left=70, right=25, height=115, top=22, bottom=28;
    const x = cycle => left + (cycle-fullStart)/(fullEnd-fullStart)*(w-left-right);
    const measuredFpu = timelinePoints.some(p=>p.fpu_capacity>0);
    const metrics = [
      measuredFpu ? {name:"FPU busy lanes", key:"fpu_busy", den:"fpu_capacity", max:1, color:"#087d9c", percent:true} :
      {name:"FPU utilization (printed percentage)", key:"overall_util_duration", den:"overall_duration", max:1, scale:.01, color:"#087d9c", percent:true},
      {name:"MSHR occupancy", key:"mshr_occupied", den:"mshr_capacity", max:1, color:"#7c4fb0", percent:true},
      {name:"Remote responses / cycle", key:"traffic_mst_resp", den:"traffic_duration", color:"#bd6505"}
    ];
    $("runTimelineCharts").innerHTML = metrics.map(m => {
      const values = timelinePoints.map(p => p[m.key] == null || !p[m.den] ? null : p[m.key]/p[m.den]*(m.scale || 1));
      const max=m.max || values.reduce((value, sample) =>
        sample == null ? value : Math.max(value, sample), 1);
      const y=v=>height-bottom-v/max*(height-top-bottom);
      let s=`<svg class="timelineChart" viewBox="0 0 ${w} ${height}" role="img" aria-label="Full-run ${m.name}" style="width:100%;touch-action:none;user-select:none"><text x="${left}" y="14">${m.name}</text>`;
      const bench=root.meta.benchmark;
      if(bench?.every(v=>v!=null)) s+=`<rect x="${x(bench[0])}" y="${top}" width="${x(bench[1])-x(bench[0])}" height="${height-top-bottom}" fill="#f2f6fa"/>`;
      for(let j=0;j<=2;j++) {
        const value=max*j/2;
        s+=`<path d="M${left} ${y(value)}H${w-right}" stroke="#dce4eb"/><text x="${left-8}" y="${y(value)+4}" text-anchor="end">${m.percent?num(value*100,0)+'%':num(value,1)}</text>`;
      }
      let path="", last=null;
      timelinePoints.forEach((p,i)=>{
        if(values[i]==null) {last=null;return;}
        const continuous=last && p.start<=last.end && p.phase===last.phase;
        path+=`${continuous?'L':'M'}${x(p.start)},${y(values[i])}L${x(p.end)},${y(values[i])}`;
        last=p;
      });
      s+=`<path d="${path}" stroke="${m.color}" fill="none" stroke-width="1.8"/>`;
      s+=`<rect class="detailShade" x="${x(detailRange[0])}" y="${top}" width="${Math.max(1,x(detailRange[1])-x(detailRange[0]))}" height="${height-top-bottom}" fill="#1385a3" fill-opacity=".15" stroke="#1385a3"/>`;
      for(let j=0;j<=4;j++) s+=`<text x="${x(fullStart+(fullEnd-fullStart)*j/4)}" y="${height-5}" text-anchor="middle">${num(fullStart+(fullEnd-fullStart)*j/4,0)}</text>`;
      if(values.every(v=>v==null)) s+=`<text x="500" y="60" text-anchor="middle">Unavailable in this trace</text>`;
      return s+'</svg>';
    }).join('');
    $("detailStart").value = detailRange[0]; $("detailEnd").value = detailRange[1];
    $("overviewCoverage").textContent = `Overview: ${num(fullStart,0)}–${num(fullEnd,0)} cycles, all phases; gray background marks the benchmark. Rates use summed counters and denominators. Select up to ${num(maxDetailCycles,0)} cycles for full-resolution entry, bank and link detail. The Phase selector below filters the detail only.`;
    document.querySelectorAll('.timelineChart').forEach(svg=>{
      const cycle=e=>Math.max(fullStart,Math.min(fullEnd,Math.round((fullStart+Math.max(0,Math.min(1,((e.clientX-svg.getBoundingClientRect().left)/svg.getBoundingClientRect().width*w-left)/(w-left-right)))*(fullEnd-fullStart))/root.window)*root.window));
      let anchor=null;
      svg.onpointerdown=e=>{anchor=cycle(e);svg.setPointerCapture(e.pointerId);};
      svg.onpointermove=e=>{
        if(anchor==null) return;
        const c=cycle(e), lo=Math.min(anchor,c), hi=Math.max(anchor,c);
        const shade=svg.querySelector('.detailShade');shade.setAttribute('x',x(lo));shade.setAttribute('width',Math.max(1,x(hi)-x(lo)));
      };
      svg.onpointercancel=()=>{anchor=null;drawTimeline();};
      svg.onpointerup=e=>{
        if(anchor==null)return;
        const c=cycle(e), start=anchor;anchor=null;
        if(Math.abs(c-start)<root.window) {
          const width=Math.min(root.meta.page_cycles,fullEnd-fullStart);
          const lo=Math.max(fullStart,Math.min(fullEnd-width,c-width/2));
          loadRange(lo,lo+width);
        } else loadRange(Math.min(start,c),Math.max(start,c));
      };
    });
  }
  async function loadRange(start,end) {
    if(loading) return false;
    if(!Number.isFinite(start)||!Number.isFinite(end)||start<fullStart||end>fullEnd||end<=start) {
      $("pageStatus").textContent="Enter a valid range within the captured cycles.";drawTimeline();return false;
    }
    if(end-start>maxDetailCycles) {
      $("pageStatus").textContent=`Select ${num(maxDetailCycles,0)} cycles or fewer for detailed records; the overview always shows the full run.`;drawTimeline();return false;
    }
    loading=true; pager.disabled=true; $("detailApply").disabled=true;
    if(timer){clearInterval(timer);timer=null;$("play").textContent="Play";}
    $("pageStatus").textContent="Loading original-resolution records…";
    try {
      // Records belong to pages by end cycle, including intervals that straddle
      // a page boundary. Read the adjacent page and retain overlapping intervals.
      const targets=root.pages.filter(p=>p.end>start && p.start<end+root.window);
      const frames=[]; let workBefore=null;
      for(const p of targets) {
        const value=await unpack('page-data-'+p.index);
        if(workBefore==null) workBefore=[...value.work_before];
        for(const f of value.frames) {
          for(const r of f.rows) if(r.kind==='work' && r.end<=start && (r.phase==='bench'||r.workload_phase==='bench')) workBefore[r.g]+=r.fmac;
          const keep=f.rows.filter(r=>r.end>start && r.start<end);
          if(keep.length) frames.push({...f,rows:keep});
        }
      }
      // Long source intervals (for example a whole-benchmark summary) may be
      // stored much later than the selected range. Include them once without
      // decompressing every intervening detail block.
      const ids=new Set(frames.flatMap(f=>f.rows.filter(r=>r.end-r.start>root.window).map(r=>JSON.stringify(r))));
      for(const r of root.long_intervals || []) {
        if(r.end<=start || r.start>=end || ids.has(JSON.stringify(r))) continue;
        const stop=Math.ceil(Math.min(r.end,end)/root.window)*root.window;
        let frame=frames.find(f=>f.end===stop);
        if(!frame){frame={start:stop-root.window,end:stop,rows:[]};frames.push(frame);}
        frame.rows.push(r);ids.add(JSON.stringify(r));
      }
      frames.sort((a,b)=>a.start-b.start);
      if(!frames.length) throw new Error('No recorded intervals overlap this range');
      if(!targets.length) {
        const next=root.pages.find(p=>p.end>start);
        if(next) workBefore=[...(await unpack('page-data-'+next.index)).work_before];
      }
      F=frames;D.frames=F;M.work_before=workBefore;D.work_before=workBefore;
      rowIndex=indexFrames();selected=0;pageNumber=(targets[0] || root.pages.find(p=>p.end>start) || root.pages.at(-1)).index;pager.value=String(pageNumber);
      detailRange=[start,end];D.detail_range=detailRange;
      filter();drawTimeline();
      $("pageStatus").textContent=`Detail: ${num(start,0)}–${num(end,0)} cycles. Boundary windows retain their original counts.`;
      return true;
    } catch(error) {$("pageStatus").textContent='Could not load detail: '+error.message;return false;}
    finally {loading=false;pager.disabled=false;$("detailApply").disabled=false;}
  }
  async function loadPage(n) {
    if(n<0||n>=root.pages.length)return false;
    return loadRange(root.pages[n].start,root.pages[n].end);
  }
  pager.onchange=()=>loadPage(+pager.value);
  $("pagePrev").onclick=()=>loadPage(pageNumber-1);$("pageNext").onclick=()=>loadPage(pageNumber+1);
  $("detailApply").onclick=()=>loadRange(+$("detailStart").value,+$("detailEnd").value);
  function shiftDetail(sign) {
    const width=detailRange[1]-detailRange[0], lo=Math.max(fullStart,Math.min(fullEnd-width,detailRange[0]+sign*width));
    return loadRange(lo,lo+width);
  }
  $("detailPrev").onclick=()=>shiftDetail(-1);$("detailNext").onclick=()=>shiftDetail(1);
  D.detail_range=detailRange;drawTimeline();
  $("pageStatus").textContent=`Detail: ${num(detailRange[0],0)}–${num(detailRange[1],0)} cycles`;

  await loadRange(...detailRange);
