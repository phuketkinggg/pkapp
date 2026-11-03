// Pangea website drawings, drawn live in code (no stock images).
// Hero: separate landmasses drift together into one, Pangea. The body, back together.
// The four parts of you: brainwaves, a heartbeat, living cells and a turning DNA helix.
(function () {
  var calm = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var GOLD = '184,138,68', GOLDD = '138,106,53', GREEN = '24,53,45', SOFT = '47,85,70';

  function fit(c) {
    var r = c.getBoundingClientRect(), d = Math.min(window.devicePixelRatio || 1, 2);
    c.width = Math.max(1, Math.round(r.width * d)); c.height = Math.max(1, Math.round(r.height * d));
    var x = c.getContext('2d'); x.setTransform(d, 0, 0, d, 0, 0); return { x: x, w: r.width, h: r.height };
  }
  function whenSeen(el, start, stop) {
    if (!('IntersectionObserver' in window)) { start(); return; }
    new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) start(); else stop(); }); }, { threshold: 0.05 }).observe(el);
  }
  function loop(draw) {
    var raf = 0, on = false, t0 = performance.now();
    function f(now) { if (!on) return; draw((now - t0) / 1000); raf = requestAnimationFrame(f); }
    return { start: function () { if (on) return; on = true; raf = requestAnimationFrame(f); }, stop: function () { on = false; cancelAnimationFrame(raf); } };
  }
  // smooth value noise for coastlines
  function hash(i) { var s = Math.sin(i * 127.1) * 43758.5453; return s - Math.floor(s); }
  function noise1(a, seed) { var i = Math.floor(a), f = a - i, u = f * f * (3 - 2 * f); return hash(i + seed) * (1 - u) + hash(i + 1 + seed) * u; }
  function ease(t) { return t < 0 ? 0 : t > 1 ? 1 : 1 - Math.pow(1 - t, 3); }

  /* ---------- the hero: one land ---------- */
  var land = document.getElementById('land');
  if (land) {
    // Pangea's plates where they sat 250 million years ago (x, y, size in units of R), and how far each has drifted today (dx, dy, turn)
    var PLATES = [
      { x: -0.48, y: -0.36, rx: 0.40, ry: 0.27, dx: -0.55, dy: -0.10, turn: 0.35 },  // north America
      { x: 0.12, y: -0.48, rx: 0.58, ry: 0.25, dx: 0.45, dy: -0.25, turn: -0.25 },   // Eurasia
      { x: -0.52, y: 0.22, rx: 0.26, ry: 0.37, dx: -0.70, dy: 0.40, turn: -0.45 },   // south America
      { x: -0.10, y: 0.08, rx: 0.34, ry: 0.40, dx: 0.02, dy: 0.18, turn: 0.15 },     // Africa
      { x: 0.02, y: 0.58, rx: 0.44, ry: 0.19, dx: 0.20, dy: 0.55, turn: 0.40 },      // Antarctica and Australia
      { x: 0.34, y: 0.27, rx: 0.17, ry: 0.16, dx: 0.55, dy: -0.05, turn: -0.60 }     // India
    ];
    var SEA = { x: 0.62, y: -0.04, rx: 0.42, ry: 0.19 }; // the Tethys sea, cutting in from the east
    function vnoise(x, y) { var i = Math.floor(x), j = Math.floor(y), fx = x - i, fy = y - j, u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
      function h(a, b) { return hash(a * 57 + b * 131 + 7); }
      return (h(i, j) * (1 - u) + h(i + 1, j) * u) * (1 - v) + (h(i, j + 1) * (1 - u) + h(i + 1, j + 1) * u) * v; }
    var dots = [], G, view;
    function build() {
      view = fit(land); dots = [];
      var w = view.w, h = view.h, small = w < 760;
      var R = small ? w * 0.34 : Math.min(w * 0.22, h * 0.40);
      var cx = small ? w * 0.5 : w * 0.75, cy = small ? R * 1.2 : h * 0.5;
      var step = Math.max(5.5, R / 34);
      for (var gx = -1.1; gx <= 1.1; gx += step / R) for (var gy = -0.95; gy <= 0.95; gy += step / R) {
        var best = -1, k = -1;
        PLATES.forEach(function (p, i) { var ex = (gx - p.x) / p.rx, ey = (gy - p.y) / p.ry, f = 1 - Math.sqrt(ex * ex + ey * ey); if (f > best) { best = f; k = i; } });
        var coast = (vnoise(gx * 5 + 3, gy * 5 + 9) - 0.5) * 0.5 + (vnoise(gx * 13, gy * 13) - 0.5) * 0.2;
        if (best + coast < 0) continue;
        var sx = (gx - SEA.x) / SEA.rx, sy = (gy - SEA.y) / SEA.ry; if (sx * sx + sy * sy < 1 + coast) continue;
        var p = PLATES[k];
        dots.push({ k: k, ox: (gx - p.x) * R, oy: (gy - p.y) * R, inner: Math.min(1, best * 2.2), tw: hash(dots.length + 3) * 6.28 });
      }
      G = { R: R, cx: cx, cy: cy, step: step };
    }
    function draw(t) {
      var x = view.x, w = view.w, h = view.h, R = G.R;
      x.clearRect(0, 0, w, h);
      x.lineWidth = 1;
      for (var i = 1; i <= 3; i++) { x.strokeStyle = 'rgba(' + GOLD + ',' + (0.17 - i * 0.04) + ')'; x.beginPath(); x.arc(G.cx, G.cy, R * (1.05 + i * 0.28), 0, 6.283); x.stroke(); }
      var p = calm ? 1 : ease((t - 0.5) / 9.5), apart = 1 - p;
      for (var j = 0; j < dots.length; j++) {
        var d = dots[j], pl = PLATES[d.k], turn = pl.turn * apart, c = Math.cos(turn), s = Math.sin(turn);
        var X = G.cx + (pl.x + pl.dx * apart) * R + d.ox * c - d.oy * s, Y = G.cy + (pl.y + pl.dy * apart) * R + d.ox * s + d.oy * c;
        var a = (0.35 + 0.55 * d.inner + (calm ? 0 : 0.1 * Math.sin(t * 0.6 + d.tw))) * (0.3 + 0.7 * p);
        x.fillStyle = 'rgba(' + (d.inner < 0.25 ? GOLDD : GOLD) + ',' + Math.max(0, Math.min(1, a)) + ')';
        x.beginPath(); x.arc(X, Y, G.step * 0.22, 0, 6.283); x.fill();
      }
    }
    build();
    var L = loop(draw);
    if (calm) draw(20); else whenSeen(land, L.start, L.stop);
    var rt; window.addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(function () { build(); if (calm) draw(20); }, 150); });
  }

  /* ---------- the logo film: gold on black made see-through. The file holds the picture on top and its see-through mask below;
     WebGL puts them together, so it works in every browser. Plays once, stays on the logo, tap to play again. ---------- */
  var la = document.querySelector('.logoanim');
  if (la) (function () {
    function still() { if (la.querySelector('img')) return; var i = new Image(); i.src = 'media/pangea-logo.webp'; i.alt = ''; la.appendChild(i); var c = la.querySelector('canvas'); if (c) c.remove(); }
    if (calm) { still(); return; }
    var cv = document.createElement('canvas'), gl = cv.getContext('webgl', { premultipliedAlpha: true, alpha: true });
    if (!gl) { still(); return; }
    var vid = document.createElement('video'); vid.muted = true; vid.defaultMuted = true; vid.playsInline = true; vid.setAttribute('playsinline', ''); vid.setAttribute('muted', ''); vid.preload = 'auto'; vid.src = la.getAttribute('data-video');
    var vs = 'attribute vec2 p;varying vec2 u;void main(){u=vec2(p.x*.5+.5,.5-p.y*.5);gl_Position=vec4(p,0.,1.);}';
    var fs = 'precision mediump float;varying vec2 u;uniform sampler2D t;void main(){vec3 c=texture2D(t,vec2(u.x,u.y*.5)).rgb;float a=texture2D(t,vec2(u.x,u.y*.5+.5)).r;gl_FragColor=vec4(c*a,a);}';
    function sh(type, src) { var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; }
    var pr = gl.createProgram(); gl.attachShader(pr, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(pr); gl.useProgram(pr);
    var b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    var loc = gl.getAttribLocation(pr, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    var tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T].forEach(function (k) { gl.texParameteri(gl.TEXTURE_2D, k, gl.CLAMP_TO_EDGE); });
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    function size() { var r = la.getBoundingClientRect(), d = Math.min(window.devicePixelRatio || 1, 2); cv.width = Math.round(r.width * d); cv.height = Math.round(r.height * d); gl.viewport(0, 0, cv.width, cv.height); }
    function frame() { if (vid.readyState < 2) return; gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, vid); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4); }
    var raf = 0; function tick() { frame(); if (!vid.paused && !vid.ended) raf = requestAnimationFrame(tick); }
    la.appendChild(cv); size(); window.addEventListener('resize', function () { size(); frame(); });
    vid.addEventListener('play', function () { cancelAnimationFrame(raf); raf = requestAnimationFrame(tick); });
    vid.addEventListener('ended', function () { frame(); });
    vid.addEventListener('error', still);
    var started = false;
    function go() { if (started) return; started = true; var r = vid.play(); if (r && r.catch) r.catch(still); setTimeout(function () { if (vid.paused && vid.currentTime === 0) still(); }, 4000); }
    if ('IntersectionObserver' in window) new IntersectionObserver(function (es) { if (es[0].isIntersecting) go(); }, { threshold: 0.2 }).observe(la); else go();
    la.addEventListener('click', function () { if (!la.querySelector('canvas')) return; vid.currentTime = 0; var r = vid.play(); if (r && r.catch) r.catch(function () {}); });
  })();

  /* ---------- the four parts of you ---------- */
  var ART = {
    mind: function (v, t) { // brainwaves: alpha, theta and a slow delta, layered
      var x = v.x, w = v.w, h = v.h; x.clearRect(0, 0, w, h); x.lineWidth = 1.2;
      [[0.55, 9, 0.9, GREEN, 0.85], [0.35, 5, 0.55, SOFT, 0.55], [0.2, 2.2, 0.3, GOLD, 0.8]].forEach(function (l, i) {
        x.strokeStyle = 'rgba(' + l[3] + ',' + l[4] + ')'; x.beginPath();
        for (var px = 0; px <= w; px += 2) {
          var u = px / w, env = Math.sin(u * Math.PI);
          var y = h / 2 + env * h * 0.32 * l[0] * (Math.sin(u * l[1] * 6.283 - t * l[2] * 2) * 0.7 + Math.sin(u * l[1] * 3.1 + t * l[2] + i) * 0.3);
          px ? x.lineTo(px, y) : x.moveTo(px, y);
        }
        x.stroke();
      });
    },
    body: function (v, t) { // a heartbeat trace, written left to right
      var x = v.x, w = v.w, h = v.h; x.clearRect(0, 0, w, h);
      var period = w / 2.2, head = (t * 70) % (w + 40);
      function beat(px) {
        var u = ((px % period) + period) % period / period, y = 0;
        if (u > 0.30 && u < 0.36) y = -Math.sin((u - 0.30) / 0.06 * Math.PI) * 0.08;
        else if (u > 0.40 && u < 0.43) y = (u - 0.40) / 0.03 * 0.12;
        else if (u >= 0.43 && u < 0.47) y = 0.12 - (u - 0.43) / 0.04 * 0.62;
        else if (u >= 0.47 && u < 0.51) y = -0.50 + (u - 0.47) / 0.04 * 0.62;
        else if (u > 0.60 && u < 0.72) y = -Math.sin((u - 0.60) / 0.12 * Math.PI) * 0.12;
        return h / 2 + y * h;
      }
      x.strokeStyle = 'rgba(' + GREEN + ',.12)'; x.lineWidth = 1; x.beginPath(); x.moveTo(0, h / 2); x.lineTo(w, h / 2); x.stroke();
      x.lineWidth = 1.4;
      for (var px = 1; px <= Math.min(head, w); px += 2) {
        var fade = Math.max(0, 1 - (head - px) / (w * 0.9));
        x.strokeStyle = 'rgba(' + GREEN + ',' + (0.1 + 0.8 * fade) + ')';
        x.beginPath(); x.moveTo(px - 2, beat(px - 2)); x.lineTo(px, beat(px)); x.stroke();
      }
      if (head <= w) { x.fillStyle = 'rgba(' + GOLD + ',1)'; x.beginPath(); x.arc(head, beat(head), 3.2, 0, 6.283); x.fill(); }
    },
    food: function (v, t) { // living cells, drifting and breathing
      var x = v.x, w = v.w, h = v.h; x.clearRect(0, 0, w, h);
      var C = [[0.22, 0.45, 0.17, 0], [0.5, 0.55, 0.22, 1], [0.78, 0.4, 0.15, 2], [0.38, 0.2, 0.08, 3], [0.66, 0.82, 0.09, 4], [0.9, 0.78, 0.06, 5]];
      C.forEach(function (c) {
        var cx = c[0] * w + Math.sin(t * 0.25 + c[3]) * 6, cy = c[1] * h + Math.cos(t * 0.21 + c[3] * 2) * 5, r = c[2] * Math.min(w, h * 1.6);
        x.beginPath();
        for (var a = 0; a <= 6.3; a += 0.12) {
          var rr = r * (1 + 0.08 * Math.sin(a * 3 + t * 0.6 + c[3]) + 0.05 * Math.sin(a * 5 - t * 0.4));
          var X = cx + Math.cos(a) * rr, Y = cy + Math.sin(a) * rr; a ? x.lineTo(X, Y) : x.moveTo(X, Y);
        }
        x.closePath(); x.fillStyle = 'rgba(' + GREEN + ',.04)'; x.fill(); x.strokeStyle = 'rgba(' + GREEN + ',.7)'; x.lineWidth = 1.1; x.stroke();
        x.fillStyle = 'rgba(' + GOLD + ',.85)'; x.beginPath(); x.arc(cx + r * 0.18 * Math.sin(t * 0.3 + c[3]), cy - r * 0.12, r * 0.24, 0, 6.283); x.fill();
      });
    },
    dna: function (v, t) { // a slowly turning double helix
      var x = v.x, w = v.w, h = v.h; x.clearRect(0, 0, w, h);
      var amp = h * 0.32, turns = 2.6, n = 90, ph = t * 0.7, pts = [];
      for (var i = 0; i <= n; i++) { var u = i / n, a = u * turns * 6.283 + ph; pts.push([u * w, h / 2 + Math.sin(a) * amp, h / 2 - Math.sin(a) * amp, Math.cos(a)]); }
      for (var j = 0; j <= n; j += 4) { var p = pts[j]; x.strokeStyle = 'rgba(' + GOLD + ',' + (0.25 + 0.45 * Math.abs(p[3])) + ')'; x.lineWidth = 1; x.beginPath(); x.moveTo(p[0], p[1]); x.lineTo(p[0], p[2]); x.stroke(); }
      [1, 2].forEach(function (k) {
        for (var i = 1; i <= n; i++) {
          var a = pts[i - 1], b = pts[i], depth = k === 1 ? b[3] : -b[3];
          x.strokeStyle = 'rgba(' + GREEN + ',' + (0.25 + 0.6 * (depth + 1) / 2) + ')'; x.lineWidth = 1 + (depth + 1) * 0.6;
          x.beginPath(); x.moveTo(a[0], a[k]); x.lineTo(b[0], b[k]); x.stroke();
        }
      });
    }
  };
  Array.prototype.forEach.call(document.querySelectorAll('canvas[data-draw]'), function (c) {
    var f = ART[c.getAttribute('data-draw')]; if (!f) return;
    var v = fit(c), L = loop(function (t) { f(v, t); });
    if (calm) f(v, 3); else whenSeen(c, L.start, L.stop);
    window.addEventListener('resize', function () { v = fit(c); if (calm) f(v, 3); });
  });
})();
