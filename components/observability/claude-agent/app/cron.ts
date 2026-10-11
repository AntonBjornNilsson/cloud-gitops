// Minimal 5-field cron matcher (minute hour day-of-month month day-of-week; *, lists, ranges, steps),
// evaluated in the container's time zone (UTC unless TZ is set).
function field(spec: string, value: number, min: number, max: number): boolean {
  return spec.split(',').some((part) => {
    const [range, stepStr] = part.split('/');
    const step = stepStr ? Number(stepStr) : 1;
    let lo = min;
    let hi = max;
    if (range !== '*') {
      const [a, b] = range.split('-').map(Number);
      lo = a;
      hi = b ?? (stepStr ? max : a);
    }
    return value >= lo && value <= hi && (value - lo) % step === 0;
  });
}

export function cronMatches(expr: string, d: Date): boolean {
  const [mi, h, dom, mon, dow] = expr.trim().split(/\s+/);
  return field(mi, d.getMinutes(), 0, 59) && field(h, d.getHours(), 0, 23) && field(dom, d.getDate(), 1, 31)
    && field(mon, d.getMonth() + 1, 1, 12) && (field(dow, d.getDay(), 0, 6) || (d.getDay() === 0 && field(dow, 7, 0, 7)));
}

export function validCron(expr: string): boolean {
  return /^(\S+\s+){4}\S+$/.test(expr.trim()) && expr.trim().split(/\s+/).every((f) => /^[\d*,\/-]+$/.test(f));
}
