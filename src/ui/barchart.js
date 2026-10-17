'use strict';

// ── Built-in Canvas 2D Bar Chart ──────────────────────────────────────────────
class BuiltinBarChart {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.container = canvas.parentElement;
    this.data = null;
    this.focusedKey = null;
    this.hoverIdx = -1;
    this.dpr = window.devicePixelRatio || 1;

    // Create floating tooltip element in parent container
    this.tooltip = document.createElement('div');
    this.tooltip.className = 'builtin-chart-tooltip';
    this.tooltip.style.display = 'none';
    this.container.appendChild(this.tooltip);

    // Event listeners
    this.onPointerMove = this.onPointerMove.bind(this);
    this.onPointerLeave = this.onPointerLeave.bind(this);
    this.onClick = this.onClick.bind(this);
    this.onResize = this.onResize.bind(this);

    this.canvas.addEventListener('pointermove', this.onPointerMove);
    this.canvas.addEventListener('pointerleave', this.onPointerLeave);
    this.canvas.addEventListener('click', this.onClick);

    this.ro = new ResizeObserver(this.onResize);
    this.ro.observe(this.container);
  }

  destroy() {
    this.ro.disconnect();
    this.canvas.removeEventListener('pointermove', this.onPointerMove);
    this.canvas.removeEventListener('pointerleave', this.onPointerLeave);
    this.canvas.removeEventListener('click', this.onClick);
    if (this.tooltip.parentElement) {
      this.tooltip.parentElement.removeChild(this.tooltip);
    }
  }

  setData({ dates, ranked, selectedDate, dailyTargetHours, hiddenSet }) {
    this.data = {
      dates: dates || [],
      ranked: ranked || [],
      selectedDate,
      dailyTargetHours: Number.isFinite(dailyTargetHours) ? dailyTargetHours : 0,
      hiddenSet: hiddenSet || new Set(),
    };
    this.draw();
  }

  setSelectedDate(selectedDate) {
    if (!this.data) return;
    if (this.data.selectedDate === selectedDate) return;
    this.data.selectedDate = selectedDate;
    this.draw();
  }

  focusSeries(key) {
    if (this.focusedKey === key) return;
    this.focusedKey = key;
    this.draw();
  }

  toggleSeries(hiddenSet) {
    if (this.data) {
      this.data.hiddenSet = hiddenSet;
      this.draw();
    }
  }

  onResize() {
    this.draw();
  }

  onPointerMove(e) {
    if (!this.data || !this.layout) return;
    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const { plotX, plotW, catW, dates } = this.layout;

    if (x >= plotX && x <= plotX + plotW && dates.length > 0) {
      const idx = Math.floor((x - plotX) / catW);
      if (idx >= 0 && idx < dates.length) {
        if (this.hoverIdx !== idx) {
          this.hoverIdx = idx;
          this.updateTooltip(e.clientX, e.clientY);
        } else {
          this.positionTooltip(e.clientX, e.clientY);
        }
        return;
      }
    }
    this.onPointerLeave();
  }

  onPointerLeave() {
    this.hoverIdx = -1;
    this.tooltip.style.display = 'none';
  }

  onClick(e) {
    if (!this.data || !this.layout) return;
    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const { plotX, plotW, catW, dates } = this.layout;

    if (x >= plotX && x <= plotX + plotW && dates.length > 0) {
      const idx = Math.floor((x - plotX) / catW);
      if (idx >= 0 && idx < dates.length && typeof goToDate === 'function') {
        goToDate(dates[idx]);
      }
    }
  }

  updateTooltip(clientX, clientY) {
    if (this.hoverIdx < 0 || !this.data) return;
    const { dates, ranked, hiddenSet } = this.data;
    const date = dates[this.hoverIdx];
    if (!date) return;

    // Filter non-zero, unhidden series on this date, sort descending
    const items = ranked
      .filter(s => !hiddenSet.has(s.key) && (s.ms[this.hoverIdx] || 0) > 0)
      .map(s => ({
        label: s.label,
        color: s.color,
        ms: s.ms[this.hoverIdx] || 0,
      }))
      .sort((a, b) => b.ms - a.ms);

    if (items.length === 0) {
      this.tooltip.style.display = 'none';
      return;
    }

    const total = items.reduce((sum, item) => sum + item.ms, 0);
    const dateStr = typeof shortDate === 'function' ? shortDate(date) : date;

    let html = `<div class="bct-head">${esc(dateStr)}</div>`;
    for (const item of items) {
      html += `<div class="bct-row">
        <span class="bct-swatch" style="background:${item.color}"></span>
        <span class="bct-label">${esc(item.label)}:</span>
        <span class="bct-time">${esc(typeof fmtMs === 'function' ? fmtMs(item.ms) : item.ms + 'ms')}</span>
      </div>`;
    }
    if (items.length > 1) {
      const totalLbl = typeof t === 'function' ? t('card_total') : 'Total';
      html += `<div class="bct-foot">${esc(totalLbl)}: ${esc(typeof fmtMs === 'function' ? fmtMs(total) : total + 'ms')}</div>`;
    }

    this.tooltip.innerHTML = html;
    this.tooltip.style.display = 'block';
    this.positionTooltip(clientX, clientY);
  }

  positionTooltip(clientX, clientY) {
    const parentRect = this.container.getBoundingClientRect();
    const ttWidth = this.tooltip.offsetWidth || 160;
    const ttHeight = this.tooltip.offsetHeight || 60;

    let left = clientX - parentRect.left + 12;
    let top = clientY - parentRect.top - ttHeight - 8;

    if (left + ttWidth > parentRect.width - 8) {
      left = clientX - parentRect.left - ttWidth - 12;
    }
    if (left < 8) left = 8;
    if (top < 8) top = clientY - parentRect.top + 16;
    if (top + ttHeight > parentRect.height - 8) {
      top = Math.max(8, parentRect.height - ttHeight - 8);
    }

    this.tooltip.style.left = Math.round(left) + 'px';
    this.tooltip.style.top = Math.round(top) + 'px';
  }

  draw() {
    if (!this.data) return;
    const { dates, ranked, selectedDate, dailyTargetHours, hiddenSet } = this.data;
    const ctx = this.ctx;
    const rect = this.container.getBoundingClientRect();
    const w = Math.floor(rect.width);
    const h = Math.floor(rect.height);
    if (w <= 0 || h <= 0) return;

    const dpr = window.devicePixelRatio || 1;
    this.dpr = dpr;
    if (this.canvas.width !== Math.round(w * dpr) || this.canvas.height !== Math.round(h * dpr)) {
      this.canvas.width = Math.round(w * dpr);
      this.canvas.height = Math.round(h * dpr);
    }
    this.canvas.style.width = '100%';
    this.canvas.style.height = '100%';

    ctx.save();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    // Compute max stacked hours across visible dates
    const unhidden = ranked.filter(s => !hiddenSet.has(s.key));
    const columnHours = dates.map((_, i) =>
      unhidden.reduce((acc, s) => acc + (s.ms[i] || 0) / 3600000, 0)
    );
    let peakHours = Math.max(1, dailyTargetHours || 0, ...columnHours);

    // Nice tick step selection matching Chart.js maxTicksLimit: 5
    const niceSteps = [1, 2, 5, 10, 15, 20, 24];
    let step = 1;
    for (const s of niceSteps) {
      if (peakHours / s <= 4) {
        step = s;
        break;
      }
    }
    const tickCount = Math.max(2, Math.ceil(peakHours / step));
    const maxVal = tickCount * step;

    // Margins
    const marginLeft = 32;
    const marginRight = 12;
    const marginTop = 12;
    const marginBottom = 22;

    const plotX = marginLeft;
    const plotY = marginTop;
    const plotW = Math.max(10, w - marginLeft - marginRight);
    const plotH = Math.max(10, h - marginTop - marginBottom);
    const catW = dates.length > 0 ? plotW / dates.length : plotW;

    this.layout = { plotX, plotY, plotW, plotH, catW, dates, maxVal };

    // Y Axis Grid lines and Ticks
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    ctx.font = '11px system-ui, -apple-system, sans-serif';
    for (let i = 0; i <= tickCount; i++) {
      const val = i * step;
      const y = Math.round(plotY + plotH - (val / maxVal) * plotH) + 0.5;

      ctx.beginPath();
      ctx.moveTo(plotX, y);
      ctx.lineTo(plotX + plotW, y);
      ctx.strokeStyle = '#2a2d3d';
      ctx.lineWidth = 1;
      ctx.stroke();

      ctx.fillStyle = '#64748b';
      ctx.fillText(val + 'h', plotX - 6, y);
    }

    // Daily target dashed line
    if (dailyTargetHours > 0 && dailyTargetHours <= maxVal) {
      const ty = Math.round(plotY + plotH - (dailyTargetHours / maxVal) * plotH) + 0.5;
      ctx.save();
      ctx.beginPath();
      ctx.setLineDash([4, 4]);
      ctx.moveTo(plotX, ty);
      ctx.lineTo(plotX + plotW, ty);
      ctx.strokeStyle = '#94a3b8';
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.restore();
    }

    // Stacked Bars
    const barW = Math.max(2, Math.min(36, Math.floor(catW * 0.72)));
    const selIdx = dates.indexOf(selectedDate);

    for (let i = 0; i < dates.length; i++) {
      const cx = plotX + i * catW + catW / 2;
      const bx = Math.round(cx - barW / 2);
      let curY = plotY + plotH;

      // Find all visible segments for this column
      const segments = [];
      for (const s of unhidden) {
        const ms = s.ms[i] || 0;
        if (ms > 0) {
          segments.push({
            series: s,
            hours: ms / 3600000,
          });
        }
      }

      for (let sIdx = 0; sIdx < segments.length; sIdx++) {
        const seg = segments[sIdx];
        const isTop = sIdx === segments.length - 1;
        const segH = Math.max(1, Math.round((seg.hours / maxVal) * plotH));
        const topY = Math.max(plotY, curY - segH);
        const actualH = curY - topY;

        // Opacity
        const isFocused = this.focusedKey == null || seg.series.key === this.focusedKey;
        const alpha = !isFocused ? '26' : (i === selIdx || selIdx < 0 ? 'ff' : 'b3');
        ctx.fillStyle = seg.series.color + alpha;

        if (isTop && actualH >= 3 && barW >= 4) {
          // Rounded top corners (radius 3)
          const r = Math.min(3, Math.floor(barW / 2), actualH);
          ctx.beginPath();
          ctx.moveTo(bx, curY);
          ctx.lineTo(bx, topY + r);
          ctx.arcTo(bx, topY, bx + r, topY, r);
          ctx.lineTo(bx + barW - r, topY);
          ctx.arcTo(bx + barW, topY, bx + barW, topY + r, r);
          ctx.lineTo(bx + barW, curY);
          ctx.closePath();
          ctx.fill();
        } else {
          ctx.fillRect(bx, topY, barW, actualH);
        }

        curY = topY;
      }
    }

    // X Axis Labels
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.font = '11px system-ui, -apple-system, sans-serif';

    // Measure label width to ensure clean spacing matching Chart.js autoSkipPadding: 8
    const sampleWidth = ctx.measureText('Sep 30').width || 38;
    const minLabelSpacing = sampleWidth + 16;
    const skipStep = Math.max(1, Math.ceil(minLabelSpacing / catW));

    for (let i = 0; i < dates.length; i += skipStep) {
      const cx = Math.round(plotX + i * catW + catW / 2);
      const isSel = i === selIdx;
      ctx.fillStyle = isSel ? '#e2e8f0' : '#64748b';
      const label = typeof shortDate === 'function' ? shortDate(dates[i]) : dates[i];
      ctx.fillText(label, cx, plotY + plotH + 6);
    }

    ctx.restore();
  }
}
