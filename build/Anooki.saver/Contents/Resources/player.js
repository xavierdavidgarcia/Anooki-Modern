// Anooki player — picks a random anim*.swf, plays it via Ruffle, advances when done.
// The original Screentime engine cycled through 31 numbered anims plus animEND.
// We mimic that: shuffle the list, play each once, then reshuffle.

(function () {
  const ANIM_COUNT = 30; // anim0.swf .. anim29.swf
  const FALLBACK_MS = 30_000; // if a SWF never reports "done", move on after this
  const stage = document.getElementById("stage");

  let queue = [];
  let currentPlayer = null;
  let fallbackTimer = null;
  let stopped = false;

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

  function nextAnim() {
    if (stopped) return;
    if (queue.length === 0) refillQueue();
    return queue.shift();
  }

  function cleanupCurrent() {
    if (fallbackTimer) {
      clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
    if (currentPlayer && currentPlayer.parentNode) {
      try { currentPlayer.remove(); } catch (e) { /* ignore */ }
    }
    currentPlayer = null;
  }

  async function playOne() {
    if (stopped) return;
    cleanupCurrent();

    const url = nextAnim();
    if (!url) return;

    if (!window.RufflePlayer) {
      // Ruffle hasn't loaded — try again shortly.
      setTimeout(playOne, 500);
      return;
    }

    const ruffle = window.RufflePlayer.newest();
    const player = ruffle.createPlayer();
    player.style.width = "100%";
    player.style.height = "100%";
    stage.appendChild(player);
    currentPlayer = player;

    // Hard timeout in case the player never signals completion.
    fallbackTimer = setTimeout(playOne, FALLBACK_MS);

    // Listen for the SWF reaching its end. Ruffle dispatches loadedmetadata when
    // the SWF is parsed; "PLAYER_LOADED_DATA"/play-state events are not standard,
    // so we poll for completion using a simple frame-count heuristic.
    player.addEventListener("loadedmetadata", () => {
      try {
        const meta = player.metadata || {};
        const totalFrames = meta.numFrames || 0;
        const fps = meta.frameRate || 24;
        if (totalFrames > 0 && fps > 0) {
          const durationMs = Math.ceil((totalFrames / fps) * 1000) + 250;
          clearTimeout(fallbackTimer);
          fallbackTimer = setTimeout(playOne, durationMs);
        }
      } catch (e) { /* keep fallback */ }
    });

    try {
      await player.load({
        url,
        autoplay: "on",
        muted: false,
        backgroundColor: "#000000",
        letterbox: "on",
        unmuteOverlay: "hidden",
        scale: "showAll",
        warnOnUnsupportedContent: false,
        logLevel: "error",
        polyfills: false,
      });
    } catch (err) {
      // If this anim fails to load, skip to the next one.
      console.error("[Anooki] load failed:", url, err);
      setTimeout(playOne, 250);
    }
  }

  // Public hook so the Swift side can pause us on stopAnimation.
  window.anookiStop = function () {
    stopped = true;
    cleanupCurrent();
  };
  window.anookiStart = function () {
    stopped = false;
    refillQueue();
    playOne();
  };

  // Wait for Ruffle to register itself before starting.
  function bootstrap(retries) {
    if (window.RufflePlayer && window.RufflePlayer.newest) {
      refillQueue();
      playOne();
      return;
    }
    if (retries <= 0) {
      console.error("[Anooki] Ruffle did not load.");
      return;
    }
    setTimeout(() => bootstrap(retries - 1), 100);
  }

  bootstrap(50);
})();
