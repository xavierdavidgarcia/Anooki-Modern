// Anooki player. Strategy:
//   1) Try the original Screentime entry point (movie.swf). If it boots
//      it'll handle backgrounds + composition + date-driven anim choice
//      by itself, just like the 2013 screensaver did.
//   2) If movie.swf fails (the most common case — it needs STFProxy's
//      native bridge), fall back to rotating the anim*.swf clips over
//      the CSS gradient background.
//
// A single Ruffle player is created once and reused via .load() so the
// "RUFFLE" splash never flashes between anims.

(function () {
  const ANIM_COUNT = 30;          // anim0.swf .. anim29.swf
  const PER_ANIM_MS = 12_000;     // fixed per-anim window (metadata isn't reliable)
  const MOVIE_BOOT_GRACE_MS = 6_000; // how long to give movie.swf to prove itself

  const stage = document.getElementById("stage");

  let ruffle;
  let player;
  let queue = [];
  let perAnimTimer = null;
  let stopped = false;
  let mode = "movie"; // "movie" → trying movie.swf; "anim" → rotating clips

  function shuffle(a) {
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }

  function refillQueue() {
    const list = [];
    for (let i = 0; i < ANIM_COUNT; i++) list.push(`anims/anim${i}.swf`);
    queue = shuffle(list);
  }

  function nextAnimUrl() {
    if (queue.length === 0) refillQueue();
    return queue.shift();
  }

  function createPlayerIfNeeded() {
    if (player) return;
    if (!window.RufflePlayer) return;
    ruffle = window.RufflePlayer.newest();
    player = ruffle.createPlayer();
    player.style.width = "100%";
    player.style.height = "100%";
    stage.appendChild(player);
  }

  function loadInPlayer(url, extraConfig) {
    if (!player) return Promise.reject(new Error("no player"));
    const config = Object.assign({
      url,
      autoplay: "on",
      muted: true,
      backgroundColor: null,           // transparent → reveals CSS gradient
      letterbox: "on",
      unmuteOverlay: "hidden",
      scale: "showAll",
      warnOnUnsupportedContent: false,
      logLevel: "error",
      polyfills: false,
      allowNetworking: "none",
      allowScriptAccess: false,
      splashScreen: false              // suppress the yellow/blue "RUFFLE" logo
    }, extraConfig || {});
    return player.load(config);
  }

  async function tryMovieEntry() {
    console.log("[Anooki] trying movie.swf entry");
    try {
      await loadInPlayer("movie.swf");
    } catch (err) {
      console.error("[Anooki] movie.swf failed to load:", err && err.message);
      switchToAnimMode();
      return;
    }

    // movie.swf relies on STFProxy (Screentime native bridge) for licensing
    // and config. We give it MOVIE_BOOT_GRACE_MS to start displaying real
    // content. If we never receive a viable signal, fall back to anim mode.
    //
    // The simplest signal we can check is whether the SWF is still in its
    // first frame after the grace period (proxy gating). Ruffle doesn't
    // expose a great hook for this, so we just inspect the player's
    // metadata + readyState heuristically.
    setTimeout(() => {
      if (stopped) return;
      const meta = (player && player.metadata) || {};
      const stillBooting =
        !meta.numFrames || meta.numFrames < 2;
      if (stillBooting) {
        console.log("[Anooki] movie.swf appears stuck — falling back to anim rotation");
        switchToAnimMode();
      } else {
        console.log("[Anooki] movie.swf is running — leaving it alone");
      }
    }, MOVIE_BOOT_GRACE_MS);
  }

  function switchToAnimMode() {
    if (mode === "anim") return;
    mode = "anim";
    refillQueue();
    playNextAnim();
  }

  function playNextAnim() {
    if (stopped) return;
    if (perAnimTimer) { clearTimeout(perAnimTimer); perAnimTimer = null; }

    const url = nextAnimUrl();
    if (!url) return;

    loadInPlayer(url).catch(err => {
      console.error("[Anooki] anim load failed:", url, err && err.message);
    });

    perAnimTimer = setTimeout(playNextAnim, PER_ANIM_MS);
  }

  // Public hooks for the Swift host.
  window.anookiStop = function () {
    stopped = true;
    if (perAnimTimer) { clearTimeout(perAnimTimer); perAnimTimer = null; }
    try { player && player.remove(); } catch (e) { /* ignore */ }
    player = null;
  };
  window.anookiStart = function () {
    stopped = false;
    bootstrap(50);
  };

  function bootstrap(retries) {
    if (stopped) return;
    if (window.RufflePlayer && window.RufflePlayer.newest) {
      createPlayerIfNeeded();
      if (!player) {
        // Ruffle is loaded but instantiation failed; retry shortly.
        setTimeout(() => bootstrap(retries - 1), 100);
        return;
      }
      tryMovieEntry();
      return;
    }
    if (retries <= 0) {
      console.error("[Anooki] Ruffle did not load — giving up");
      return;
    }
    setTimeout(() => bootstrap(retries - 1), 100);
  }

  bootstrap(50);
})();
