/* هوية الأكاديمية (White Label): تُقرأ من جدول system_settings، ولا يُكتب اسم عميل في الكود.
   تُعدَّل القيم من إعدادات النظام (أدمن) أو من SQL لعميل جديد. تستخدم القيم الافتراضية عند تعذّر التحميل. */
(function () {
  'use strict';
  var cfg = window.ACADEMY_CONFIG || {};
  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  var A = window.ACADEMY = {
    name: 'أكاديمية النموذج',
    shortName: 'النموذج',
    director: 'مدير الأكاديمية',
    logoUrl: '',
    contact: { phone: '', whatsapp: '', email: '', address: '' },
    social: { facebook: '', instagram: '', youtube: '', tiktok: '' },
    esc: esc,
    ready: null
  };
  Object.defineProperty(A, 'fileTag', {
    get: function () { return String(A.shortName || 'academy').trim().replace(/\s+/g, '_').replace(/[\\\/:*?"<>|]/g, '') || 'academy'; }
  });

  var KEYS = {
    system_name: function (v) { A.name = v; },
    academy_short_name: function (v) { A.shortName = v; },
    academy_director_name: function (v) { A.director = v; },
    academy_logo_url: function (v) { A.logoUrl = v; },
    contact_phone: function (v) { A.contact.phone = v; },
    contact_whatsapp: function (v) { A.contact.whatsapp = v; },
    contact_email: function (v) { A.contact.email = v; },
    contact_address: function (v) { A.contact.address = v; },
    social_facebook: function (v) { A.social.facebook = v; },
    social_instagram: function (v) { A.social.instagram = v; },
    social_youtube: function (v) { A.social.youtube = v; },
    social_tiktok: function (v) { A.social.tiktok = v; },
    brand_navy: color('--navy'), brand_navy2: color('--navy2'),
    brand_gold: color('--gold'), brand_gold2: color('--gold2')
  };
  function color(cssVar) {
    return function (v) {
      if (/^#[0-9a-f]{3,8}$/i.test(v)) document.documentElement.style.setProperty(cssVar, v);
    };
  }

  function applyLogo() {
    var u = A.logoUrl;
    if (!u || !(/^https:\/\//i.test(u) || /^data:image\/(png|jpeg|webp|svg\+xml);/i.test(u))) return;
    document.querySelectorAll('.logo-area').forEach(function (area) {
      var first = area.firstElementChild;
      if (first && first.tagName === 'DIV' && first.textContent.indexOf('🎓') !== -1) {
        var img = document.createElement('img');
        img.src = u; img.alt = A.name;
        img.style.cssText = 'height:34px;width:auto;max-width:48px;object-fit:contain;border-radius:6px';
        first.textContent = ''; first.appendChild(img);
      }
    });
  }

  A.ready = (async function () {
    try {
      if (!cfg.supabaseUrl || !cfg.supabaseKey) return A;
      var ctl = new AbortController();
      var timer = setTimeout(function () { ctl.abort(); }, 6000);
      var url = cfg.supabaseUrl + '/rest/v1/system_settings?select=key,value&key=in.(' + Object.keys(KEYS).join(',') + ')';
      var res = await fetch(url, { headers: { apikey: cfg.supabaseKey }, signal: ctl.signal });
      clearTimeout(timer);
      if (!res.ok) return A;
      (await res.json()).forEach(function (row) {
        var v = row && typeof row.value === 'string' ? row.value.trim() : '';
        if (v && KEYS[row.key]) KEYS[row.key](v);
      });
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', applyLogo); else applyLogo();
    } catch (e) { /* تُستخدم القيم الافتراضية */ }
    return A;
  })();
})();
