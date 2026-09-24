// Shared by the reminder runner and browser. No filesystem, credentials or side effects.
function parseZonedTime(value) {
  if (typeof value !== 'string') return null;
  const match = value.trim().match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|[+-]\d{2}:\d{2})$/i);
  if (!match) return null;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText = '0', , zone] = match;
  const [year, month, day, hour, minute, second] = [yearText, monthText, dayText, hourText, minuteText, secondText].map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1]
    || hour > 23 || minute > 59 || second > 59) return null;
  if (zone.toUpperCase() !== 'Z' && (Number(zone.slice(1, 3)) > 23 || Number(zone.slice(4)) > 59)) return null;
  const at = new Date(value.trim());
  return Number.isFinite(at.getTime()) ? at.toISOString() : null;
}

export function resolveTaskDeadline(issue) {
  const fields = String(issue?.body ?? '').split(/\r?\n/)
    .map(line => line.match(/^\s*截止时间\s*[:：]\s*(.*?)\s*$/))
    .filter(Boolean);
  if (fields.length > 1) return { at: null, source: 'body', error: '截止时间重复，请只保留一行。' };
  if (fields.length === 1) {
    const at = parseZonedTime(fields[0][1]);
    return { at, source: 'body', error: at ? null : '截止时间无效，请填写带时区的 ISO 时间。' };
  }
  const due = issue?.milestone?.due_on;
  if (due == null || due === '') return { at: null, source: null, error: null };
  const at = parseZonedTime(due);
  return { at, source: 'milestone', error: at ? null : '里程碑截止时间无效。' };
}
