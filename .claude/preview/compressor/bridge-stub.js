// Browser-side mock of the production bridge in
// ConjureDSPExtension/Resources/customui-bridge.js, for use by the
// in-browser preview scaffold (see .claude/preview/README.md).
//
// Mirrors the public ConjureDSP.* surface — parameters.{count, get,
// set, metadata, onChange, onAnyChange}, audio.{onFrame, offFrame},
// ready, theme, log — and the production self-write semantics:
// `set()` fires onChange synchronously after a dedupe-on-equal guard,
// matching customui-bridge.js's actual behavior.
//
// The metadata + values below are scratch defaults shaped roughly
// like a compressor preset (threshold/ratio/attack/release/makeup/mix);
// edit freely for your test page. cdp-ui.js + your page only see
// what's exposed here, so adjusting this stub is how you simulate
// alternate plugin states (different param counts, missing metadata,
// edge values, etc.).
(function () {
  var META = [
    { name: 'Threshold', key: 'threshold', min: -60, max: 0, default: -20, unit: 'dB', curve: 'linear', style: 'slider' },
    { name: 'Ratio',     key: 'ratio',     min: 1,   max: 20,default: 4,   unit: ':1', curve: 'linear', style: 'slider' },
    { name: 'Attack',    key: 'attack',    min: 0.1, max: 100,default: 10, unit: 'ms', curve: 'log',    style: 'slider' },
    { name: 'Release',   key: 'release',   min: 10,  max: 2000,default: 100,unit: 'ms', curve: 'log',   style: 'slider' },
    { name: 'Makeup',    key: 'makeup',    min: 0,   max: 24, default: 0,   unit: 'dB', curve: 'linear',style: 'slider' },
    { name: 'Mix',       key: 'mix',       min: 0,   max: 1,  default: 1,   unit: '',   curve: 'linear',style: 'slider' },
  ];
  var values = META.map(function(m){ return m.default; });
  var perChange = META.map(function(){ return []; });
  var anyChange = [];
  var readyCbs = [];
  var ready = false;

  var ConjureDSP = {
    apiVersion: 1,
    theme: 'dark',
    parameters: {
      get count() { return META.length; },
      metadata: function (i) { return META[i] || null; },
      get: function (i) { return values[i]; },
      set: function (i, v) {
        // Mirrors the production bridge: synchronous onChange on self-
        // writes, with dedupe-on-equal to break recursion.
        var num = Number(v);
        if (!isFinite(num)) return;
        if (values[i] === num) return;
        values[i] = num;
        perChange[i].forEach(function(cb){ try { cb(num); } catch(e) { console.error('onChange threw', e); } });
        anyChange.forEach(function(cb){ try { cb(i, num); } catch(e) { console.error('onAnyChange threw', e); } });
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
        // Fire a synthetic frame periodically so drawMeter() runs.
        var iv = setInterval(function () {
          cb({ rmsIn: 0.3, rmsOut: 0.2, peakIn: 0.4, peakOut: 0.3 });
        }, 33);
        return function () { clearInterval(iv); };
      },
      offFrame: function () {},
    },
    ready: function (cb) {
      if (ready) cb();
      else readyCbs.push(cb);
    },
    log: function () { console.log.apply(console, ['[CDP-stub]'].concat([].slice.call(arguments))); },
  };

  window.ConjureDSP = ConjureDSP;

  // Fire ready on next tick (matches how the real bridge fires after Swift sends initial state).
  setTimeout(function () {
    ready = true;
    var cbs = readyCbs.slice(); readyCbs.length = 0;
    cbs.forEach(function(cb){ try { cb(); } catch(e) { console.error('ready cb threw', e); } });
  }, 0);
})();
