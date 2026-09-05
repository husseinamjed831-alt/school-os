// School OS — shared "show activation code" modal. Used right after a
// teacher account is created and from the reissue action on the teacher
// profile page — same one-time reveal UI both times, built once here so
// there's exactly one place that renders a secret activation code.

let overlay = null;

function ensureOverlay() {
  if (overlay && document.body.contains(overlay)) return overlay;
  overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.id = "activation-code-overlay";
  overlay.innerHTML = `
    <div class="modal">
      <div class="modal-header">
        <h3>كود تفعيل الحساب</h3>
        <button type="button" class="modal-close" id="activation-code-close" aria-label="إغلاق">✕</button>
      </div>
      <p class="text-muted" style="margin-bottom:14px; font-size:13px;">
        سلّم هذه القيم للمعلم بشكل مباشر (وليس عبر قناة عامة). لن يظهر الكود مرة أخرى بعد إغلاق هذه النافذة —
        إن ضاع يمكن إصدار كود جديد من صفحة ملف المعلم. صالح لمدة <span id="activation-code-hours"></span> ساعة.
      </p>
      <div class="field">
        <label for="activation-code-hamura-id">HAMURA ID</label>
        <div class="flex gap-8">
          <input type="text" id="activation-code-hamura-id" readonly style="font-weight:800; letter-spacing:1px;" />
          <button type="button" class="btn btn-ghost btn-sm" data-copy="activation-code-hamura-id">نسخ</button>
        </div>
      </div>
      <div class="field">
        <label for="activation-code-value">كود التفعيل</label>
        <div class="flex gap-8">
          <input type="text" id="activation-code-value" readonly style="font-weight:800; letter-spacing:2px;" />
          <button type="button" class="btn btn-ghost btn-sm" data-copy="activation-code-value">نسخ</button>
        </div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn btn-primary" id="activation-code-done">تم</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);

  overlay.querySelector("#activation-code-close").addEventListener("click", close);
  overlay.querySelector("#activation-code-done").addEventListener("click", close);
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });
  overlay.querySelectorAll("[data-copy]").forEach((btn) =>
    btn.addEventListener("click", async () => {
      const input = document.getElementById(btn.dataset.copy);
      try {
        await navigator.clipboard.writeText(input.value);
      } catch {
        input.select();
        document.execCommand("copy");
      }
      const original = btn.textContent;
      btn.textContent = "تم النسخ ✓";
      setTimeout(() => {
        btn.textContent = original;
      }, 1500);
    })
  );

  return overlay;
}

function close() {
  overlay?.classList.remove("is-open");
}

/** @param {{hamura_id: string, activation_code: string, expires_at_hours: number}} data */
export function showActivationCodeModal(data) {
  const el = ensureOverlay();
  el.querySelector("#activation-code-hamura-id").value = data.hamura_id;
  el.querySelector("#activation-code-value").value = data.activation_code;
  el.querySelector("#activation-code-hours").textContent = data.expires_at_hours;
  el.classList.add("is-open");
}
