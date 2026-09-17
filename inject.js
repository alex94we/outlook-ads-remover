/* Outlook Ad Remover - payload iniettato nel WebView2 della nuova app Outlook.
   Nasconde le righe pubblicitarie dell'elenco messaggi.

   Regola primaria: la riga annuncio ha la classe "iIsOF".
   Ripiego strutturale: se la classe cambia con un aggiornamento, nasconde
   l'antenato dell'etichetta "Annuncio" che si trova allo stesso livello delle
   righe vere dell'elenco (div[role="listitem"]). */
(function () {
  'use strict';
  try {
    if ((location.hostname || '').toLowerCase().indexOf('outlook') === -1) { return; }
    if (window.__outlookAdFixLoaded) { return; }
    window.__outlookAdFixLoaded = true;

    var LABELS = ['annuncio', 'advertisement', 'advertising', 'sponsored', 'sponsorizzato',
                  'anzeige', 'werbung', 'publicit\u00e9', 'anuncio', 'advertentie', 'reclame',
                  'mainos', 'reklam', 'reclama', 'hirdet\u00e9s', 'reklama', 'mainonta'];

    var CSS = 'div[class~="iIsOF"]{display:none !important;height:0 !important;min-height:0 !important;' +
              'max-height:0 !important;padding:0 !important;margin:0 !important;border:0 !important;}';

    function addStyle() {
      var root = document.head || document.documentElement;
      if (!root || document.getElementById('outlook-adfix-style')) { return; }
      var s = document.createElement('style');
      s.id = 'outlook-adfix-style';
      s.type = 'text/css';
      s.appendChild(document.createTextNode(CSS));
      root.appendChild(s);
    }

    function hide(el) {
      if (!el || el.nodeType !== 1 || el.getAttribute('data-outlook-adfix') === '1') { return; }
      el.setAttribute('data-outlook-adfix', '1');
      el.style.setProperty('display', 'none', 'important');
      el.style.setProperty('height', '0', 'important');
      el.style.setProperty('padding', '0', 'important');
      el.style.setProperty('margin', '0', 'important');
    }

    function labelOnly(el) {
      if (!el || el.children.length > 0) { return false; }
      var t = (el.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
      return t.length > 0 && t.length <= 30 && LABELS.indexOf(t) !== -1;
    }

    function rowFromLabel(el) {
      var cur = el, depth = 0;
      while (cur && cur.parentElement && depth < 15) {
        var p = cur.parentElement;
        if (p.querySelector(':scope > div[role="listitem"]')) { return cur; }
        cur = p;
        depth++;
      }
      return null;
    }

    function sweep() {
      addStyle();
      var rows = document.querySelectorAll('div[class~="iIsOF"]');
      for (var i = 0; i < rows.length; i++) { hide(rows[i]); }
      var els = document.querySelectorAll('div,span');
      for (var j = 0; j < els.length; j++) {
        if (labelOnly(els[j])) {
          var r = rowFromLabel(els[j]);
          if (r) { hide(r); }
        }
      }
    }

    var pending = false;
    function schedule() {
      if (pending) { return; }
      pending = true;
      (window.requestAnimationFrame || window.setTimeout)(function () {
        pending = false;
        try { sweep(); } catch (e) { }
      }, 50);
    }

    addStyle();
    schedule();
    try { new MutationObserver(schedule).observe(document.documentElement || document, { childList: true, subtree: true }); } catch (e) { }
    setInterval(schedule, 2000);
    document.addEventListener('DOMContentLoaded', schedule, true);
  } catch (e) { }
})();
