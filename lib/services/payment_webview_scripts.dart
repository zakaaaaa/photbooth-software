class PaymentWebviewScripts {
  const PaymentWebviewScripts._();

  static const String autoSelectQris = '''
      (function() {
        var qrisClicked = false;

        function simulateClick(el) {
          ['mousedown', 'mouseup', 'click'].forEach(function(evtType) {
            el.dispatchEvent(new MouseEvent(evtType, {
              bubbles: true, cancelable: true, view: window
            }));
          });
        }

        function trySelectQris(attempt) {
          if (attempt > 30 || qrisClicked) return;

          var xpathResult = document.evaluate(
            "//*[contains(translate(text(),'qris','QRIS'),'QRIS')]",
            document, null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null
          );

          for (var i = 0; i < xpathResult.snapshotLength; i++) {
            var node = xpathResult.snapshotItem(i);
            var target = node;
            for (var depth = 0; depth < 8; depth++) {
              if (!target) break;
              var tag = (target.tagName || '').toUpperCase();
              var role = (target.getAttribute && target.getAttribute('role')) || '';
              var cursor = window.getComputedStyle(target).cursor;

              if (tag === 'BUTTON' || tag === 'A' || tag === 'LI' ||
                  role === 'button' || role === 'tab' || role === 'option' ||
                  cursor === 'pointer' ||
                  target.onclick != null ||
                  (target.className && target.className.toString().match(/channel|method|option|item|card|tab|accordion/i))) {
                simulateClick(target);
                qrisClicked = true;
                setTimeout(function() { scrollToQrCode(0); }, 2000);
                return;
              }
              target = target.parentElement;
            }
          }

          var fallbackSelectors = [
            '[data-channel*="qris" i]',
            '[data-channel*="QRIS"]',
            '[data-payment*="qris" i]',
            '[data-value*="qris" i]',
            '[id*="qris" i]',
            '[class*="qris" i]',
            '[class*="channel" i]',
          ];
          for (var s = 0; s < fallbackSelectors.length; s++) {
            try {
              var els = document.querySelectorAll(fallbackSelectors[s]);
              for (var j = 0; j < els.length; j++) {
                var txt = (els[j].textContent || '').toUpperCase();
                if (txt.indexOf('QRIS') !== -1) {
                  simulateClick(els[j]);
                  qrisClicked = true;
                  setTimeout(function() { scrollToQrCode(0); }, 2000);
                  return;
                }
              }
            } catch(e) {}
          }

          if (!qrisClicked) {
            var all = document.querySelectorAll('*');
            for (var k = 0; k < all.length; k++) {
              var el = all[k];
              var directText = '';
              for (var c = 0; c < el.childNodes.length; c++) {
                if (el.childNodes[c].nodeType === 3) {
                  directText += el.childNodes[c].textContent;
                }
              }
              if (directText.trim().toUpperCase().indexOf('QRIS') !== -1) {
                var clickTarget = el;
                while (clickTarget && clickTarget !== document.body) {
                  var cs = window.getComputedStyle(clickTarget).cursor;
                  if (cs === 'pointer') {
                    simulateClick(clickTarget);
                    qrisClicked = true;
                    setTimeout(function() { scrollToQrCode(0); }, 2000);
                    return;
                  }
                  clickTarget = clickTarget.parentElement;
                }
                simulateClick(el);
                qrisClicked = true;
                setTimeout(function() { scrollToQrCode(0); }, 2000);
                return;
              }
            }
          }

          setTimeout(function() { trySelectQris(attempt + 1); }, 500);
        }

        function scrollToQrCode(attempt) {
          if (attempt > 30) return;
          var qrSelectors = [
            'img[src*="qr"]', 'img[alt*="qr" i]', 'img[alt*="QRIS" i]',
            'canvas', '[class*="qr-code" i]', '[class*="qrcode" i]',
            '[id*="qr" i]', 'img[src*="payment"]',
            'img[src*="doku"]', 'img[src*="shopeepay"]',
          ];
          var qrElement = null;
          for (var s = 0; s < qrSelectors.length; s++) {
            try {
              qrElement = document.querySelector(qrSelectors[s]);
              if (qrElement) break;
            } catch(e) {}
          }
          if (qrElement) {
            qrElement.scrollIntoView({behavior: 'smooth', block: 'center'});
          } else {
            setTimeout(function() { scrollToQrCode(attempt + 1); }, 500);
          }
        }

        var observer = new MutationObserver(function() {
          if (!qrisClicked) {
            trySelectQris(0);
          } else {
            observer.disconnect();
          }
        });
        observer.observe(document.body || document.documentElement, {
          childList: true, subtree: true
        });

        setTimeout(function() { trySelectQris(0); }, 1500);
      })();
    ''';
}
