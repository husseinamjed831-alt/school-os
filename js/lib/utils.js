// School OS — shared UI/utility helpers.

let toastStack = null;

function ensureToastStack() {
  if (toastStack && document.body.contains(toastStack)) return toastStack;
  toastStack = document.createElement("div");
  toastStack.className = "toast-stack";
  document.body.appendChild(toastStack);
  return toastStack;
}

/**
 * @param {string} message
 * @param {"success"|"danger"|"info"} type
 */
export function showToast(message, type = "info") {
  const stack = ensureToastStack();
  const toast = document.createElement("div");
  toast.className = `toast${type === "success" ? " toast-success" : ""}${type === "danger" ? " toast-danger" : ""}`;
  toast.textContent = message;
  stack.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}

/** @param {string|Date} value */
export function formatDate(value) {
  if (!value) return "—";
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return new Intl.DateTimeFormat("ar-EG", { year: "numeric", month: "long", day: "numeric" }).format(d);
}

/** @param {string|Date} value */
export function formatDateTime(value) {
  if (!value) return "—";
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return new Intl.DateTimeFormat("ar-EG", {
    year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
  }).format(d);
}

/**
 * Runs an async Supabase call, converts any thrown/returned error into an
 * Arabic toast, and returns null on failure so callers can just check truthiness.
 * @template T
 * @param {() => Promise<T>} fn
 * @param {string} [fallbackMessage]
 * @returns {Promise<T|null>}
 */
export async function guard(fn, fallbackMessage = "حدث خطأ غير متوقع، حاول مرة أخرى") {
  try {
    return await fn();
  } catch (err) {
    console.error(err);
    showToast(err?.message ? toArabicError(err.message) : fallbackMessage, "danger");
    return null;
  }
}

/** Maps common Supabase/Postgres error text to an Arabic message. Used both
 * by api/*.js (to throw a readable error) and by guard() (to display one). */
export function toArabicError(message) {
  const known = {
    "Invalid login credentials": "البريد الإلكتروني أو كلمة المرور غير صحيحة",
    "duplicate key value violates unique constraint": "هذا السجل موجود مسبقاً",
    "JWT expired": "انتهت صلاحية الجلسة، الرجاء تسجيل الدخول مجدداً",
    "violates row-level security policy": "لا تملك صلاحية تنفيذ هذه العملية",
    "violates foreign key constraint": "لا يمكن الحذف لوجود سجلات مرتبطة بهذا العنصر",
    "violates check constraint": "قيمة غير صالحة في أحد الحقول",
    "network": "تعذر الاتصال بالخادم، تحقق من الإنترنت",
  };
  for (const [key, ar] of Object.entries(known)) {
    if (message.includes(key)) return ar;
  }
  return message;
}

/** @param {number} amount @param {string} [currency] */
export function formatCurrency(amount, currency = "IQD") {
  const n = Number(amount ?? 0);
  return `${n.toLocaleString("ar")} ${currency}`;
}

/** Escapes text before inserting into innerHTML to prevent XSS. */
export function escapeHtml(value) {
  const div = document.createElement("div");
  div.textContent = value ?? "";
  return div.innerHTML;
}

/**
 * Minimal RFC-4180-ish CSV parser: handles quoted fields (with embedded
 * commas/newlines/escaped "" quotes) and bare unquoted fields. Returns an
 * array of row-arrays, no header handling — the caller matches headers.
 * @param {string} text
 * @returns {string[][]}
 */
export function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  const normalized = text.replace(/\r\n/g, "\n");

  for (let i = 0; i < normalized.length; i++) {
    const char = normalized[i];
    if (inQuotes) {
      if (char === '"') {
        if (normalized[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ",") {
      row.push(field);
      field = "";
    } else if (char === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += char;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ""));
}

export function debounce(fn, wait = 300) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}
