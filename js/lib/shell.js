// School OS — shared dashboard shell (sidebar + topbar + mobile nav).
import { logout } from "./auth.js";
import { listMyNotifications, markNotificationRead } from "../api/notifications.js";
import { createTelegramLinkCode } from "../api/telegram.js";
import { escapeHtml, formatDateTime, guard, showToast } from "./utils.js";

const ICONS = {
  dashboard: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>`,
  students: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3 2 8l10 5 10-5-10-5Z"/><path d="M6 10.5V16c0 1.5 3 3 6 3s6-1.5 6-3v-5.5"/></svg>`,
  setup: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.55V21a2 2 0 0 1-4 0v-.09a1.7 1.7 0 0 0-1-1.55 1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1H3a2 2 0 0 1 0-4h.09a1.7 1.7 0 0 0 1.55-1 1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1-1.55V3a2 2 0 0 1 4 0v.09a1.7 1.7 0 0 0 1 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9c.19.42.55.74 1 .9H21a2 2 0 0 1 0 4h-.09c-.5.16-.86.48-1.05.9Z"/></svg>`,
  users: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>`,
  grading: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 11.5 11 13.5 15 9"/><circle cx="12" cy="12" r="9"/></svg>`,
  schedule: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 10h18"/><path d="M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01"/></svg>`,
  schools: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m3 10 9-6 9 6-9 6-9-6Z"/><path d="M7 12.5V19c0 .5 2.5 2 5 2s5-1.5 5-2v-6.5"/></svg>`,
  bell: `<svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>`,
  logout: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/></svg>`,
  telegram: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>`,
  staffAttendance: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="m17 11 2 2 4-4"/></svg>`,
};

const NAV_BY_ROLE = {
  super_admin: [
    { key: "schools", label: "المدارس", href: "/admin/schools.html", icon: "schools" },
  ],
  school_admin: [
    { key: "dashboard", label: "لوحة التحكم", href: "/admin/dashboard.html", icon: "dashboard" },
    { key: "students", label: "الطلاب", href: "/admin/students.html", icon: "students" },
    { key: "setup", label: "الهيكل الأكاديمي", href: "/admin/setup.html", icon: "setup" },
    { key: "schedule", label: "الجدول الأسبوعي", href: "/admin/schedule.html", icon: "schedule" },
    { key: "staff-attendance", label: "حضور الموظفين", href: "/admin/staff-attendance.html", icon: "staffAttendance" },
    { key: "grading", label: "إعدادات التقييم", href: "/admin/grading.html", icon: "grading" },
    { key: "users", label: "المستخدمون", href: "/admin/users.html", icon: "users" },
  ],
  branch_admin: [
    { key: "dashboard", label: "لوحة التحكم", href: "/admin/dashboard.html", icon: "dashboard" },
    { key: "students", label: "الطلاب", href: "/admin/students.html", icon: "students" },
    { key: "setup", label: "الهيكل الأكاديمي", href: "/admin/setup.html", icon: "setup" },
    { key: "schedule", label: "الجدول الأسبوعي", href: "/admin/schedule.html", icon: "schedule" },
    { key: "staff-attendance", label: "حضور الموظفين", href: "/admin/staff-attendance.html", icon: "staffAttendance" },
    { key: "users", label: "المستخدمون", href: "/admin/users.html", icon: "users" },
  ],
  teacher: [
    { key: "dashboard", label: "لوحة التحكم", href: "/teacher/dashboard.html", icon: "dashboard" },
    { key: "attendance", label: "الحضور", href: "/teacher/attendance.html", icon: "students" },
    { key: "assessments", label: "التقييمات والدرجات", href: "/teacher/assessments.html", icon: "grading" },
  ],
  student: [
    { key: "dashboard", label: "لوحة التحكم", href: "/student/dashboard.html", icon: "dashboard" },
  ],
  parent: [
    { key: "dashboard", label: "لوحة التحكم", href: "/parent/dashboard.html", icon: "dashboard" },
  ],
};

const ROLE_LABEL = {
  super_admin: "مدير المنصة",
  school_admin: "مدير المدرسة",
  branch_admin: "مدير الفرع",
  teacher: "معلم",
  student: "طالب",
  parent: "ولي أمر",
};

/**
 * Builds the sidebar/topbar/mobile-nav shell and returns the empty
 * `.app-content` element the page should render its own markup into.
 * @param {object} profile
 * @param {string} activeKey
 * @returns {HTMLElement}
 */
export function mountShell(profile, activeKey) {
  const nav = NAV_BY_ROLE[profile.role] ?? [];

  document.body.insertAdjacentHTML(
    "afterbegin",
    `
    <div class="app-shell">
      <aside class="sidebar">
        <div class="sidebar-brand">${ICONS.schools} School OS</div>
        <nav class="sidebar-nav">
          ${nav
            .map(
              (item) => `
            <a href="${item.href}" class="sidebar-link${item.key === activeKey ? " is-active" : ""}">
              ${ICONS[item.icon]}<span>${item.label}</span>
            </a>`
            )
            .join("")}
        </nav>
        <div class="sidebar-footer">
          <button type="button" class="sidebar-link" id="shell-telegram" style="width:100%; border:none; background:none; cursor:pointer;">
            ${ICONS.telegram}<span>ربط تلغرام</span>
          </button>
          <button type="button" class="sidebar-link" id="shell-logout" style="width:100%; border:none; background:none; cursor:pointer;">
            ${ICONS.logout}<span>تسجيل الخروج</span>
          </button>
        </div>
      </aside>
      <div class="app-main">
        <header class="topbar">
          <div class="flex gap-12">
            <div class="avatar">${escapeHtml(initials(profile.full_name))}</div>
            <div>
              <div style="font-weight:700; font-size:14px;">${escapeHtml(profile.full_name)}</div>
              <div class="text-subtle" style="font-size:12px;">${ROLE_LABEL[profile.role] ?? ""}</div>
            </div>
          </div>
          <div class="topbar-actions">
            <div class="dropdown" id="notif-dropdown">
              <button type="button" class="topbar-icon-btn" id="notif-toggle" aria-label="الإشعارات">
                ${ICONS.bell}<span class="dot" id="notif-dot" style="display:none;"></span>
              </button>
              <div class="dropdown-panel" id="notif-panel">
                <div class="dropdown-item text-muted" id="notif-empty">لا توجد إشعارات</div>
              </div>
            </div>
          </div>
        </header>
        <main class="app-content" id="app-content"></main>
      </div>
    </div>
    <nav class="bottom-nav">
      <div class="bottom-nav-inner">
        ${nav
          .map(
            (item) => `
          <a href="${item.href}" class="bottom-nav-link${item.key === activeKey ? " is-active" : ""}">
            ${ICONS[item.icon]}<span>${item.label}</span>
          </a>`
          )
          .join("")}
      </div>
    </nav>
    <div class="modal-overlay" id="telegram-modal-overlay">
      <div class="modal">
        <div class="modal-header">
          <h3>ربط حساب تلغرام</h3>
          <button class="modal-close" id="telegram-modal-close" aria-label="إغلاق">✕</button>
        </div>
        <div id="telegram-modal-body">
          <p class="text-muted">اضغط الزر لإنشاء كود ربط صالح لمدة 15 دقيقة.</p>
          <button type="button" class="btn btn-primary" id="telegram-generate-btn">إنشاء كود</button>
        </div>
      </div>
    </div>
    `
  );

  document.getElementById("shell-logout").addEventListener("click", logout);
  wireNotifications(profile);
  wireTelegramLink();

  return document.getElementById("app-content");
}

function wireTelegramLink() {
  const overlay = document.getElementById("telegram-modal-overlay");
  const body = document.getElementById("telegram-modal-body");
  const openBtn = document.getElementById("shell-telegram");
  const closeBtn = document.getElementById("telegram-modal-close");

  function resetBody() {
    body.innerHTML = `
      <p class="text-muted">اضغط الزر لإنشاء كود ربط صالح لمدة 15 دقيقة.</p>
      <button type="button" class="btn btn-primary" id="telegram-generate-btn">إنشاء كود</button>
    `;
    document.getElementById("telegram-generate-btn").addEventListener("click", generateCode);
  }

  async function generateCode() {
    const result = await guard(() => createTelegramLinkCode());
    if (!result) return;
    body.innerHTML = `
      <p class="text-muted" style="margin-bottom:10px;">افتح بوت تلغرام الخاص بالمدرسة وأرسل هذه الرسالة بالضبط:</p>
      <div class="card" style="text-align:center; font-size:22px; font-weight:800; letter-spacing:2px; padding:16px; margin-bottom:10px;">
        /ربط ${escapeHtml(result.code)}
      </div>
      <p class="text-subtle" style="font-size:12px;">الكود صالح 15 دقيقة فقط.</p>
    `;
  }

  openBtn.addEventListener("click", () => {
    resetBody();
    overlay.classList.add("is-open");
  });
  closeBtn.addEventListener("click", () => overlay.classList.remove("is-open"));
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) overlay.classList.remove("is-open");
  });
}

function initials(name) {
  if (!name) return "؟";
  return name.trim().split(/\s+/).slice(0, 2).map((p) => p[0]).join("");
}

async function wireNotifications(profile) {
  const toggle = document.getElementById("notif-toggle");
  const dropdown = document.getElementById("notif-dropdown");
  const panel = document.getElementById("notif-panel");
  const dot = document.getElementById("notif-dot");

  toggle.addEventListener("click", () => dropdown.classList.toggle("is-open"));
  document.addEventListener("click", (e) => {
    if (!dropdown.contains(e.target)) dropdown.classList.remove("is-open");
  });

  const notifications = await listMyNotifications(profile.id);
  if (!notifications || notifications.length === 0) return;

  const unread = notifications.filter((n) => !n.is_read);
  if (unread.length > 0) dot.style.display = "block";

  panel.innerHTML = notifications
    .map(
      (n) => `
    <div class="dropdown-item${n.is_read ? "" : " is-unread"}" data-id="${n.id}">
      <div class="dropdown-item-title">${escapeHtml(n.title)}</div>
      <div class="text-muted">${escapeHtml(n.body ?? "")}</div>
      <div class="text-subtle" style="margin-top:4px;">${formatDateTime(n.created_at)}</div>
    </div>`
    )
    .join("");

  panel.querySelectorAll(".dropdown-item[data-id]").forEach((el) => {
    el.addEventListener("click", async () => {
      if (el.classList.contains("is-unread")) {
        await markNotificationRead(el.dataset.id);
        el.classList.remove("is-unread");
      }
    });
  });
}
