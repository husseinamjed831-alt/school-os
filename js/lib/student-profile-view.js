// School OS — Student 360: one shared renderer used by the admin/teacher
// profile page, the parent profile page, and (in a reduced form) the
// student's own dashboard. Every fetch here is scoped by RLS to whatever
// the caller is actually allowed to see, so the same code is safe to reuse
// across roles — it never fetches "everything" and hides it client-side.
import { getStudent } from "../api/students.js";
import { listStudentAttendanceHistory } from "../api/attendance.js";
import { getStudentAttendanceRate, getStudentGradeSummary, getStudentRiskScore } from "../api/analytics.js";
import { listStudentScores } from "../api/assessment-scores.js";
import { listBehaviorRecords, listTeacherNotes } from "../api/student-records.js";
import { listGradingScales, labelForPercent } from "../api/grading-scales.js";
import { guard, escapeHtml, formatDate, formatDateTime } from "./utils.js";

const STATUS_LABEL = { present: "حاضر", absent: "غائب", late: "متأخر", excused: "مجاز" };
const STATUS_BADGE = { present: "badge-present", absent: "badge-absent", late: "badge-late", excused: "badge-excused" };
const RISK_LABEL = { high: "مرتفع", medium: "متوسط", low: "منخفض" };
const RISK_BADGE = { high: "badge-danger", medium: "badge-warning", low: "badge-success" };

/**
 * @param {HTMLElement} container
 * @param {string} studentId
 * @param {{includeStaffSections?: boolean, includeBehavior?: boolean}} [options]
 *   includeStaffSections: risk score section — school_admin/branch_admin/
 *     teacher only (also enforced server-side by fn_can_view_risk_score,
 *     this flag just avoids calling an RPC that would be denied anyway).
 *   includeBehavior: behavior records — staff and parents can see these
 *     (there's an RLS policy for both), the student's own view does not.
 *     Defaults to the value of includeStaffSections when not given.
 */
export async function renderStudentProfile(container, studentId, options = {}) {
  const { includeStaffSections = false, includeBehavior = includeStaffSections } = options;

  container.innerHTML = `<div class="skeleton" style="height:200px;"></div>`;

  const student = await guard(() => getStudent(studentId));
  if (!student) {
    container.innerHTML = `<div class="empty-state"><div class="empty-state-title">تعذر تحميل بيانات الطالب</div></div>`;
    return;
  }

  const [attendanceRate, attendanceHistory, gradeSummary, scores, scales, notes] = await Promise.all([
    guard(() => getStudentAttendanceRate(studentId)),
    guard(() => listStudentAttendanceHistory(studentId)),
    guard(() => getStudentGradeSummary(studentId)),
    guard(() => listStudentScores(studentId)),
    guard(() => listGradingScales()),
    guard(() => listTeacherNotes(studentId)),
  ]);

  const behaviorRecords = includeBehavior ? await guard(() => listBehaviorRecords(studentId)) : null;
  const riskScore = includeStaffSections ? await guard(() => getStudentRiskScore(studentId)) : null;

  const avgGrade = gradeSummary?.length
    ? gradeSummary.filter((g) => g.weighted_percent != null).reduce((sum, g, _, arr) => sum + g.weighted_percent / arr.length, 0)
    : null;

  container.innerHTML = `
    <div class="card" style="margin-bottom:20px;">
      <div class="flex gap-16" style="align-items:flex-start;">
        <div class="avatar" style="width:64px; height:64px; font-size:20px;">${initials(student.full_name)}</div>
        <div style="flex:1;">
          <h2 style="margin-bottom:2px;">${escapeHtml(student.full_name)}</h2>
          <p class="text-muted">
            ${student.sections ? `${escapeHtml(student.sections.classes?.name ?? "")} - ${escapeHtml(student.sections.name)}` : "لم يُحدَّد الصف"}
            ${student.birth_date ? " • تاريخ الميلاد: " + formatDate(student.birth_date) : ""}
          </p>
          <p class="text-muted" style="font-size:13px;">
            ولي الأمر: ${student.parent ? escapeHtml(student.parent.full_name) + (student.parent.phone ? " - " + escapeHtml(student.parent.phone) : "") : "غير مسجّل"}
          </p>
        </div>
        <span class="badge ${student.is_active ? "badge-success" : "badge-neutral"}">${student.is_active ? "نشط" : "معطل"}</span>
      </div>
    </div>

    <div class="grid grid-3" style="margin-bottom:20px;">
      <div class="stat-card">
        <div class="stat-icon">${ICON_ATTENDANCE}</div>
        <div><div class="stat-value">${attendanceRate ?? "—"}${attendanceRate != null ? "%" : ""}</div><div class="stat-label">نسبة الحضور</div></div>
      </div>
      <div class="stat-card">
        <div class="stat-icon">${ICON_GRADE}</div>
        <div><div class="stat-value">${avgGrade != null ? Math.round(avgGrade) + "%" : "—"}</div><div class="stat-label">المعدل العام</div></div>
      </div>
      ${
        includeStaffSections
          ? `<div class="stat-card">
              <div class="stat-icon">${ICON_RISK}</div>
              <div>
                <div class="stat-value">${riskScore ? `<span class="badge ${RISK_BADGE[riskScore.risk_level]}">${RISK_LABEL[riskScore.risk_level]}</span>` : "—"}</div>
                <div class="stat-label">مؤشر المخاطر (${riskScore?.risk_score ?? 0}/100)</div>
              </div>
            </div>`
          : `<div class="stat-card">
              <div class="stat-icon">${ICON_SUBJECT}</div>
              <div><div class="stat-value">${gradeSummary?.length ?? 0}</div><div class="stat-label">عدد المواد المقيَّمة</div></div>
            </div>`
      }
    </div>

    ${
      includeStaffSections && riskScore && riskScore.risk_factors?.length
        ? `<div class="card" style="margin-bottom:20px; border-color: var(--warning);">
            <div class="card-title">عوامل تستدعي الانتباه</div>
            <div class="card-subtitle">مؤشر دعم قرار غير نهائي — يُقيَّم بالسياق من قبل الطاقم التعليمي، وليس حكماً على الطالب</div>
            <ul style="list-style:disc; padding-inline-start:20px;">
              ${riskScore.risk_factors.map((f) => `<li>${escapeHtml(f)}</li>`).join("")}
            </ul>
          </div>`
        : ""
    }

    <div class="grid grid-2" style="margin-bottom:20px; align-items:start;">
      <div class="card">
        <div class="card-title">الأداء حسب المادة</div>
        ${
          !gradeSummary || gradeSummary.length === 0
            ? `<p class="text-muted" style="font-size:13px;">لا توجد درجات مسجّلة بعد</p>`
            : gradeSummary
                .map((g) => {
                  const scale = labelForPercent(scales, g.weighted_percent);
                  const pct = g.weighted_percent ?? 0;
                  return `
                  <div style="margin-bottom:14px;">
                    <div class="flex-between" style="margin-bottom:4px; font-size:13px;">
                      <span>${escapeHtml(g.subject_name)}${scale ? ` <span class="badge badge-neutral">${escapeHtml(scale.label)}</span>` : ""}</span>
                      <span class="text-muted">${g.weighted_percent != null ? g.weighted_percent + "%" : "لم يُقيَّم بعد"}</span>
                    </div>
                    <div class="progress"><div class="progress-bar ${pct < 60 ? "danger" : pct < 75 ? "warning" : "success"}" style="width:${pct}%;"></div></div>
                    ${g.missing_count > 0 ? `<div class="text-subtle" style="font-size:12px; margin-top:2px;">${g.missing_count} تقييم غير مسلَّم</div>` : ""}
                  </div>`;
                })
                .join("")
        }
      </div>

      <div class="card">
        <div class="card-title">آخر سجل حضور</div>
        ${
          !attendanceHistory || attendanceHistory.length === 0
            ? `<p class="text-muted" style="font-size:13px;">لا يوجد سجل حضور بعد</p>`
            : `<div class="table-wrap" style="border:none;"><table class="table">
                <tbody>
                  ${attendanceHistory
                    .slice(0, 8)
                    .map((a) => `<tr><td>${formatDate(a.date)}</td><td><span class="badge ${STATUS_BADGE[a.status]}">${STATUS_LABEL[a.status]}</span></td></tr>`)
                    .join("")}
                </tbody>
              </table></div>`
        }
      </div>
    </div>

    ${
      includeBehavior
        ? `<div class="card" style="margin-bottom:20px;">
            <div class="card-title">السلوك</div>
            ${
              !behaviorRecords || behaviorRecords.length === 0
                ? `<p class="text-muted" style="font-size:13px;">لا توجد ملاحظات سلوكية</p>`
                : behaviorRecords
                    .map(
                      (b) => `
                  <div style="padding:10px 0; border-bottom:1px solid var(--border);">
                    <span class="badge ${b.category === "positive" ? "badge-success" : "badge-warning"}">${b.category === "positive" ? "إيجابي" : "يستدعي الانتباه"}</span>
                    <p style="margin:6px 0 2px;">${escapeHtml(b.note)}</p>
                    <span class="text-subtle" style="font-size:12px;">${escapeHtml(b.recorded_by_profile?.full_name ?? "")} • ${formatDateTime(b.created_at)}</span>
                  </div>`
                    )
                    .join("")
            }
          </div>`
        : ""
    }

    <div class="card">
      <div class="card-title">ملاحظات المعلمين</div>
      ${
        !notes || notes.length === 0
          ? `<p class="text-muted" style="font-size:13px;">لا توجد ملاحظات</p>`
          : notes
              .map(
                (n) => `
            <div style="padding:10px 0; border-bottom:1px solid var(--border);">
              <p style="margin:0 0 4px;">${escapeHtml(n.note)}</p>
              <span class="text-subtle" style="font-size:12px;">${n.subjects ? escapeHtml(n.subjects.name) + " • " : ""}${escapeHtml(n.created_by_profile?.full_name ?? "")} • ${formatDateTime(n.created_at)}</span>
            </div>`
              )
              .join("")
      }
    </div>
  `;
}

function initials(name) {
  if (!name) return "؟";
  return name.trim().split(/\s+/).slice(0, 2).map((p) => p[0]).join("");
}

const ICON_ATTENDANCE = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 10h18"/><path d="m8 15 2.5 2.5L16 12"/></svg>`;
const ICON_GRADE = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3 2 8l10 5 10-5-10-5Z"/><path d="M6 10.5V16c0 1.5 3 3 6 3s6-1.5 6-3v-5.5"/></svg>`;
const ICON_RISK = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z"/><path d="M12 9v4M12 17h.01"/></svg>`;
const ICON_SUBJECT = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2Z"/></svg>`;
