// Date, time, month and week inputs ignore typed text; each takes its value in one ISO format.
export const VALUE_FORMATS = {
  date: "YYYY-MM-DD",
  time: "HH:MM",
  "datetime-local": "YYYY-MM-DDTHH:MM",
  month: "YYYY-MM",
  week: "YYYY-Www",
} as const;
export type ValueFieldType = keyof typeof VALUE_FORMATS;

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const pad = (n: number) => String(n).padStart(2, "0");
const monthNumber = (name: string) => MONTHS.indexOf(name.slice(0, 3).toLowerCase()) + 1;

const daysIn = (year: number, month: number) =>
  month === 2
    ? year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
      ? 29
      : 28
    : [4, 6, 9, 11].includes(month)
      ? 30
      : 31;

const isoDate = (year: number, month: number, day: number) =>
  year > 0 && month >= 1 && month <= 12 && day >= 1 && day <= daysIn(year, month)
    ? `${year}-${pad(month)}-${pad(day)}`
    : undefined;

const dateValue = (text: string) => {
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(text);
  if (m) return isoDate(+m[1]!, +m[2]!, +m[3]!);
  m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(text);
  if (m) {
    const [first, second, year] = [+m[1]!, +m[2]!, +m[3]!];
    // 12/11 reads as either order; only take a numeric date one order can make.
    if (first <= 12 && second <= 12 && first !== second) return undefined;
    return isoDate(year, first, second) ?? isoDate(year, second, first);
  }
  m = /^(?:[a-z]+,? )?([a-z]{3,})\.? (\d{1,2})(?:st|nd|rd|th)?,? (\d{4})$/i.exec(text);
  if (m && monthNumber(m[1]!)) return isoDate(+m[3]!, monthNumber(m[1]!), +m[2]!);
  m = /^(?:[a-z]+,? )?(\d{1,2})(?:st|nd|rd|th)? ([a-z]{3,})\.?,? (\d{4})$/i.exec(text);
  if (m && monthNumber(m[2]!)) return isoDate(+m[3]!, monthNumber(m[2]!), +m[1]!);
  return undefined;
};

const timeValue = (text: string) => {
  const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))? ?(?:([ap])\.?m\.?)?$/i.exec(text);
  if (!m) return undefined;
  let hour = +m[1]!;
  const meridiem = m[4]?.toLowerCase();
  if (meridiem && (hour < 1 || hour > 12)) return undefined;
  if (meridiem === "p" && hour < 12) hour += 12;
  if (meridiem === "a" && hour === 12) hour = 0;
  if (hour > 23 || +m[2]! > 59 || +(m[3] ?? 0) > 59) return undefined;
  return `${pad(hour)}:${m[2]}${m[3] === undefined ? "" : `:${m[3]}`}`;
};

const monthValue = (text: string) => {
  const iso = /^(\d{4})-(\d{1,2})$/.exec(text);
  const numeric = /^(\d{1,2})\/(\d{4})$/.exec(text);
  const named = /^([a-z]{3,})\.?,? (\d{4})$/i.exec(text);
  const [year, month] = iso
    ? [+iso[1]!, +iso[2]!]
    : numeric
      ? [+numeric[2]!, +numeric[1]!]
      : named
        ? [+named[2]!, monthNumber(named[1]!)]
        : [0, 0];
  return year > 0 && month >= 1 && month <= 12 ? `${year}-${pad(month)}` : undefined;
};

/** The value a date-like input takes for the text an agent typed, or undefined when it is unclear. */
export const fieldValue = (type: ValueFieldType, typed: string): string | undefined => {
  const text = typed.trim().replace(/\s+/g, " ");
  switch (type) {
    case "date":
      return dateValue(text);
    case "time":
      return timeValue(text);
    case "datetime-local": {
      const m = /^(.+?)(?:T|,? at |,? )(\d{1,2}:\d{2}(?::\d{2})? ?(?:[ap]\.?m\.?)?)$/i.exec(text);
      const date = m ? dateValue(m[1]!) : undefined;
      const time = m ? timeValue(m[2]!) : undefined;
      return date && time ? `${date}T${time}` : undefined;
    }
    case "month":
      return monthValue(text);
    case "week":
      return /^\d{4}-W\d{2}$/i.test(text) ? text.toUpperCase() : undefined;
  }
};
