// Browser-side mock of the production bridge for the cdp-meter preview.
// Drives the meter with a synthetic, time-varying audio frame so you can
// eyeball ballistics, peak-hold latch/release, click-to-reset, and
// telemetry sourcing without booting the AU. Edit freely.
(function () {
  var META = [
    { name: 'Drive', key: 'drive', min: 0, max: 1, default: 0.5, unit: '', curve: 'linear', style: 'slider' },
  ];
  var values = META.map(function (m) { return m.default; });
  var perChange = META.map(function () { return []; });
  var anyChange = [];
  var readyCbs = [];
  var ready = false;
  var frameCallbacks = [];

  // Synthetic audio: a sinusoidal envelope at ~0.4 Hz with a brief
  // burst every 4 s so peak hold + decay are easy to see.
  var t0 = performance.now();
  setInterval(function () {
    var t = (performance.now() - t0) / 1000;
    var slow = 0.5 + 0.5 * Math.sin(2 * Math.PI * 0.4 * t);
    var burst = (t % 4) < 0.05 ? 1.0 : 0;
    var peakOut = Math.max(slow * 0.85, burst);
    var rmsOut = peakOut * 0.6;
    var grDb = -((slow * slow) * 18);
    var frame = {
      peakIn: peakOut * 1.05,
      peakOut: peakOut,
      rmsIn: rmsOut * 1.05,
      rmsOut: rmsOut,
      t: t,
      telemetry: { GR_DB: grDb, gr_db: grDb },
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
      set: function (i, v) {
        var n = Number(v);
        if (!isFinite(n)) return;
        if (values[i] === n) return;
        values[i] = n;
        perChange[i].forEach(function (cb) { try { cb(n); } catch (e) { console.error(e); } });
        anyChange.forEach(function (cb) { try { cb(i, n); } catch (e) { console.error(e); } });
      },
      onChange: function (i, cb) {
        perChange[i].push(cb);
        return function () {
          var k = perChange[i].indexOf(cb);
          if (k >= 0) perChange[i].splice(k, 1);
        };
      },
      onAnyChange: function (cb) {
        anyChange.push(cb);
        return function () {
          var k = anyChange.indexOf(cb);
          if (k >= 0) anyChange.splice(k, 1);
        };
      },
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
