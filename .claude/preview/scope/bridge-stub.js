// Browser-side mock of the production bridge for the cdp-scope preview.
// Drives the scope with multiple synthetic vector telemetry slots so you
// can eyeball line/filled/dots, fixed vs auto-range, decimation, and
// the loose-name resolver against a single set of frames.
(function () {
  var META = []; // no params for the scope preview
  var values = [];
  var perChange = [];
  var anyChange = [];
  var readyCbs = [];
  var ready = false;
  var frameCallbacks = [];

  // Pre-allocate vectors so we mirror the production no-alloc pattern.
  var SINE_LEN = 256;
  var RAMP_LEN = 128;
  var IMPULSE_LEN = 64;
  var LONG_LEN = 4096;

  var sineCurve = new Array(SINE_LEN);
  var rampCurve = new Array(RAMP_LEN);
  var impulseCurve = new Array(IMPULSE_LEN);
  var longCurve = new Array(LONG_LEN);

  // Static ramp.
  for (var r = 0; r < RAMP_LEN; r++) rampCurve[r] = -1 + (2 * r) / (RAMP_LEN - 1);

  // Static long curve: sine + envelope + tiny detail noise so the
  // decimated min+max-per-pixel render fills out, not a flat line.
  for (var L = 0; L < LONG_LEN; L++) {
    var phase = (L / LONG_LEN) * Math.PI * 16;
    var env = 0.5 + 0.5 * Math.sin((L / LONG_LEN) * Math.PI * 2);
    longCurve[L] = env * Math.sin(phase) + 0.05 * Math.sin(L * 0.7);
  }

  var t0 = performance.now();
  setInterval(function () {
    var t = (performance.now() - t0) / 1000;

    // Sine: phase scrolls left at ~0.5 cycles/sec.
    var phaseOffset = t * Math.PI;
    for (var i = 0; i < SINE_LEN; i++) {
      sineCurve[i] = Math.sin(phaseOffset + (i / SINE_LEN) * Math.PI * 4);
    }

    // Impulse that walks across the buffer over ~3 s.
    var pos = Math.floor(((t / 3) % 1) * IMPULSE_LEN);
    for (var k = 0; k < IMPULSE_LEN; k++) {
      var d = k - pos;
      impulseCurve[k] = Math.exp(-(d * d) * 0.4);
    }

    var grDb = -((0.5 + 0.5 * Math.sin(t * 1.7)) * 18);

    var frame = {
      peakIn: 0.5,
      peakOut: 0.5,
      rmsIn: 0.3,
      rmsOut: 0.3,
      t: t,
      // Cover both shapes so resolveTelemetryKey + scalar-bail paths
      // are exercised by a single set of frames.
      telemetry: {
        sine_curve: sineCurve,
        ramp_curve: rampCurve,
        impulse_curve: impulseCurve,
        long_curve: longCurve,
        gr_db: grDb,
        // Loose-match target: HTML attribute "envcurve" should bind to
        // this slot via normalizeParamName.
        ENV_CURVE: sineCurve,
      },
    };
    frameCallbacks.forEach(function (cb) {
      try { cb(frame); } catch (e) { console.error('onFrame cb threw', e); }
    });
  }, 33);

  window.ConjureDSP = {
    apiVersion: 1,
    theme: 'dark',
    parameters: {
      get count() { return META.length; },
      metadata: function (i) { return META[i] || null; },
      get: function (i) { return values[i]; },
      set: function () {},
      onChange: function () { return function () {}; },
      onAnyChange: function () { return function () {}; },
    },
    audio: {
      onFrame: function (cb) {
        frameCallbacks.push(cb);
        return function () {
          var k = frameCallbacks.indexOf(cb);
          if (k >= 0) frameCallbacks.splice(k, 1);
        };
      },
      offFrame: function (cb) {
        var k = frameCallbacks.indexOf(cb);
        if (k >= 0) frameCallbacks.splice(k, 1);
      },
    },
    ready: function (cb) {
      if (ready) cb(); else readyCbs.push(cb);
    },
    log: function () { console.log.apply(console, ['[CDP-stub]'].concat([].slice.call(arguments))); },
  };

  setTimeout(function () {
    ready = true;
    var cbs = readyCbs.slice(); readyCbs.length = 0;
    cbs.forEach(function (cb) { try { cb(); } catch (e) { console.error(e); } });
  }, 0);
})();
